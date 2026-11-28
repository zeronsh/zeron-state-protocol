import os, sys, time, statistics
d = os.path.join(sys.argv[1], "fsync-probe")
os.makedirs(d, exist_ok=True)
times, opens = [], []
for i in range(200):
    t = time.perf_counter()
    with open(os.path.join(d, f"f{i % 20}"), "ab") as f:
        f.write(os.urandom(4096))
        f.flush()
        os.fsync(f.fileno())
    times.append((time.perf_counter() - t) * 1000)
for i in range(100):
    t = time.perf_counter()
    p = os.path.join(d, f"n{i}")
    with open(p, "wb") as f:
        f.write(b"x")
    os.remove(p)
    opens.append((time.perf_counter() - t) * 1000)
q = lambda xs, p: sorted(xs)[int(len(xs) * p) - 1]
print(f"{sys.argv[1]}: write+fsync ms p50 {statistics.median(times):.2f} p99 {q(times, .99):.2f} max {max(times):.2f}; create+remove ms p50 {statistics.median(opens):.2f} p99 {q(opens, .99):.2f}")
