"""What a relay's checkpoints cost and how fast it wakes after, by how a space is written: python3 bench/policy.py

Against a relay deployed with STATS set (ZSP_CLOUD=https://..., ZSP_CLOUD_TOKEN), or under workerd here. Each way of
writing has a space of its own: as fast as it can be written, steadily for a while, or a little at a time as people
type. What the relay did is counted and priced; then it is left to hibernate, and what is next written is timed to
another device, which is what waking costs whoever writes next."""

import json, os, sys, time, urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tests"))
import end_to_end as e

CLASS_A, CLASS_B, ROW_WRITTEN = 4.50e-6, 0.36e-6, 1.00e-6
HIBERNATE = float(os.environ.get("ZSP_HIBERNATE", "20"))
WAYS = [  # name, rows, bytes a row, writes a second (0: as fast as it can)
    ("bulk", 1500, 16 << 10, 0),
    ("steady", 300, 16 << 10, 20),
    ("chat", 300, 200, 10),
]


def stats(cloud, sid):
    url = cloud.url.replace("ws", "http", 1) + "/" + sid + "?stats"
    return json.loads(urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "zsp-bench"})).read())


def quiet(cloud, sid):
    def still():
        a = stats(cloud, sid)
        time.sleep(2)
        b = stats(cloud, sid)
        return all(a["storage"][k] == b["storage"][k] for k in ("gets", "puts", "deletes", "rowsWritten"))

    e.eventually("the relay is quiet", still, timeout=180)


def one_write(ca, cb, order):
    t = time.monotonic()
    ca.put(1, "w", order, [b"x" * 100])
    cb.until(lambda: any(o == order for o, _, _ in cb.list(1, "w")), timeout=60)
    return (time.monotonic() - t) * 1e3


def main():
    cloud = e.Cloud().start(ACCESS_TOKEN="bench")
    results = []
    for i, (name, rows, size, rate) in enumerate(WAYS):
        if os.environ.get("ZSP_WAYS") and name not in os.environ["ZSP_WAYS"].split(","):
            continue
        _, (a, b) = e.space(f"pa{i}", f"pb{i}", relay=cloud, options=["--credential=" + cloud.token])
        sid = e.zspd_space(a)
        ca, cb = a.client(), b.client()
        cb.watch(1, 1, "w", limit=20, back=True)
        cb.until(lambda: 1 in cb.windows, timeout=60)
        ca.put(1, "w", 0, [b"first"])
        cb.until(lambda: len(cb.list(1, "w")) == 1, timeout=60)
        quiet(cloud, sid)
        s0 = stats(cloud, sid)
        t = time.monotonic()
        for n in range(rows):
            ca.put(1, "w", 1000 + n, [os.urandom(size)])
            if rate:
                time.sleep(max(0, t + (n + 1) / rate - time.monotonic()))
        cb.until(lambda: any(o == 1000 + rows - 1 for o, _, _ in cb.list(1, "w")), timeout=600)
        took = time.monotonic() - t
        quiet(cloud, sid)
        s1 = stats(cloud, sid)
        d = {k: s1["storage"][k] - s0["storage"][k] for k in ("puts", "gets", "rowsWritten", "put")}
        mb = rows * size / 1e6
        dollars = d["puts"] * CLASS_A + d["gets"] * CLASS_B + d["rowsWritten"] * ROW_WRITTEN
        row = {
            "way": name, "mb": round(mb, 2), "seconds": round(took, 1),
            "checkpoints": s1["node"]["checkpoints"] - s0["node"]["checkpoints"],
            "extents": s1["node"]["extents"] - s0["node"]["extents"],
            **d, "dollars": dollars, "dollars_per_mb": dollars / mb,
        }
        ca.drain(0.2)
        time.sleep(HIBERNATE)
        row["hibernated_first_write_ms"] = round(one_write(ca, cb, 10**6))
        row["after_ms"] = round(one_write(ca, cb, 10**6 + 1))
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
