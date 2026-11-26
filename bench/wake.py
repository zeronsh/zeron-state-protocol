"""How long a relay takes to wake, by how much log it has to replay: python3 bench/wake.py [tails in KiB...]

Against a relay deployed with STATS set and QUIET_TAIL far above the largest tail, so that no checkpoint comes of waiting (ZSP_CLOUD=https://...,
ZSP_CLOUD_TOKEN), or under workerd here. For each tail, a new space has that much written past its last checkpoint, in
rows of 16 KiB or of 200 bytes; then the relay is woken three ways, and what a device next writes is timed to another:
as an object evicted with its cache, as one evicted with nothing at hand, and as one that hibernated on its own."""

import json, os, statistics, sys, time, urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests"))
import end_to_end as e

TAILS = [int(t) << 10 for t in sys.argv[1:]] or [0, 256 << 10, 1 << 20, 4 << 20]
HIBERNATE = float(os.environ.get("ZSP_HIBERNATE", "20"))  # seconds idle before an object with sockets hibernates


def get(cloud, sid, q):
    url = cloud.url.replace("ws", "http", 1) + "/" + sid + "?" + q
    t = time.monotonic()
    body = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "zsp-bench"})).read()
    return body, (time.monotonic() - t) * 1e3


def stats(cloud, sid):
    return json.loads(get(cloud, sid, "stats")[0])


def quiet(cloud, sid):
    def still():
        a = stats(cloud, sid)
        time.sleep(0.5)
        b = stats(cloud, sid)
        return [a["storage"][k] for k in ("gets", "puts", "deletes", "rowsWritten")] == [b["storage"][k] for k in ("gets", "puts", "deletes", "rowsWritten")]

    e.eventually("the relay is quiet", still, timeout=120)


def one_write(ca, cb, order):
    t = time.monotonic()
    ca.put(1, "w", order, [b"x" * 100])
    cb.until(lambda: any(o == order for o, _, _ in cb.list(1, "w")), timeout=60)
    return (time.monotonic() - t) * 1e3


def main():
    cloud = e.Cloud().start(ACCESS_TOKEN="bench", QUIET_TAIL=str(64 << 20))
    results = []
    sizes = ((16 << 10, "rows of 16 KiB"), (200, "rows of 200 B"))
    for size, name in [x for x in sizes if os.environ.get("ZSP_ROWS", "") in ("", str(x[0]))]:
        for tail in TAILS:
            run = len(results)
            _, (a, b) = e.space(f"wa{run}", f"wb{run}", relay=cloud, options=["--credential=" + cloud.token])
            sid = e.zspd_space(a)
            ca, cb = a.client(), b.client()
            cb.watch(1, 1, "w", limit=20, back=True)
            cb.until(lambda: 1 in cb.windows, timeout=60)
            ca.put(1, "w", 0, [b"first"])
            cb.until(lambda: len(cb.list(1, "w")) == 1, timeout=60)
            quiet(cloud, sid)
            base = stats(cloud, sid)["node"]
            n, order = 0, 1
            while True:
                st = stats(cloud, sid)["node"]
                if os.environ.get("ZSP_DEBUG"):
                    print("  at", st["tail"], st["checkpoint"], st["checkpoints"], st["dirty"], flush=True)
                if st["tail"] - st["checkpoint"] >= tail:
                    break
                batch = max(1, min(200, (tail - (st["tail"] - st["checkpoint"])) // (size + 120)))
                for _ in range(batch):
                    ca.put(1, "w", 1000 + order, [os.urandom(size)])
                    order += 1
                ca.drain(0.2)
                n += batch
            quiet(cloud, sid)
            st = stats(cloud, sid)["node"]
            replay = st["tail"] - st["checkpoint"]
            row = {"rows": name, "tail_kib": tail >> 10, "replay_kib": replay >> 10, "checkpoints": st["checkpoints"] - base["checkpoints"]}
            for how in ("warm", "cold"):
                took = []
                for _ in range(3):
                    _, ms = get(cloud, sid, "evict=" + how)
                    took.append((ms, one_write(ca, cb, 10**6 + order)))
                    order += 1
                row[how + "_evict_ms"] = statistics.median(t[0] for t in took)
                row[how + "_first_write_ms"] = statistics.median(t[1] for t in took)
            ca.drain(0.2)
            time.sleep(HIBERNATE)
            row["hibernated_first_write_ms"] = one_write(ca, cb, 10**6 + order)
            row["after_ms"] = one_write(ca, cb, 10**6 + order + 1)
            order += 2
            print(json.dumps(row), flush=True)
            results.append(row)
            a.stop()
            b.stop()
    print(json.dumps(results, indent=1))


try:
    main()
finally:
    for p in e.procs:
        p.kill()
