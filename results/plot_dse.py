#!/usr/bin/env python3
"""Design space: measured area against measured accuracy.

Area from results/dse.csv (Yosys+ABC, mode-locked so each point is specialised
to one lane width). Accuracy from model/formats.py on a length-64 dot product.

The cost axis is cells per product per cycle, not cells: narrow modes buy lanes,
so a mode that is smaller AND does four products at once is cheaper twice over.
Plotting raw cells would hide the throughput half of the trade.
"""
import csv, pathlib, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "model"))
from formats import study_precision

ERR = {m: e for m, (_, _, e) in study_precision().items()}

rows = list(csv.DictReader(open(pathlib.Path(__file__).parent / "dse.csv")))
pts = [r for r in rows if r["arch"] != "baseline"]

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11.5, 4.6))

MARK = {"shared": "o", "split": "s"}
COL  = {"infer": "#3f7f5f", "rca": "#b04a4a", "ksa": "#4a6fb0"}

for r in pts:
    cells = int(r["cells_abc"]); lanes = int(r["lanes"])
    per_prod = cells / lanes
    ax1.scatter(per_prod, ERR[r["mode"]], s=90, marker=MARK[r["arch"]],
                c=COL[r["cpa"]], alpha=.85, zorder=3)

for cpa, c in COL.items():
    ax1.scatter([], [], c=c, label=f"CPA: {cpa}")
for arch, m in MARK.items():
    ax1.scatter([], [], c="#666", marker=m, label=f"arch: {arch}")
ax1.set_yscale("log")
ax1.set_xlabel("cells per product per cycle (Yosys+ABC)")
ax1.set_ylabel("RMS relative error, length-64 dot product")
ax1.set_title("Area-per-throughput vs accuracy")
ax1.grid(alpha=.3, which="both")
ax1.legend(fontsize=8, loc="center right")
for mode, dx in (("M16", 8), ("M8", 8), ("M4", 8)):
    xs = [int(r["cells_abc"])/int(r["lanes"]) for r in pts if r["mode"] == mode]
    ax1.annotate(mode, (max(xs) + dx, ERR[mode]), fontsize=9, va="center")

# area vs depth, the classic Pareto, per mode
for mode, mk in (("M16", "o"), ("M8", "s"), ("M4", "^")):
    sel = [r for r in pts if r["mode"] == mode]
    ax2.scatter([int(r["cells_abc"]) for r in sel],
                [int(r["depth_abc"]) for r in sel],
                marker=mk, s=90, label=mode, alpha=.85, zorder=3)
base = [r for r in rows if r["arch"] == "baseline"]
ax2.scatter([int(r["cells_abc"]) for r in base],
            [int(r["depth_abc"]) for r in base],
            marker="x", s=110, c="#333", label="baselines", zorder=3)
ax2.set_xlabel("cells (Yosys+ABC)")
ax2.set_ylabel("logic depth (ltp)")
ax2.set_title("Area vs depth, per mode")
ax2.grid(alpha=.3)
ax2.legend(fontsize=8)

fig.suptitle("Multi-precision MAC: 14 synthesised design points against measured accuracy",
             fontsize=11)
fig.tight_layout()
fig.savefig("dse_pareto.png", dpi=130)
print("wrote results/dse_pareto.png")

print("\ncheapest point per mode (cells per product per cycle):")
for mode in ("M16", "M8", "M4"):
    sel = [r for r in pts if r["mode"] == mode]
    best = min(sel, key=lambda r: int(r["cells_abc"]) / int(r["lanes"]))
    pp = int(best["cells_abc"]) / int(best["lanes"])
    print(f"  {mode:4s} {best['arch']:6s}/{best['cpa']:5s}  "
          f"{pp:7.1f} cells/product   err {ERR[mode]:.2e}")
