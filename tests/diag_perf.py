import csv, sys, statistics
rows = list(csv.reader(open(sys.argv[1], encoding="utf-8", errors="replace")))
head, data = rows[0], rows[1:]
def col(name):
    i = next(k for k, h in enumerate(head) if name in h)
    out = []
    for r in data:
        try: out.append(float(r[i]))
        except (ValueError, IndexError): pass
    return out
cpu, cw, dw, cq, dq = col("Processor"), col("(C:)\\Avg. Disk sec/Write"), col("(D:)\\Avg. Disk sec/Write"), col("(C:)\\Current Disk Queue"), col("(D:)\\Current Disk Queue")
f = lambda xs: f"mean {statistics.mean(xs):.3g} max {max(xs):.3g}" if xs else "-"
print(f"{sys.argv[1]}: cpu% {f(cpu)} | C: write s {f(cw)} queue {f(cq)} | D: write s {f(dw)} queue {f(dq)}")
