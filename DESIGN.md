# Multi-precision MAC — design and first analysis

What is built, what was verified, and what the numbers say — including where
the first reading of the numbers turned out to be wrong.

Everything below reproduces from a clean clone with Yosys, Verilator,
SymbiYosys, eqy and z3 on `PATH` (Vivado additionally for the FPGA numbers);
see the README for versions.

```bash
python3 model/mpmac.py                          # golden model self-check
./sweep_mac.sh                                  # Yosys area + depth
cd formal && eqy -f mpmac_eq.eqy                # the two architectures agree
cd ../fpga && vivado -mode batch -source ooc.tcl  # LUT/FF/DSP + real timing
```

## What it is

One 16×16 datapath, three runtime modes, one 48-bit accumulator file that is
**partitioned** rather than replicated:

| mode | lanes | operands | product | lane acc | headroom |
|---|---|---|---|---|---|
| `M16` | 1 | 16 × 16 | 32 bit | 48 bit | 16 bit |
| `M8`  | 2 |  8 × 8  | 16 bit | 24 bit |  8 bit |
| `M4`  | 4 |  4 × 4  |  8 bit | 12 bit |  4 bit |

Every mode uses the same 16 sub-products `a_i·b_j` over 4-bit digits. Only the
enable mask, the weights and the lane boundaries change. Signedness is handled
by sign-extending **only the top digit of each lane**, which is exactly what
two's complement means:

> A = Σ_{i<top} a_i·2^4i + ã_top·2^4top

`model/mpmac.py` proves that identity against a direct `*` reference —
exhaustively for `M4` and for a full 8×8 lane, random elsewhere, zero
mismatches. It ran before any Verilog existed, which is the only reason the RTL
debug was short.

### Variants

| | `mpmac_split` (V1) | `mpmac_shared` (V2) |
|---|---|---|
| Reduction | three separate networks, one per mode | one masked placement network |
| Accumulate | three separate adder sets, output mux | one segmented adder tree |
| Mode touches | which network's result is written | the enable masks, three carry-break gates |
| Shared | the 16 sub-multipliers only | everything except masks and carry gates |

V2's segmented adder is four 12-bit blocks whose carry chain is broken at the
lane boundaries: `M16` merges all three boundaries, `M8` the outer two, `M4`
none. The carry-propagate structure inside those blocks is a parameter —
inferred `+`, `rca`, or `ksa` from `rtl/adders.v` (`mpmac_rca`, `mpmac_ksa`).

## Verification

| Check | Result |
|---|---|
| Python decomposition vs direct `*` | 0 mismatches |
| `mpmac_split` (V1) vs independent golden | 1,467,310 checks, 0 errors |
| `mpmac_shared` (V2) vs same golden | 1,467,310 checks, 0 errors |
| `mpmac_rca`, `mpmac_ksa` vs same golden | 1,467,310 checks each, 0 errors |
| `mac_separate` (B1) vs same golden | 1,467,310 checks, 0 errors |
| **V1 ≡ V2** | **`eqy`: proved equivalent**, 341 partitions, 141 s |
| **inferred `+` ≡ `rca` ≡ `ksa`** | **`sby` + z3: PASS**, exhaustive, < 1 s |

The testbench golden slices the operands and multiplies with `*`; it shares no
structure with the DUT's digit decomposition, which is what makes agreement
mean anything. Stimulus is weighted toward the failure mode this design
actually has — lane crosstalk. Every directed test drives **one** lane and
asserts the others are exactly zero, including negative products (which must
not sign-extend past their own lane) and a 64-deep overflow soak that pushes
`M4` past its 4-bit headroom to confirm the carry stops at the boundary.

> **Caveat on B1.** `mac_separate` is not equivalent to `mpmac` in general: it
> has seven independent accumulators, so switching mode mid-accumulation
> selects a different register, where `mpmac` reinterprets the same 48 shared
> bits. The testbench resets between mode groups, so the 1,467,310 passing
> checks establish agreement *under that discipline*, not equivalence.

### What formal caught that 1.47 M simulation vectors did not

`eqy` returned a counterexample at `mode = 2'b11`, an unused code. V1's if-else
chain falls through to `M4`; V2's carry gates were written as `mode != M4`, so
the illegal code got `M8` lane merging with `M4` term placement. The designs
genuinely differed, and no amount of directed simulation would have found it,
because the testbench only drives legal modes.

Fixed by decoding positively in both (`mode == M16 || mode == M8`) so any
unused code means `M4`. Re-run: proved equivalent.

The point is not that the bug was severe — an illegal mode encoding may never
be driven. It is that directed simulation cannot find this class of difference
at all, however many vectors it runs, because the testbench only generates
inputs someone thought of.

### Proving the CPA swap at the right level

Equivalence of the three carry-propagate choices was first attempted on the
whole MAC, and `eqy` was heading for roughly 3½ minutes per accumulator bit
partition — hours. But `seg_add48` is the *only* thing that differs between
`mpmac_shared`, `mpmac_rca` and `mpmac_ksa`, so proving the block proves the
three MACs equivalent by substitution. As a combinational miter
(`formal/miter_seg.v`, 98 inputs → 48 outputs) it closes in under a second.

