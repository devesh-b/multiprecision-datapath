# multiprecision-datapath

A format-flexible multiply-accumulate unit in Verilog: one 16×16 datapath that
runs as **1×16-bit, 2×8-bit, or 4×4-bit** lanes at runtime, sharing a single
48-bit accumulator file that is partitioned per mode rather than replicated.

Two architectures are built and formally proved equivalent, measured against
two baselines through both a technology-independent flow (Yosys + ABC) and a
real FPGA flow (Vivado, Artix-7). The interesting part is that **the two flows
disagree**, twice, and the generic-cell flow is the one that gets it wrong.

Full design notes, numbers and analysis: **[DESIGN.md](DESIGN.md)**.
Standalone adder width study: **[SWEEP.md](SWEEP.md)**.

## Results in brief

- Vivado ranks the two architectures **opposite** to how Yosys generic cells
  rank them — a 23% LUT difference in the other direction. Generic cells have
  no notion of a dedicated carry chain.
- Hand-written ripple and Kogge-Stone adders **lose to an inferred `+`**,
  because writing the carry logic explicitly locks the design out of the
  CARRY4 fast-carry path (64 CARRY4 against 245).
- Yosys `ltp` scores Kogge-Stone as the *deeper* design; static timing says it
  is **9.5 ns faster** on the accumulator loop. `ltp` counts topological levels
  and cannot weight them.
- At 16 bits the shared multi-precision unit **does not beat** seven dedicated
  per-format units on area or timing. Its surviving advantage is throughput per
  operand port, which is the honest case for it.
- Equivalence checking found a real difference between the two architectures at
  an unused mode encoding that 1.47 M directed simulation vectors did not.

## Layout

| Path | What |
|---|---|
| `rtl/mpmac.v` | the MAC: shared front end, segmented adder, both architectures |
| `rtl/adders.v` | ripple, serial-carry and Kogge-Stone adders, swappable |
| `rtl/mac_ref.v` | baselines: dedicated per-format units, and a fixed 16-bit unit |
| `model/mpmac.py` | golden model; proves the digit-decomposition algebra |
| `tb/tb_mpmac.v` | self-checking testbench, `-DDUT=<module>` picks the design |
| `formal/` | equivalence proofs (SymbiYosys + z3, eqy) |
| `fpga/` | Vivado out-of-context synthesis and its results |
| `sweep.sh`, `sweep_mac.sh` | Yosys area/depth sweeps |

## Requirements

- Yosys 0.68+ with ABC, SymbiYosys, eqy, z3 — all in the
  [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
- Verilator 5.05+
- Python 3.10+ (standard library only)
- Vivado 2025.2 for the FPGA numbers — optional, everything else runs without it

## Reproduce

With the tools above on `PATH`, from a clean clone:

```bash
python3 model/mpmac.py                       # golden model self-check

verilator --binary --timing -sv rtl/adders.v rtl/mpmac.v tb/tb_mpmac.v \
  --top-module tb_mpmac -o sim -DDUT=mpmac_shared \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-TIMESCALEMOD -Wno-DECLFILENAME
./obj_dir/sim                                # 1,467,310 self-checked vectors

./sweep.sh                                   # adder width study
./sweep_mac.sh                               # MAC area/depth vs baselines

cd formal && sby -f equiv_seg.sby            # carry-propagate variants agree
eqy -f mpmac_eq.eqy                          # the two architectures agree (~2.5 min)

cd ../fpga && vivado -mode batch -source ooc.tcl   # LUT/FF/DSP + timing
```

## Licence

MIT.
