import sys, re
xs = sorted(float(m.group(1)) for m in (re.search(r"roster in ([0-9.]+)", l) for l in sys.stdin) if m)
if xs:
    q = lambda p: xs[min(len(xs) - 1, int(len(xs) * p))]
    print(f"roster in: n {len(xs)} p50 {q(.5):.2f}s p90 {q(.9):.2f}s p99 {q(.99):.2f}s max {xs[-1]:.2f}s")