Picking the right proof granularity was worth more than any solver tuning
here — the same lesson `SWEEP.md` records about `abc` not inventing structure.

## Numbers, part 1 — Yosys generic cells

Yosys 0.68 + ABC, generic `AND/OR/XOR`, `flatten` before `techmap`, same flow
as `sweep.sh`.

| design | as-written cells/depth | after ABC cells/depth | FF bits | logic cells |
|---|---|---|---|---|
| `mpmac_split`  V1 | 7789 / 345 | 4886 / 388 | 48 | 4838 |
| `mpmac_shared` V2 | 6997 / 293 | **4435 / 274** | 48 | 4387 |
| `mac_separate` B1 | 4534 / 275 | 4333 / 261 | **144** | 4189 |
| `mac_fixed16`  B2 | 2515 / 274 | 2454 / 264 | 48 | 2406 |

Read on its own this says: V2 beats V1 by 9.2% in cells and 29.4% in depth,
and loses to seven dedicated units by 2.4%. **Both halves of that reading turn
out to be wrong on real fabric.** Generic-cell counting scores a flip-flop the
same as an AND gate and knows nothing about carry chains or hard macros.

### Where the area goes

| block | cells (ABC) | delta |
|---|---|---|
| 16 × plain 4×4 **unsigned** multiply (`fe_unsigned`) | 1096 | — |
| 16 × 5×5 **signed**, mode/sgn constant-folded (`fe_static`) | 1352 | +256 signed widening |
| `mp_frontend`, mode and sign **runtime** | 2570 | +1218 runtime flexibility |

The three-way split matters. Making the sub-multipliers signed costs 256 cells;
making the mode and signedness *runtime-selectable* costs another 1218 — nearly
five times as much, and 27% of the whole design. For scale, the front end is
2570 of V2's 4435 cells (58%); everything else — placement, the segmented adder
tree and the accumulate — is the remaining 1865 (42%). The part the two
architectures argue about is not where the money is. The reason is specialisation: with
`mode` and `sgn` fixed, twelve of the sixteen sub-multipliers collapse to
narrow unsigned units, and only the top-digit ones stay 5×5 signed. A runtime
mode forbids that — every sub-multiplier must be full 5×5 signed all the time.

That puts a number on the cost of format-mixing, and it is the strongest
argument in this repo for **Baugh-Wooley** as the next move: keep all
sixteen sub-multipliers unconditionally 4×4 unsigned and push sign correction
into the reduction tree as a few mode-dependent constant rows. The recoverable
budget is the gap between 1096 and 2570, not merely the 256.

## Numbers, part 2 — Vivado, and the reversal

Vivado 2025.2, `xc7a100tcsg324-1`, out-of-context, 10 ns clock. Run twice:
`-max_dsp 0` forces LUT implementation for a fair architectural comparison,
while the default lets Vivado infer DSP48E1.

**LUT-only (`-max_dsp 0`) — the fair comparison:**

| design | LUT | FF | CARRY4 | WNS reg→reg | WNS worst |
|---|---|---|---|---|---|
| `mpmac_split`  V1 | **1046** | 48 | 158 | +1.402 | −2.537 |
| `mpmac_shared` V2 | 1351 | 48 | 245 | +2.690 | −6.353 |
| `mpmac_rca` | 1496 | 48 | 64 | −8.401 | −11.259 |
| `mpmac_ksa` | 2262 | 48 | 64 | +1.136 | −9.512 |
| `mac_separate` B1 | **948** | 144 | 150 | +6.744 | **+0.619** |
| `mac_fixed16`  B2 | 502 | 48 | 84 | +6.755 | +0.604 |

**Three things flip:**

1. **V1 beats V2 on LUTs by 23%** — the opposite of the Yosys verdict. V2 also
   carries 245 CARRY4 against V1's 158. Two explanations are consistent with
   that and this data does not separate them: V2's carry-break gates may
   fragment the CARRY4 chains, or V2 simply performs more wide addition
   (sixteen 48-bit segmented adds against three networks that are narrow at the
   leaves). Distinguishing them needs chain *lengths*, not counts. What is
   certain is the direction: generic cells have no notion of a dedicated carry
   resource, so they cannot rank these two designs, and they ranked them
   backwards.
2. **Hand-written adders lose to inferred `+`.** `mpmac_rca` and `mpmac_ksa`
   both use 64 CARRY4 against V2's 245 — writing the carry logic explicitly
   *prevents* Vivado from mapping it to the fast carry chain, and costs 11% and
   67% more LUTs respectively. On an FPGA, `+` is not laziness, it is the
   interface to a hard resource.
3. **Kogge-Stone wins on timing where `ltp` said it lost.** Yosys `ltp` scored
   `mpmac_ksa` *deeper* than `mpmac_rca` (354 vs 235 as-written). Real static
   timing says the opposite and by a wide margin: +1.136 ns against −8.401 ns
   reg-to-reg, a 9.5 ns swing. `ltp` counts topological levels and cannot
   weight them. This is the clearest evidence here for treating Yosys numbers
   as a fast structural sweep and Vivado numbers as the ones worth quoting.

