# Design-space exploration, number formats, and a rewrite that needs a side-condition

Phase 2. Three things that Phase 1 pointed at but did not do: sweep the variant
space automatically, put an accuracy axis next to the area axis, and build a
concrete case where an algebraic identity is only valid under a bitwidth
condition.

```bash
./dse.sh                                   # 14 synthesised points -> results/dse.csv
python3 model/formats.py                   # accuracy study
cd results && python3 plot_dse.py          # the Pareto
cd formal && sby -f dist_wide.sby          # PASS
                sby -f dist_narrow.sby     # FAIL, with a counterexample
                sby -f dist_cond.sby       # PASS under the side-condition
```

## A rewrite that is only valid under a bitwidth condition

`a*b + a*c → a*(b+c)` is true over the integers and false in hardware, because
the intermediate `b+c` has a width. This is the concrete form of the
"sufficient condition" column in Coward, Constantinides & Drane (ARITH 2022,
Table II), where every rewrite carries a bitwidth side-condition for exactly
this reason.

Three circuits computing the same integer expression, `rtl/distribute.v`:

| module | intermediate | result |
|---|---|---|
| `dist_expanded` | none — two multiplies | reference |
| `dist_wide` | `b+c` in W+1 bits | **proved equal, unconditionally** |
| `dist_narrow` | `b+c` truncated to W bits | **proved unequal** |
| `dist_narrow` + assumption | same circuit, `b+c` constrained not to overflow | **proved equal** |

The counterexample the solver returns for the narrow case, at W=4:

```
a = 1,  b = 12,  c = 4
a*b + a*c        = 16
b + c            = 16  ->  truncated to 4 bits = 0
a * ((b+c) mod 16) = 0
```

One input triple out of 4096. The narrow circuit is the *cheaper* one, which is
the whole problem: a rewriter that applies the identity unconditionally produces
a smaller design that is wrong on a subset of inputs no directed test is likely
to visit. The condition is not a footnote on the rewrite — it is the rewrite.

Worth recording: the same proof at **W=8 did not close in ten minutes**, while
W=4 closes instantly. Multiplier equivalence is the classic hard case for
bit-blasting SMT, and it is why the equivalence work elsewhere in this
repository is careful to pick the smallest block that carries the obligation.

## Design-space exploration

`dse.sh` generates and synthesises the cross product of architecture ×
carry-propagate structure × precision mode, locking `mode` to a constant so each
point is specialised to one lane width. 14 points, `results/dse.csv`.

![design space](results/dse_pareto.png)

Cheapest point per mode, measured as **cells per product per cycle** — narrow
modes buy lanes, so raw cell count hides half the trade:

| mode | best variant | cells/product | RMS relative error |
|---|---|---|---|
| `M16` | shared / rca | 2641.0 | 4.91e-04 |
| `M8`  | split / infer | 733.5 | 1.08e-01 |
| `M4`  | split / infer | 223.5 | 1.88e+00 |

**`M4` is 12× cheaper per product than `M16` and 3800× less accurate.** On a
general length-64 dot product a 4-bit lane produces a 188% RMS error, which is
not a usable answer at any price. `M8` is 3.5× cheaper for a 10.8% error.

So the Pareto is real but steep, and the useful conclusion is a conditional one:
the narrow modes only pay for themselves in an application that can absorb that
error. That is precisely the premise of error-tolerant design-space exploration
— the ARITH 2020 line of work — though that paper is paywalled here and this
note relates to the *idea*, not to its contents.

## Number formats at a fixed width

`model/formats.py`. Posit values are obtained by decoding all 2^16 bit patterns
and quantising to the nearest, which is obviously correct and cheap; the decoder
is checked against `maxpos = useed^(n-2) = 4^14 = 2^28`.

RMS relative error on the same length-64 dot product:

| format | uniform [-1,1) | wide, 8 decades |
|---|---|---|
| fixed Q1.15 | **4.91e-04** | 1.00e+00 |
| IEEE binary16 | 3.84e-03 | **2.09e-02** |
| posit(16,1) | 1.20e-03 | 1.96e-01 |

**The ranking inverts, and posit is second in both columns.** Fixed point wins
where the range is known and bounded — and fails outright where it is not.
Posit(16,1) beats binary16 by 3× near 1, where its tapered accuracy spends bits
on the fraction. Binary16 beats posit by 9× across 8 decades, because out at the
extremes the regime field has eaten the bits the fraction needed.

Tapered accuracy is a bet that the data sits near 1, not a free win. That is the
useful thing to be able to say about posits, and it is close to the opposite of
how they are usually pitched.

**No area number belongs beside this table.** There is no float or posit RTL
here, and inventing a cost model to fill the column would be worse than leaving
it empty. Only the fixed-point row has hardware behind it, and that hardware is
in `results/dse.csv`.

## Automating it: the same condition as an e-graph rewrite

`egraph/` is a small `egg` optimiser that carries bitwidth as an e-class
analysis and applies distributivity **only where the intermediate fits**. It is
the automated form of the section above, and the mechanism behind the
"sufficient condition" column of ARITH 2022's rewrite table.

