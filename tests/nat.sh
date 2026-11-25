#!/bin/sh
# Two devices, each behind its own NAT, a relay on the public side that also answers STUN. They must find
# a direct path, use it, and still agree when the NATs forbid one. Needs root: ./x nat
set -eu
BIN=${ZSPD:-$(dirname "$0")/../build/zspd}
BIN=$(readlink -f "$BIN")
CLIENTS=$(readlink -f "$(dirname "$0")/../clients/python")
T=$(mktemp -d)
NS="zpub zna znb za zb"
clean() { pkill -9 -f "$T" 2>/dev/null || true; for n in $NS; do ip netns del $n 2>/dev/null || true; done; rm -rf "$T"; }
trap clean EXIT
for n in $NS; do ip netns del $n 2>/dev/null || true; ip netns add $n; ip -n $n link set lo up; done

ip -n zpub link add br0 type bridge; ip -n zpub link set br0 up; ip -n zpub addr add 198.51.100.1/24 dev br0
house() { # nat host public private
	ip link add v$1 netns zpub type veth peer name wan netns $1
	ip -n zpub link set v$1 master br0; ip -n zpub link set v$1 up
	ip -n $1 addr add $3/24 dev wan; ip -n $1 link set wan up
	ip link add lan netns $1 type veth peer name eth0 netns $2
	ip -n $1 addr add $4.1/24 dev lan; ip -n $1 link set lan up
	ip -n $2 addr add $4.2/24 dev eth0; ip -n $2 link set eth0 up
	ip -n $2 route add default via $4.1
	ip netns exec $1 sysctl -qw net.ipv4.ip_forward=1
	ip netns exec $1 iptables -t nat -A POSTROUTING -o wan -j MASQUERADE $5
	ip netns exec $1 iptables -A FORWARD -i wan -m state --state NEW -j DROP
	ip netns exec $1 iptables -A INPUT -i wan -m state --state NEW -j DROP
}
house zna za 198.51.100.10 10.1.1 ""
house znb zb 198.51.100.20 10.2.2 "${NAT_B:-}"

(cd "$T" && ip netns exec zpub "$BIN" serve "$T/relay" --listen=198.51.100.1:8787 --udp=3478 >"$T/relay.out" 2>&1 &)
sleep 0.5
KEY=$(cut -d' ' -f1 "$T/relay.out")
S=$("$BIN" create "$T/a")
"$BIN" relay "$T/a" "$KEY" ws://198.51.100.1:8787
"$BIN" admit "$T/a" "$("$BIN" key "$T/b")" 1
"$BIN" join "$T/b" "$S" "$KEY" ws://198.51.100.1:8787
for n in a b; do (ip netns exec z$n "$BIN" run "$T/$n" --stun=198.51.100.1:3478 --verbose >"$T/$n.out" 2>"$T/$n.log" &); done
i=0; while ! { grep -q "linked directly" "$T/a.log" && grep -q "linked directly" "$T/b.log"; }; do
	i=$((i + 1)); [ $i -lt 60 ] || { [ -n "${EXPECT_RELAY:-}" ] && break; echo "never linked"; cat "$T"/*.log; exit 1; }; sleep 0.1
done
grep -h "linked directly" "$T/a.log" "$T/b.log" || echo "no direct path, as arranged"
[ -n "${EXPECT_RELAY:-}" ] || { pkill -9 -f "$T/relay" ; sleep 0.2; }
ip netns exec za python3 -c "
import sys; sys.path.insert(0, '$CLIENTS'); import zsp
c = zsp.Client(open('$T/a/address').read(), open('$T/a/token','rb').read())
for i in range(20): c.put(1, 'x', i, [b'across'])
c.until(lambda: c.acked == c.seq)"
ip netns exec zb python3 -c "
import sys; sys.path.insert(0, '$CLIENTS'); import zsp
c = zsp.Client(open('$T/b/address').read(), open('$T/b/token','rb').read())
c.watch(1, 1, 'x'); c.until(lambda: len(c.list(1, 'x')) == 20)"
echo ok
