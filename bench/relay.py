"""What keeping a space costs a relay on Durable Objects and R2, and how fast it serves it: python3 bench/relay.py [rows]

Under workerd here, or, given ZSP_CLOUD=https://... and ZSP_CLOUD_TOKEN, against a relay deployed with STATS set.
Devices are zspd, here; the relay counts what it did, and this prices it."""

import json, os, statistics, sys, time, urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests"))
import end_to_end as e

ROWS = int(sys.argv[1]) if len(sys.argv) > 1 else 1500
VALUE = 16 << 10
# Cloudflare's prices, as given.
CLASS_A, CLASS_B, ROW_WRITTEN = 4.50e-6, 0.36e-6, 1.00e-6
R2_GB_MONTH, DO_GB_MONTH = 0.015, 0.20


def stats(cloud, space):
    url = cloud.url.replace("ws", "http", 1) + "/" + space + "?stats"
    return json.loads(urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "zsp-bench"})).read())


def spent(a, b):
    s0, s1 = a["storage"], b["storage"]
    d = {k: s1[k] - s0[k] for k in ("gets", "puts", "deletes", "got", "put", "rowsWritten", "rowsRead", "getMs", "putMs")}
    d["dollars"] = d["puts"] * CLASS_A + d["gets"] * CLASS_B + d["rowsWritten"] * ROW_WRITTEN
    n0, n1 = a.get("node") or {}, b.get("node") or {}
    d["node"] = {k: n1[k] - n0.get(k, 0) for k in n1 if k != "dirty"}
    return d


def line(what, d, per=None, n=1):
    each = f"{d['dollars'] / n * 1e6:9.3f} µ$ each" if per else ""
    print(
        f"  {what:<34} A {d['puts']:>5}  B {d['gets']:>5}  rows {d['rowsWritten']:>6}  "
        f"R2 put {d['put'] / 1e6:7.2f} MB  got {d['got'] / 1e6:7.2f} MB  ${d['dollars']:.6f} {each}"
    )
    n = d["node"]
    if n:
        print(f"  {'':<34} checkpoints {n['checkpoints']}, extents {n['extents']}, log gets {n['log_gets']}, pages fetched {n['fetched_pages']}, from its own storage {n['local_hits']}, relocated {n['relocated']}")


def main():
    cloud = e.Cloud().start(ACCESS_TOKEN="bench")
    where = "deployed" if cloud.p is None else "under workerd"
    _, (a, b) = e.space("ra", "rb", relay=cloud, options=["--credential=" + cloud.token])
    sid = e.zspd_space(a)
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "bench")
    cb.until(lambda: 1 in cb.windows, timeout=60)
    print(f"a relay {where}, {ROWS} rows of {VALUE >> 10} KiB")
    results = {}

    # One small write, from one device through the relay to another's screen.
    s0 = stats(cloud, sid)
    took = []
    for i in range(60):
        t = time.monotonic()
        ca.put(1, "bench", i, [b"x" * 100])
        cb.until(lambda: len(cb.list(1, "bench")) == i + 1, timeout=30)
        took.append(time.monotonic() - t)
    s1 = stats(cloud, sid)
    d = spent(s0, s1)
    results["small write"] = {"p50_ms": statistics.median(took) * 1e3, "p90_ms": sorted(took)[int(len(took) * 0.9)] * 1e3, **d}
    print(f"small write seen on the other device: p50 {results['small write']['p50_ms']:.1f} ms, p90 {results['small write']['p90_ms']:.1f} ms")
    line("60 small writes", d, True, 60)

    # Much at once.
    s0 = stats(cloud, sid)
    t = time.monotonic()
    for i in range(ROWS):
        ca.put(1, "bench", 1000 + i, [os.urandom(VALUE)])
    cb.until(lambda: len(cb.list(1, "bench")) == 60 + ROWS, timeout=600)
    took = time.monotonic() - t
    time.sleep(5)  # what it puts in R2 once the burst is over
    s1 = stats(cloud, sid)
    d = spent(s0, s1)
    mb = ROWS * VALUE / 1e6
    results["bulk"] = {"seconds": took, "mb": mb, **d}
    print(f"{mb:.0f} MB written and seen on the other device in {took:.1f} s: {mb / took:.1f} MB/s")
    line(f"{mb:.0f} MB in bulk", d)
    print(f"  per MB: ${d['dollars'] / mb:.6f}; checkpoints {s1['node']['checkpoints'] - s0['node']['checkpoints']}, extents {s1['node']['extents'] - s0['node']['extents']}")

    # A device that has none of it.
    s0 = stats(cloud, sid)
    c = e.Node("rc", "run", "--credential=" + cloud.token, "--no-udp")
    e.zspd("admit", a.dir, e.zspd("key", c.dir), "1")
    e.zspd("join", c.dir, sid, cloud.key, cloud.url)
    c.start()
    e.eventually("it hears who belongs", lambda: os.path.exists(os.path.join(c.dir, sid, "roster")), 60)
    t = time.monotonic()
    cc = c.client()
    cc.watch(1, 1, "bench")
    cc.until(lambda: len(cc.list(1, "bench")) == 60 + ROWS, timeout=900)
    took = time.monotonic() - t
    s1 = stats(cloud, sid)
    d = spent(s0, s1)
    results["catch up"] = {"seconds": took, **d}
    print(f"a new device has all {mb:.0f} MB in {took:.1f} s: {mb / took:.1f} MB/s")
    line("catching up", d)

    # A window of the latest 50, on a relay that has slept.
    time.sleep(20 if cloud.p is None else 12)
    s0 = stats(cloud, sid)
    cw = b.client()
    t = time.monotonic()
    cw.watch(7, 1, "bench", limit=50)
    cw.until(lambda: 7 in cw.windows and len(cw.list(1, "bench")) >= 50, timeout=60)
    took = time.monotonic() - t
    s1 = stats(cloud, sid)
    d = spent(s0, s1)
    results["window"] = {"ms": took * 1e3, **d}
    print(f"a window of 50 after sleeping: {took * 1e3:.0f} ms")
    line("window of 50", d)

    # A device that has it all already, back: one fingerprint.
    s0 = stats(cloud, sid)
    c.stop()
    t = time.monotonic()
    c.start()
    cc = c.client()
    cc.watch(1, 1, "bench")
    cc.until(lambda: 1 in cc.windows, timeout=60)
    took = time.monotonic() - t
    s1 = stats(cloud, sid)
    d = spent(s0, s1)
    results["reconnect"] = {"ms": took * 1e3, **d}
    print(f"a device that has everything, back and level: {took * 1e3:.0f} ms")
    line("reconnecting level", d)

    s = stats(cloud, sid)
    st = s["storage"]
    results["at rest"] = {"sqlite_bytes": s["sqlite"], "memory_bytes": s["node"] and s["memory"], "r2_put_mb": st["put"] / 1e6}
    gets, puts = max(st["gets"], 1), max(st["puts"], 1)
    print(
        f"at rest: the object's own storage {s['sqlite'] / 1e6:.2f} MB (${s['sqlite'] / 1e9 * DO_GB_MONTH:.5f}/month), "
        f"wasm memory {s['memory'] / 1e6:.1f} MB; R2 get {st['getMs'] / gets:.1f} ms, put {st['putMs'] / puts:.1f} ms on average"
    )
    print(json.dumps(results, indent=1))


try:
    main()
finally:
    for p in e.procs:
        p.kill()