**With DSP inference enabled**, the picture changes completely:

| design | LUT | FF | DSP |
|---|---|---|---|
| `mac_fixed16` B2 | 2 | 0 | 1 |
| `mac_separate` B1 | 463 | 96 | 1 |
| all `mpmac` variants | unchanged | 48 | **0** |

A behavioural `a*b + acc` maps into a single DSP48E1 — *including its
accumulator*, which is why B2's flip-flops disappear entirely. The
hand-decomposed datapath infers no DSPs at all: sub-word decomposition is
invisible to the inference pass. On a real Artix-7, asking for a 16-bit MAC and
getting one hard macro beats any LUT-built alternative outright.

### The honest verdict

**At 16 bits on this fabric, the shared multi-precision MAC does not pay for
itself.** Seven dedicated units are smaller (948 vs 1046 LUT), meet timing when
none of the shared variants do (+0.619 ns vs −2.537 ns), and map to DSPs when
allowed to. The accumulator-register saving (48 FF vs 144) is real but nearly
worthless on an FPGA, where every slice ships flip-flops next to LUTs whether
you use them or not.

What the shared unit still has is the thing the baselines cannot do: **produce
two or four independent products per cycle from the same operand ports**, which
a DSP48E1 will not do for multiplies. The case for it is throughput per operand
port, not area — and that is the case the README should make, because the area
case does not survive contact with Vivado.

## Width dependence, inside a single unit

The carry-propagate structure is one physical block serving three lane widths:
12 bits in `M4`, 24 in `M8`, 48 in `M16`. Synthesising `seg_add48` alone with
`mode` tied to a constant (as-written, structure preserved):

| lane width | `rca` cells/depth | `ksa` cells/depth | KS depth saved | KS cell cost |
|---|---|---|---|---|
| 12 (`M4`)  | 221 / 22 | 449 / 9  | 13 levels | 2.03× |
| 24 (`M8`)  | 233 / 46 | 539 / 11 | 35 levels | 2.31× |
| 48 (`M16`) | 239 / 94 | 590 / 15 | 79 levels | 2.47× |

This is `SWEEP.md`'s adder crossover reappearing inside the MAC's own
accumulator: at 12 bits Kogge-Stone buys 13 levels for 228 extra cells, a poor
trade; at 48 bits it buys 79 levels for 351, a good one.

**And here it is a genuine conflict rather than a free win.** In the standalone
adder study you simply pick the right adder per width. Here one block must serve
all three modes at once, so `M4` and `M16` want opposite answers out of the same
hardware. The width-dependence argument (ARITH 2022) arrives not as a menu to
choose from but as a constraint: the optimum is width-dependent *within a single
unit that cannot be specialised*.

The Vivado data adds the resolution: on this fabric neither hand-written adder
is the answer, because inferred `+` reaches the carry chain and they do not.

## Limits

- **One operand width.** Every number is 16-bit. Parameterising the digit count
  for 32- and 64-bit operands would test whether the shared-vs-separate verdict
  moves — the register saving scales with lane count while the runtime-mode
  overhead scales with digit count, so a crossover is plausible but unmeasured.
- **No per-mode proof against a dedicated unit.** Each mode ought to be proved
  equivalent to a dedicated fixed-width MAC — `M4` exhaustively, `M8`/`M16` via
  `eqy`. What exists instead is `mac_separate` passing the same testbench, which
  is agreement under a reset discipline, not equivalence (see the caveat above).
  Not done.
- **No place-and-route.** Post-synthesis timing only; routing will move the
  numbers, and the CARRY4 story especially.
- **`ltp` is a proxy.** ABC raises V1's depth (345 → 388) while cutting cells,
  optimising against a delay model it does not have. Treat every Yosys depth
  here as a structural indicator, nothing more — the Kogge-Stone case shows it
  can invert the true answer.
- **Narrow modes leave sub-multipliers idle** — `M16` uses 16/16, `M8` 8/16,
  `M4` 4/16. Not a design flaw: with 16-bit operand ports, four 4-bit lanes is
  all the operand bandwidth there is. Narrow modes buy lane parallelism, not
  throughput per gate. That is a property of the operand interface, not a
  shortcoming of the decomposition, but it should be stated plainly.

## Files

| Path | What |
|---|---|
| `model/mpmac.py` | golden model; proves the digit-decomposition algebra |
| `rtl/mpmac.v` | `mp_frontend`, `seg_add48`, V1, V2, CPA and mode-locked wrappers |
| `rtl/mac_ref.v` | `mac_unit`, `mac_separate` (B1), `mac_fixed16` (B2) |
| `tb/tb_mpmac.v` | self-checking TB; `-DDUT=<module>` selects the design |
| `formal/mpmac_eq.eqy` | V1 ≡ V2 (PASS) |
| `formal/equiv_seg.sby`, `formal/miter_seg.v` | inferred `+` ≡ `rca` ≡ `ksa` (PASS) |
| `sweep_mac.sh` | Yosys table |
| `fpga/ooc.tcl` | Vivado table, with and without DSP inference |