```
operands         datapath  guarded: extracted    cost   unguarded: extracted  cost
a:8,b:8,c:8            16  (* a (+ b c))          110   (* a (+ b c))          110   sum needs 9 of 16  -- sound
a:8,b:15,c:15          16  (* a (+ b c))          110   (* a (+ b c))          110   sum needs 16 of 16 -- sound
a:8,b:16,c:16          16  (+ (* a b) (* a c))    210   (* a (+ b c))          110   sum needs 17 of 16 -- BLOCKED
a:4,b:32,c:32          32  (+ (* a b) (* a c))    210   (* a (+ b c))          110   sum needs 33 of 32 -- BLOCKED
```

The analysis propagates bits the way the arithmetic does — a sum carries one
bit past its widest operand, a product needs the sum of its operands' widths —
and `merge` takes the tighter of two bounds, since both are valid.

Running the *same* rewrite with its guard removed factors two more cases and
halves the cost. Those two circuits are exactly the ones `dist_narrow.sby`
refutes: smaller, cheaper by the cost model, and wrong. **The guard is not a
conservatism knob; it is the difference between an optimiser and a bug
generator** — which is why the interesting part of automated datapath rewriting
is the side-conditions rather than the search.

The cost model is deliberately crude (multiplier 100, adder 10). It only has to
rank one multiply against two; ARITH 2022 uses a two-input-gate estimate
parameterised by operand width, and validates it against logic synthesis.

## Does the verdict move with operand width?

At 16 bits the shared multi-precision MAC and seven dedicated units are within
a couple of percent of each other. The whole premise of width-dependent
optimality is that such a result does not transfer, so `rtl/mpmac_gen.v`
generalises the architecture over operand width and `sweep_width.sh` re-measures
it. Verified at all three widths against a golden model first — 120,000 checks
each, zero errors, for both the shared design and the dedicated baseline.

Structure-preserving counts (`proc/opt/techmap/opt`), which complete at every
width:

| W | shared `mpmac_gen` | dedicated `mac_sep_gen` | ratio | shared depth | dedicated depth |
|---|---|---|---|---|---|
| 16 | 7583 | 4535 | **1.67×** | 295 | 275 |
| 32 | 42574 | 14243 | **2.99×** | 614 | 561 |
| 64 | 235744 | 47527 | **4.96×** | 1321 | 1135 |

**The verdict moves, and it moves hard against the shared design.** Its cost
grows roughly as W^2.5 while the dedicated baseline grows as W^1.7, so the gap
triples between 16 and 64 bits.

The mechanism is the reduction network, not the multipliers. Sub-products are
always 4×4 and there are (W/4)² of them — quadratic, matching the dedicated
multiplier. But every one of them is *placed into a full 3W-bit accumulator
field* before being summed, so the adder tree carries (W/4)² terms of 3W bits:
**cubic in W**. A dedicated multiplier reduces its partial products at their
natural narrow width and only widens at the end.

That is a fixable architectural mistake rather than a fact about multi-precision
arithmetic: reducing sub-products within their lane before placing them, the way
a Wallace or Dadda tree does, would bring the reduction back to quadratic. This
design does not do it, and at 16 bits the cost is invisible.

**Confidence, stated honestly.** These are as-written counts. At W=16 ABC
changes the answer — it takes the shared design from 7583 to 4322 and the
dedicated from 4535 to 4398, turning a 1.67× loss into a marginal win. So
technology mapping matters a great deal here, and only the shared design's ABC
number is available at W=32 (17822 cells); the dedicated baseline's did not
complete in 25 minutes, because technology-mapping a behavioural 32×32 multiply
is expensive and 64×64 is worse. A ratio that triples is very unlikely to be a
mapping artefact, but the 32- and 64-bit rows are indicative rather than
settled, and saying otherwise would be overclaiming from one measured column.

## Limits

- The accuracy study quantises the *inputs* and accumulates in double. Real
  hardware also quantises the accumulator, which the 48-bit lane file makes a
  small effect here but not a zero one.
- Two workloads is not a survey. The point is that the ranking depends on the
  distribution, not that these two distributions are representative.
- `dse.sh` explores a space someone hand-wrote. The `egraph/` optimiser does
  generate alternatives, but over one rewrite on scalar expressions — not over
  the RTL that `dse.sh` synthesises. Closing that loop, so the extracted
  expression becomes the design that gets measured, is the real gap.
- The width analysis tracks an upper bound, not a range. It cannot see that
  `b+c` fits because `b` and `c` happen to be small at runtime — only that
  their declared widths allow it.
- The width study has ABC numbers at 16 bits only for both designs. The
  cross-width conclusion rests on structure-preserving counts, which the 16-bit
  row shows can differ from the mapped result in direction, not just magnitude.
- `mpmac_gen` is a generalisation of the architecture, not the same netlist as
  `mpmac_shared`: it folds the reduction linearly rather than as a balanced
  tree. It is verified independently, but the two are not interchangeable and
  their cell counts are not directly comparable.
