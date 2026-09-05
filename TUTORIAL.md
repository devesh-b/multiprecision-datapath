# How this datapath works, from the beginning

A ground-up explanation of everything in this repository. It assumes you know
what a bit is and roughly what a logic gate does, and nothing else. By the end
you should be able to read every file here and know why each line is the way it
is — including the parts that turned out to be wrong.

---

## 1. What problem is this repository solving?

Computers multiply numbers together and add up the results. That single
operation — multiply two numbers, add the answer to a running total — is called
a **multiply-accumulate**, or MAC. It is the innermost loop of almost everything
numerically interesting: filtering audio, rendering graphics, and in particular
running a neural network, where the vast majority of the work is multiplying
weights by activations and summing them.

Because it is the innermost loop, hardware designers build dedicated circuits
for it. And because a chip has a fixed area, how *efficiently* you build that
circuit determines how many of them fit, which determines how fast the whole
system runs.

Now the twist this repository is about. Different applications need different
**precision**. A scientific simulation might need 32 or 64 bits per number. A
neural network doing image classification often works fine with 8 bits, and
sometimes with 4. Using 32-bit hardware to multiply 4-bit numbers wastes most of
the circuit.

So: could you build **one** multiplier that runs as a single 16-bit unit when
you need precision, or as four independent 4-bit units when you don't — sharing
the same silicon either way?

That is a **multi-precision datapath**, and building one, measuring it honestly,
and proving it correct is what this repository does.

The short answer, which we will earn over the next several thousand words, is:
you can build it, it works, and at 16 bits it is *not* obviously worth it. The
interesting part is why, and how many of our confident predictions the
measurements contradicted.

---

## 2. Numbers in hardware

### 2.1 Binary, and why hardware likes it

A wire is either at a high voltage or a low one. Call those 1 and 0. That is a
**bit**. To represent a number bigger than 1 you use several wires and agree on
what each one means.

The usual agreement is place value, base 2. With four wires `b₃ b₂ b₁ b₀`:

```
value = b₃·8 + b₂·4 + b₁·2 + b₀·1
```

So `1011` is 8 + 0 + 2 + 1 = 11. Each bit's **weight** is a power of two, and
the leftmost bit is the **most significant** because it contributes most.

An n-bit number can hold 0 to 2ⁿ−1. Four bits: 0 to 15. Sixteen bits: 0 to
65535. This matters constantly in hardware, because unlike in software the width
is a physical thing you paid for in wires and transistors.

### 2.2 Negative numbers: two's complement

We need negatives. The scheme everyone uses is **two's complement**, and it is
worth understanding properly because it is the source of one of the subtler
tricks in this design.

The rule: keep place value exactly as before, but make the **top bit's weight
negative**. For four bits:

```
value = −b₃·8 + b₂·4 + b₁·2 + b₀·1
```

Now `1011` is −8 + 0 + 2 + 1 = −5. The range is −8 to +7: still sixteen distinct
values, just shifted.

Why this scheme and not something more obvious like "one bit for the sign"?
Because **addition circuitry does not need to change at all.** Add two
two's-complement numbers using exactly the ordinary binary adder, throw away any
carry that falls off the top, and the answer is correct. Negative numbers come
out right for free. That is an enormous saving, and it is why essentially all
hardware uses it.

A consequence we will need later: in two's complement, **the top bit is the only
one carrying a sign**. Every other bit has an ordinary positive weight. Hold on
to that.

### 2.3 Wrapping

If you add 1 to the largest 4-bit value (`0111` = 7) you get `1000`, which is
−8. The number **wrapped around**. In software this is usually a bug; in
hardware it is simply what a fixed number of wires does, and you design around
it. Mathematically, an n-bit adder computes the true sum **modulo 2ⁿ** — it
keeps the remainder after dividing by 2ⁿ.

"Modulo" will come up a lot. `a mod n` means the remainder when you divide `a`
by `n`. `17 mod 5 = 2`. Wrapping is just arithmetic modulo 2ⁿ, and thinking of
it that way makes several later arguments much easier.

---

## 3. Adding

Multiplication is built from addition, so we start there.

### 3.1 Ripple-carry: the obvious way

To add two numbers by hand you go column by column, right to left, carrying when
a column overflows. Hardware does the same. For each bit position you build a
**full adder**: a small circuit taking two input bits and a carry-in, producing
a sum bit and a carry-out.

```
sum      = a XOR b XOR carry_in
carry_out = (a AND b) OR (carry_in AND (a XOR b))
```

Chain n of these, feeding each carry-out into the next carry-in, and you have an
n-bit **ripple-carry adder**. It is in `rtl/adders.v` as `rca`.

It is small and it is simple. It also has a serious problem.

### 3.2 Why ripple-carry is slow

The top bit's answer cannot be computed until the carry has travelled all the
way from the bottom. Adding `0001` + `1111`, the carry generated at bit 0
propagates through every position. The circuit's **delay** is therefore
proportional to n: doubling the width doubles the time.

In our measurements a 12-bit ripple adder has a logic depth of 25 and a 48-bit
one has depth 97 — almost exactly four times, as the theory says.

That linear growth is the central problem of computer arithmetic. Almost every
clever adder design is an attempt to beat it.

### 3.3 Parallel prefix: computing carries in advance

The trick is to stop treating carries as something that arrives and start
treating them as something you can **compute directly**.

For each bit position define two signals:

- **generate**, `g = a AND b`. If both inputs are 1, this position produces a
  carry no matter what arrives from below.
- **propagate**, `p = a XOR b`. If exactly one input is 1, this position passes
  along whatever carry arrives.

Then the carry into position i+1 is:

```
c[i+1] = g[i] OR (p[i] AND c[i])
```

Still recursive — but this form can be *combined*. If you know how a block of
bits behaves as a whole (does it generate a carry? does it propagate one?), you
can join two adjacent blocks into a bigger block in one step:

```
G = G_high OR (P_high AND G_low)
P = P_high AND P_low
```

Combine pairs, then pairs of pairs, and so on. After log₂(n) rounds you know the
carry into every position. This is a **parallel prefix** adder; the specific
arrangement in `rtl/adders.v` is a **Kogge-Stone** adder, `ksa`.

The delay is now proportional to log₂(n), not n. Going from 12 to 48 bits, a
ripple adder's depth goes 25 → 97, while Kogge-Stone goes 10 → 14.

Nothing is free. Kogge-Stone computes many more intermediate signals, so it
needs far more gates: at 48 bits, 915 cells against ripple's 240. Roughly four
times the area to be seven times shallower.

### 3.4 The first real lesson: it depends on the width

`SWEEP.md` in this repository measures both adders at 8, 16, 32 and 64 bits. The
pattern is the point:

| width | ripple depth | Kogge-Stone depth | KS cost |
|---|---|---|---|
| 8 | 17 | 14 | 1.3× the cells |
| 16 | 33 | 22 | 1.6× |
| 32 | 65 | 27 | 2.0× |
| 64 | 129 | 34 | 2.3× |

At 8 bits, Kogge-Stone saves you 3 levels of depth and costs 30% more area — a
poor trade. At 64 bits it saves 95 levels for 130% more area — an excellent one.

**Same two designs. Opposite verdicts. The only thing that changed is the
width.** This is the central claim of the research literature this work engages
with (Coward, Constantinides & Drane, ARITH 2022): the optimal arithmetic
circuit is *width-dependent*, so what you want is not one design but a library,
and a way of choosing between them.

Keep this in mind. It comes back at the very end, and it bites.

---

## 4. Multiplying

### 4.1 Long multiplication, in binary

You already know the algorithm from primary school. Multiply the top number by
each digit of the bottom number, shift each result left by the appropriate
amount, add everything up.

Binary makes it easier, because each digit is 0 or 1. Multiplying by a binary
digit is either "copy it" or "use zero". So:

```
      1011   (11)
    × 1101   (13)
    ------
      1011   ← bottom bit is 1, copy, shift 0
     0000    ← next bit is 0, zero,  shift 1
    1011     ← next bit is 1, copy,  shift 2
   1011      ← top bit is 1,  copy,  shift 3
   --------
  10001111   (143)
```

Each shifted copy is a **partial product**. Multiplication in hardware is:
generate the partial products (trivial — AND gates), then add them all up. The
adding is the expensive part, and it is why multipliers are large.

Multiplying two n-bit numbers gives up to 2n bits. 16 × 16 needs 32 bits.

### 4.2 Splitting a multiply into smaller multiplies

Here is the idea the whole design rests on.

Write a 16-bit number as four 4-bit **digits**:

```
A = a₃·2¹² + a₂·2⁸ + a₁·2⁴ + a₀
```

Each `aᵢ` is 0–15. This is just base-16 (hexadecimal), which is why hex is
convenient for binary.

Now multiply two such numbers. Ordinary algebra:

```
A × B = (Σᵢ aᵢ·2⁴ⁱ) × (Σⱼ bⱼ·2⁴ʲ) = Σᵢ Σⱼ (aᵢ × bⱼ) · 2⁴⁽ⁱ⁺ʲ⁾
```

In words: **a 16×16 multiply is sixteen 4×4 multiplies, each shifted left by
4(i+j) and added together.**

That is the key structural fact. We build sixteen small multipliers and a
network that shifts and sums their outputs.

### 4.3 Why this buys multi-precision

Look at what happens if you only want four independent 4-bit multiplies. You
need `a₀×b₀`, `a₁×b₁`, `a₂×b₂`, `a₃×b₃` — four of the sixteen sub-products you
already have. Don't shift them; keep them separate.

Want two independent 8-bit multiplies? The low half is `{a₁,a₀} × {b₁,b₀}`,
which uses sub-products (0,0), (0,1), (1,0), (1,1) — four of the sixteen, shifted
and summed among themselves. The high half uses the other diagonal block.

**The same sixteen multipliers serve all three modes.** What changes is which
sub-products you use and how you combine them. That is the entire idea, and
everything else is consequences.

Three modes, then:

| mode | what it computes | products per cycle |
|---|---|---|
| `M16` | one 16×16 | 1 |
| `M8` | two independent 8×8 | 2 |
| `M4` | four independent 4×4 | 4 |

### 4.4 Signed digits: a trick worth understanding

Splitting into digits works cleanly for positive numbers. Negatives need care,
and the solution is elegant.

Recall that in two's complement only the top bit is negative. Now split into
digits. The top *digit* contains the top bit, so the top digit is the only one
carrying a sign. Every other digit is an ordinary positive 0–15.

Formally, if `A` is a 16-bit two's-complement number:

```
A = a₀ + a₁·2⁴ + a₂·2⁸ + ã₃·2¹²
```

where `a₀, a₁, a₂` are unsigned 0–15 and `ã₃` is the top digit read as *signed*
4-bit, i.e. −8 to +7.

Let us check this is really true. Two's complement says
`A = −A₁₅·2¹⁵ + (bits 14..0)`. Reading all four digits as unsigned gives
`A_unsigned = Σ aᵢ·2⁴ⁱ`, and the signed value is `A_unsigned − A₁₅·2¹⁶`. Since
`ã₃ = a₃ − 16·A₁₅`, we get `ã₃·2¹² = a₃·2¹² − A₁₅·2¹⁶`. Substituting back gives
exactly the right answer. It works.

So the rule is: **sign-extend only the top digit of each lane; leave the rest
unsigned.** In `M4` every digit is the top digit of its own lane, so all four are
signed. In `M8` digits 1 and 3 are tops. In `M16` only digit 3 is.

In `rtl/mpmac.v` this is the `top[i]` signal in `mp_frontend`, and the whole
sign-handling cost of the design is those few multiplexers plus one extra bit of
width on each sub-multiplier.

That extra bit matters more than you would guess, and section 11 measures it.

---

## 5. Accumulating

A MAC does not just multiply — it adds into a running total. That total lives in
a register called the **accumulator**.

The accumulator must be wider than the product, because you are adding many
products together. A 16×16 signed product needs 32 bits; adding 65,536 of them
could need 16 more. Those extra bits are called **headroom** or **guard bits**.

We chose a **48-bit** accumulator, which gives 16 bits of headroom in `M16`. 48
is not arbitrary: it is the width of the accumulator inside a Xilinx DSP48 block,
so comparisons against real FPGA hardware are meaningful.

### 5.1 Partitioning, not replicating

Here is a decision that shapes everything. In `M4` we produce four independent
results. Do we need four separate 48-bit accumulators?

No — and giving each lane a full 48 bits would be a mistake. It would mean the
narrow modes need *more* register area than the wide one, and at that point you
have not built one shared unit, you have built three separate units sharing a
name. The dedicated-units baseline would win by definition.

Instead the 48-bit accumulator file is **partitioned**:

| mode | lanes | bits per lane | product width | headroom |
|---|---|---|---|---|
| `M16` | 1 | 48 | 32 | 16 |
| `M8` | 2 | 24 | 16 | 8 |
| `M4` | 4 | 12 | 8 | 4 |

Same 48 bits of storage in every mode. Narrow modes buy more lanes by accepting
less headroom per lane — a clean, honest trade, and the headroom always works out
to 16/lanes bits.

### 5.2 Carry containment

A subtle and important requirement. In `M4` the four lanes are *independent
numbers* that happen to live in one 48-bit register. If lane 0 overflows, the
carry must **not** leak into lane 1 — that would corrupt an unrelated result.

An ordinary 48-bit adder would leak. So the design uses a **segmented adder**:
four 12-bit blocks whose carry chain can be broken between blocks.

- `M16`: all three boundaries joined — one 48-bit adder.
- `M8`: join blocks 0-1 and 2-3, break the middle — two 24-bit adders.
- `M4`: break all three — four independent 12-bit adders.

That is `seg_add48` in `rtl/mpmac.v`, and mode controls exactly three AND gates
on three carry bits. Three gates is the entire cost of making one adder serve
three different lane widths — a genuinely cheap piece of engineering.

The testbench hammers this specifically: it drives one lane to overflow, 64
accumulations deep, and checks every other lane is still exactly zero.

---

## 6. Number formats: fixed, floating, posit

A brief detour, because the repository measures all three and the results are
counterintuitive.

### 6.1 Fixed point

Choose a scale and stick to it. In **Q1.15**, one bit is the sign and fifteen
are fractional, so the value is the integer divided by 2¹⁵ and the range is −1 to
just under +1. All the arithmetic is ordinary integer arithmetic — the scaling
is a convention in your head, not something the hardware does.

Cheap, exact, and completely inflexible: values outside the range clip, and
values far below the smallest step vanish.

### 6.2 Floating point

Store a number as `sign × mantissa × 2^exponent`, like scientific notation.
IEEE binary16 uses 1 sign bit, 5 exponent bits and 10 mantissa bits.

The exponent buys enormous range. The cost is complexity — every operation has to
align exponents, normalise, and round — and *relative* rather than absolute
precision.

### 6.3 Posits

A newer format. Instead of a fixed-width exponent, a posit uses a variable-length
**regime** field: a run of identical bits whose length encodes a large power. Few
regime bits near 1.0 leaves more bits for the fraction; far from 1.0 the regime
eats the budget and precision falls away.

This is **tapered accuracy** — most precise near 1, least at the extremes. Since
lots of real data (normalised neural network weights, for one) clusters near 1,
posits are often pitched as strictly better than floats at the same width.

The measurements in `model/formats.py` say: not strictly, no.

On a dot product with values uniform in [−1,1), the RMS relative errors are

| format | uniform [−1,1) | wide, 8 decades |
|---|---|---|
| fixed Q1.15 | **4.9e-04** | 1.00e+00 |
| IEEE binary16 | 3.8e-03 | **2.1e-02** |
| posit(16,1) | 1.2e-03 | 1.96e-01 |

Read across the rows. Fixed point is far the best on a bounded range and useless
on a wide one — its numbers simply clip and vanish. Posit beats binary16 by 3×
near 1, exactly as advertised. And binary16 beats posit by 9× across eight
decades, because out at the extremes the regime field has eaten the bits the
fraction needed.

**Posit is second in both columns.** Tapered accuracy is a bet that your data
sits near 1, not a free win. That is a more useful thing to be able to say than
either marketing claim, and it is the kind of statement you can only make by
measuring both ends.

---

## 7. What is actually built here

Putting it together. `rtl/mpmac.v` contains:

**`mp_frontend`** — takes 16-bit `a` and `b`, splits each into four 4-bit digits,
decides which digits are lane-tops (mode-dependent), sign-extends those to 5 bits
and zero-extends the rest, and produces the sixteen 5×5 signed sub-products. The
sub-product range is −120 to +225, which fits 10 bits signed; `model/mpmac.py`
verifies that exhaustively rather than trusting the arithmetic.

**`seg_add48`** — the segmented adder described in §5.2.

**Two complete MACs** that use those pieces differently, which is the experiment:

- **`mpmac_split`** builds three separate reduction networks — one per mode — and
  multiplexes their outputs. Only the sub-multipliers are shared.
- **`mpmac_shared`** builds one network. Each sub-product is masked off when its
  two digits are not in the same lane, placed into a 48-bit field by constant
  wiring, and summed by a tree of segmented adders. Mode touches only the masks
  and the carry gates.

"Duplicate and select" versus "share and mask". Both compute the same function —
we prove it — so comparing them is a clean architecture-versus-architecture
experiment.

**Baselines** in `rtl/mac_ref.v`, because a design is only good or bad relative
to something:

- `mac_separate`: seven dedicated units (one 16-bit, two 8-bit, four 4-bit), all
  present at once. The cost of **no sharing**.
- `mac_fixed16`: one fixed 16-bit unit used at every precision. The cost of **no
  flexibility** — correct everywhere, wasteful when narrow, and incapable of
  producing two results in one cycle.

### 7.1 The two architectures, concretely

The difference between `mpmac_split` and `mpmac_shared` is worth drawing out,
because it is the experiment the repository exists to run.

**`mpmac_split` — duplicate and select.** Build three complete reduction
networks. One sums all sixteen sub-products with weights `4(i+j)` into a 48-bit
result. One sums the two diagonal blocks of four into two 24-bit results. One
just sign-extends the four diagonal sub-products into four 12-bit results. Then
three sets of accumulator adders, and a multiplexer at the end picking whichever
matches the current mode.

```
        ┌── M16 network ──┐
pp ─────┼── M8  network ──┼── mux ── accumulator
        └── M4  network ──┘
              ↑
            mode
```

Simple to reason about, and each network can be exactly as wide as it needs to
be. The cost is that most of the hardware is idle at any moment: in `M4` the
`M16` network is computing a result nobody will use.

**`mpmac_shared` — mask and place.** Build one network. Each sub-product is
masked off when its two digits are not in the same lane, sign-extended only as
far as its own lane's top, and dropped into a 48-bit field by constant wiring.
Then one tree of segmented adders sums all sixteen placed terms.

```
pp ── mask ── place ── one segmented adder tree ── accumulator
        ↑       ↑              ↑
      mode    mode           mode (3 carry gates)
```

Mode touches three things: which terms are masked, which of three pre-wired
placements is selected, and three AND gates on the carry chain. Nothing is
duplicated.

The placements are worth a note. For a given sub-product there are only three
possible destinations — one per mode — and each is just *wiring*, a fixed shift
with a fixed sign extension. So selecting between them is a three-way
multiplexer, not a barrel shifter. Constant wiring is free in hardware; only the
multiplexer costs anything.

**Which is better?** Generic cells said shared, by 10%. Vivado said split, by
23%. Both are measurements of the same two designs, and they disagree, which is
the point of §10.2. Neither is "the answer" — they answer different questions,
and only one of them is about a real chip.

The reason it is a *fair* experiment is that the two are proved equivalent. Any
difference in area or timing is architecture, not a bug in one of them.

---

## 8. How do you know it works?

This is the part students usually skip and professionals spend most of their
time on. There are three separate techniques here, and they catch different
things.

### 8.1 A model, written before the hardware

Before any Verilog existed, `model/mpmac.py` implemented the digit
decomposition in Python and checked it against straightforward multiplication.
Not the same code twice — two genuinely different routes to the same answer:
`products()` does the digit algebra, `reference_products()` slices the operands
and uses Python's `*`.

It runs exhaustively where it can (every 4-bit digit pair, every 8-bit lane
pair) and randomly where it cannot, and reports zero mismatches.

Why bother, when you could write the Verilog and test that? Because when a
hardware testbench fails you do not know whether the *idea* is wrong or the
*implementation* is. Separating the two questions makes the second one much
faster to answer. In this project the model caught the sign-extension algebra
before it could turn into a confusing waveform.

### 8.2 A self-checking testbench

`tb/tb_mpmac.v` drives the design and checks every result against a golden model
computed independently — it slices the operands and uses `*` directly, sharing no
structure with the digit decomposition.

1,467,310 checks per design. But the *number* is the least interesting thing
about it. What matters is that the stimulus is aimed at the failure mode this
design actually has: **lane crosstalk**.

If you drive all four lanes with the same values, a leak between lanes is
invisible — everything is equal anyway, so a corrupted lane looks correct. So
every directed test drives **one** lane and asserts the others are exactly zero.
There are tests for negative products (which must not sign-extend past their own
lane boundary) and a 64-deep overflow soak that pushes `M4` past its four bits of
headroom to confirm the carry stops at the boundary.

The lesson generalises: **a test that cannot distinguish a pass from a failure is
not a test.** Think about what would break, then build stimulus that would show
it.

### 8.3 Formal proof

Simulation checks the cases you thought of. **Formal verification** checks all of
them, by handing the question to a solver.

The tool is `SymbiYosys` driving `z3`, an **SMT solver** — a program that decides
whether a logical formula can be satisfied. You describe two circuits, assert
their outputs are equal, and ask the solver to find inputs where the assertion
fails. If it cannot, no such input exists and the circuits are equivalent for
every possible input.

This repository does it several times:

- `formal/equiv.sby`, `equiv_ks.sby` — the three adders compute the same sums.
- `formal/equiv_seg.sby` — the three carry-propagate choices inside the segmented
  adder agree.
- `formal/mpmac_eq.eqy` — the two whole architectures are equivalent, using
  `eqy`, which handles sequential circuits by matching registers.
- `formal/mode4.sby`, `mode8.sby` — each mode really does implement the dedicated
  multipliers it claims to.

### 8.4 The bug that only formal could find

During development `eqy` came back with a counterexample: **mode = `2'b11`**.

The mode field is two bits but only three modes are defined, so `2'b11` is
unused. `mpmac_split`'s if-else chain fell through to `M4`. `mpmac_shared`'s
carry gates were written as `mode != M4`, so the illegal code got `M8` lane
merging with `M4` term placement — genuinely different behaviour.

Would it ever matter? Probably not; nothing drives that code. But note what
happened: **1.47 million simulation vectors could never have found it**, because
the testbench only generates legal modes. No amount of random testing reaches
inputs the test generator does not produce.

The fix was to decode positively — `mode == M16 || mode == M8` — so any unused
code means `M4` in both designs. That is also just better practice: define
behaviour by what you include, not by what you exclude.

### 8.5 Choosing what to prove

Formal has a hard limit, and hitting it teaches you where the limit is.

The proof that the two architectures agree took under three minutes. A proof
that `M16` implements a dedicated 16×16 multiplier **never returned** — over ten
minutes in the solver with no answer.

The reason is that SMT solvers work by converting everything to a giant Boolean
formula, and **multiplication is famously bad for this**. The formula for
"these two 16×16 multipliers are equal" is enormous and highly structured in a
way solvers handle badly. At 4 bits it is instant, at 8 bits slow, at 16 bits
hopeless.

The same wall shows up in the conditional-rewrite proof of §12, which closes in a
second at 4 bits and not at all at 8.

So the practical skill is **choosing the smallest thing that carries the
obligation.** When proving the whole sequential MAC failed to close, proving just
the one block that differed — the accumulate — closed in under a second.
Granularity was worth more than any amount of solver tuning.

Where a proof does not close, say so. `M4` and `M8` are proved; `M16` is covered
by 1.47 million vectors and is documented as unproved. Two out of three, stated
plainly, is worth more than pretending.

---

## 9. Measuring hardware

You have a design that works. Is it any good? That needs numbers, and getting
comparable numbers is harder than it sounds.

### 9.1 Synthesis

**Synthesis** turns your Verilog into a network of gates. This project uses two
tools, deliberately:

- **Yosys** with **ABC**, open source, mapping to generic AND/OR/XOR gates. Fast,
  so you can sweep many designs.
- **Vivado**, Xilinx's tool, mapping to the actual resources on a real FPGA.
  Slow, but real.

Two metrics from Yosys:

- **cells** — how many gates. A proxy for area.
- **depth** (`ltp`, longest topological path) — the most gates any signal passes
  through. A proxy for delay.

Both are proxies, and the word matters.

### 9.2 What an FPGA is actually made of

Vivado's numbers need a little background. An FPGA is a grid of small
configurable blocks:

- A **LUT** (look-up table) is a tiny memory implementing any function of a few
  inputs. A 6-input LUT is 64 bits of configuration and can compute any 6-input
  Boolean function. LUTs are the general-purpose logic.
- A **flip-flop** stores one bit. Every LUT comes with one whether you use it or
  not, so on an FPGA flip-flops are close to free.
- A **CARRY4** is dedicated fast carry hardware. Because ripple carries are so
  common and so critical, FPGAs have a special hard-wired path for them that is
  far faster than routing through general LUTs.
- A **DSP48** is a hard-wired multiply-accumulate block — a real multiplier and a
  48-bit accumulator, built in silicon.

That last two matter enormously, and generic-cell counting knows about neither.

### 9.3 Timing, and slack

Vivado reports **worst negative slack** (WNS): how much time to spare the slowest
path has, against your clock. Positive slack means it meets timing; negative
means the design would not run at that speed.

Two numbers are reported here. **Register-to-register** slack covers paths from
one flip-flop to another — for this design, the accumulator feedback loop, and it
needs no assumptions about the outside world. **Worst-case** slack includes paths
from inputs, which depends on assumptions about what feeds you.

### 9.4 What synthesis will and will not do for you

A common beginner assumption is that the synthesis tool optimises your design, so
the way you write it does not matter much. That is half true, and the half that
is false matters a great deal.

Synthesis is very good at **local** optimisation. It will remove logic whose
output nobody reads, fold constants, merge duplicated gates, rebalance a chain of
ANDs, and map whatever is left onto the target's primitives. `SWEEP.md` shows
ABC cutting a Kogge-Stone adder from 915 cells to 489 — it found a great deal of
redundancy in how the prefix tree was expressed.

What it will **not** do is change your architecture. Give ABC a ripple-carry
adder and you get back a ripple-carry adder: 240 cells in, 240 cells out, depth
97 both times. It will not invent a parallel prefix tree, because that is not a
local rearrangement — it is a different algorithm with a different structure.

This is the single most important practical fact about synthesis:

> **Structure has to be in the input.** The tool optimises what you wrote; it
> does not decide what you should have written.

It is also precisely the gap that rewriting-based approaches such as e-graph
datapath optimisation exist to close, which is why §13 is in this repository at
all. An e-graph *can* discover that one structure is equivalent to another,
because it works on algebraic identities rather than gate-level rearrangement.

Two smaller corollaries worth internalising:

**Synthesis optimises against the model it has.** ABC is minimising gate count,
with only a crude notion of delay. That is why it sometimes makes a design
*deeper* while making it smaller — it raised `mpmac_split`'s depth from 345 to
388 while cutting 2900 cells. It is not malfunctioning; it is trading against an
objective you did not state.

**Two tools can disagree about which design is better**, as §10.2 shows in
detail. Whenever they do, ask which one models the thing you actually care about.
For a real chip, the one that knows about carry chains and hard macros wins that
argument every time.

---

## 10. The results, and what they overturned

Now the payoff. Several confident expectations did not survive measurement.

### 10.1 The Yosys numbers

| design | cells (ABC) | depth | FF |
|---|---|---|---|
| `mpmac_split` (V1) | 4886 | 388 | 48 |
| `mpmac_shared` (V2) | **4400** | **270** | 48 |
| `mac_separate` (B1) | 4333 | 261 | **144** |
| `mac_fixed16` (B2) | 2454 | 264 | 48 |

Read alone this says: sharing beats duplicating by about 10% in cells and 30% in
depth, and loses to seven dedicated units by 1.5%. The shared design uses a third
of the flip-flops (48 against 144) because of the partitioned accumulator.

Both halves of that reading turn out to be wrong on real hardware.

### 10.2 Vivado reverses the verdict — twice

LUT-only synthesis on an Artix-7:

| design | LUT | FF | CARRY4 | WNS reg→reg | WNS worst |
|---|---|---|---|---|---|
| `mpmac_split` V1 | **1046** | 48 | 158 | +1.402 | −2.537 |
| `mpmac_shared` V2 | 1351 | 48 | 245 | +2.690 | −6.353 |
| `mpmac_rca` | 1496 | 48 | 64 | −8.401 | −11.259 |
| `mpmac_ksa` | 2262 | 48 | 64 | +1.136 | −9.512 |
| `mac_separate` B1 | **948** | 144 | 150 | +6.744 | **+0.619** |

Three things flip.

**V1 beats V2 by 23% on LUTs** — the opposite of the generic-cell ranking. V2
also uses far more CARRY4. Two explanations fit and this data cannot separate
them: the carry-break gates may fragment the fast-carry chains, or V2 may simply
do more wide addition. What is certain is the direction, and that generic cells
have no concept of a dedicated carry resource so they cannot rank these two.

**Hand-written adders lose to writing `+`.** `mpmac_rca` and `mpmac_ksa` use 64
CARRY4 against V2's 245, and cost 11% and 67% more LUTs. Writing the carry logic
explicitly *prevents* Vivado from recognising the pattern and mapping it to the
fast carry chain. On an FPGA, `+` is not laziness — it is the interface to a hard
resource, and hand-optimising locks you out of it.

**Kogge-Stone wins on timing where `ltp` said it lost.** Yosys scored `mpmac_ksa`
deeper than `mpmac_rca` (354 versus 235). Real static timing says the opposite by
a wide margin: +1.136 ns against −8.401 ns, a 9.5 ns swing. `ltp` counts levels
and cannot weight them; a level through fast carry hardware and a level through
general routing are not the same thing at all.

If you take one methodological point from this repository, take that one. **A
proxy metric can rank two designs backwards.** Generic cells are useful for
sweeping a space quickly. They are not evidence.

### 10.3 With DSP blocks allowed

| design | LUT | FF | DSP |
|---|---|---|---|
| `mac_fixed16` | **2** | 0 | 1 |
| `mac_separate` | 463 | 96 | 1 |
| all `mpmac` variants | unchanged | 48 | **0** |

A behavioural `a*b + acc` maps into a single DSP48 — including its accumulator,
which is why B2's flip-flops vanish entirely. The whole MAC becomes two LUTs and
one hard block.

The hand-decomposed datapath infers **no DSPs at all**, because sub-word
decomposition is invisible to the inference pass. On a real Artix-7, asking for a
16-bit MAC and getting one hard macro beats any LUT-built alternative outright.

### 10.4 The honest verdict

**At 16 bits on this fabric, the shared multi-precision MAC does not pay for
itself.** Seven dedicated units are smaller, meet timing when none of the shared
variants do, and map to DSPs. The accumulator-register saving is real but nearly
worthless on FPGA fabric, where flip-flops come free with the LUTs.

What survives is the thing the baselines cannot do: **two or four independent
products per cycle from the same operand ports**, which a DSP48 will not do for
multiplies. The case for this design is throughput per operand port, not area —
and that is the case to make, because the area case does not survive contact with
Vivado.

Reporting that is more useful than burying it. A result that contradicts the
design you built is still a result.

---

## 11. Where the area actually goes

If the shared design is expensive, what is expensive about it? Three synthesis
runs isolate it:

| what | cells | difference |
|---|---|---|
| 16 plain 4×4 **unsigned** multiplies | 1096 | — |
| 16 5×5 **signed**, mode fixed at compile time | 1352 | +256 for signedness |
| `mp_frontend`, mode and sign chosen at runtime | 2570 | **+1218 for flexibility** |

Making the multipliers signed costs 256 cells. Making the mode **runtime
selectable** costs another 1218 — nearly five times as much, and 28% of the whole
design.

The reason is **specialisation**. With mode fixed at compile time, twelve of the
sixteen sub-multipliers collapse to narrow unsigned units, because the tool can
see they never handle a signed top digit. A runtime mode forbids that: every
sub-multiplier must be full 5×5 signed all the time, because on some cycle it
might be.

For scale, the front end is 2570 of 4400 cells (58%); everything else — placement,
the adder tree, the accumulate — is the other 1830. **The part the two
architectures argue about is not where the money is.**

This is the classic multi-precision cost, sometimes called mux explosion:
flexibility is not free, and it is not paid where you expect. The obvious next
move is **Baugh-Wooley**, a technique that keeps every sub-multiplier
unconditionally unsigned and pushes sign correction into the reduction tree as a
few constant rows. The recoverable budget is the gap between 1096 and 2570.

---

## 12. Exploring the design space

One design point tells you very little. `dse.sh` generates and synthesises the
whole cross product — architecture × carry structure × precision mode — locking
the mode to a constant so each point is specialised to one lane width. Fourteen
points, in `results/dse.csv`.

The important choice is the cost axis. Raw cell count is misleading, because
`M4` produces **four** results per cycle and `M16` produces one. The fair
comparison is **cells per product per cycle**:

| mode | best variant | cells per product | RMS relative error |
|---|---|---|---|
| `M16` | shared / rca | 2641 | 4.91e-04 |
| `M8` | split / infer | 733 | 1.08e-01 |
| `M4` | split / infer | 223 | 1.88e+00 |

The accuracy column comes from `model/formats.py` running a length-64 dot
product at each precision.

**`M4` is 12× cheaper per product than `M16` and 3800× less accurate.** A 4-bit
lane produces a 188% RMS error on a general dot product — not a usable answer at
any price. `M8` is 3.5× cheaper for a 10.8% error.

So there is a real Pareto trade, and it is steep. The conclusion is conditional:
narrow modes only pay for themselves in an application that can absorb that
error. Neural network inference often can, which is why low-precision inference
is an entire field. A general-purpose dot product cannot.

---

## 13. Automating the optimisation, and why it needs care

The last part of the arithmetic track is about **making a program do the
optimising**, and the trap that lies in wait.

### 13.1 Rewriting

Optimisation is largely pattern replacement. `x × 2` becomes `x << 1` — a shift
is far cheaper than a multiplier. `a×b + a×c` becomes `a×(b+c)` — one multiplier
instead of two.

Each is a **rewrite rule**: a pattern and a replacement, claimed to preserve
meaning. Apply enough of them and you have an optimiser.

The difficulty is that rewrites interact. Applying one can block another, and the
best final answer sometimes requires making things *worse* first. Greedy
application gets stuck.

### 13.2 E-graphs

An **e-graph** (equivalence graph) solves this by refusing to choose. Instead of
replacing an expression, it records that the two forms are *equal* and keeps
both. Expressions are grouped into **e-classes** — sets of forms known to be
equivalent.

Apply every rule everywhere, repeatedly, until nothing new appears. That is
**equality saturation**. The e-graph now compactly represents an enormous number
of equivalent programs — the whole space at once, without ever committing.

Then **extraction**: walk the e-graph choosing the cheapest form from each
e-class, according to a cost model. Because you never discarded anything, the
extractor sees options a greedy rewriter would have destroyed.

The library used here is `egg`, in Rust. `egraph/` is a small optimiser built on
it.

### 13.3 The trap

Here is the part that matters, and it connects straight back to §2.

`a×b + a×c = a×(b+c)` is true. It is basic algebra, true for all integers.

**It is false in hardware.**

Because `b+c` has to be *stored somewhere*, and that somewhere has a width. If
`b` and `c` are 4-bit values and you keep the sum in 4 bits, it wraps. And a
wrapped sum multiplied by `a` is not the same as the sum of two products.

The solver finds it immediately (`formal/dist_narrow.sby`):

```
a = 1,  b = 12,  c = 4
a×b + a×c        = 16
b + c            = 16  →  truncated to 4 bits = 0
a × ((b+c) mod 16) = 0
```

One input triple out of 4096. And notice which circuit is wrong: the **cheaper**
one. A rewriter that applies the identity unconditionally produces a smaller,
faster design that is wrong on inputs no directed test would ever visit.

### 13.4 Side-conditions

The identity is not false — it is **conditional**. It holds whenever `b+c` fits.
Three proofs make that precise:

| circuit | intermediate | result |
|---|---|---|
| widened | `b+c` in W+1 bits | **proved equal**, unconditionally |
| truncated | `b+c` in W bits | **proved unequal**, with the counterexample above |
| truncated + assumption | `b+c` assumed not to overflow | **proved equal** |

Same circuit in rows two and three. The only change is the domain.

This is exactly what the ARITH 2022 rewrite table encodes: every rewrite carries
a **sufficient condition** on the bitwidths, because the identities are about
integers while the circuits are about fixed-width bitvectors.

### 13.5 Teaching the optimiser the condition

`egraph/src/main.rs` carries bitwidth as an **e-class analysis** — a piece of
information attached to every e-class and propagated as the graph grows:

- a variable's width is declared
- a sum can carry one bit past its widest operand
- a product needs the sum of its operands' widths

and when two e-classes merge, take the tighter bound, since both are valid upper
bounds on the same value.

The factoring rewrite is then **guarded**: apply only if the intermediate sum
fits the datapath. Running the same rule with the guard removed:

```
operands         datapath  guarded             cost   unguarded          cost
a:8,b:8,c:8            16  (* a (+ b c))        110   (* a (+ b c))       110
a:8,b:15,c:15          16  (* a (+ b c))        110   (* a (+ b c))       110
a:8,b:16,c:16          16  (+ (* a b) (* a c))  210   (* a (+ b c))       110
a:4,b:32,c:32          32  (+ (* a b) (* a c))  210   (* a (+ b c))       110
```

The unguarded rule factors two more cases and halves the cost. Those two are
precisely the circuits the solver refutes.

**The guard is not a conservatism knob. It is the difference between an optimiser
and a bug generator.** Which is why, in automated datapath optimisation, the
interesting research problem is the side-conditions rather than the search.

---

## 14. The width study, and a lesson about confidence

One loose end. Section 3.4 said the optimum depends on width. Everything since
has been measured at 16 bits. Does the verdict hold?

`rtl/mpmac_gen.v` generalises the whole architecture over operand width — 4-bit
digits still, but `W/4` of them, an accumulator of `3W` bits, lanes of `3W/lanes`.
Verified at 16, 32 and 64 bits against a golden model, 120,000 checks each, zero
errors, before any area was measured.

| W | as-written shared | dedicated | ratio | ABC shared | dedicated | ratio |
|---|---|---|---|---|---|---|
| 16 | 7583 | 4535 | 1.67× | 4322 | 4398 | **0.98×** |
| 32 | 42574 | 14243 | 2.99× | 17822 | 14041 | **1.27×** |
| 64 | 235744 | 47527 | 4.96× | — | — | — |

**The verdict moves against sharing, and it survives technology mapping** — from
marginally *cheaper* at 16 bits to 27% *more expensive* at 32. That is the
width-dependence claim reproduced on our own datapath: a design that wins at one
width loses at the next, with nothing about the architecture changed.

### 14.1 Why it gets worse

Not the multipliers. Sub-products stay 4×4 and there are `(W/4)²` of them —
quadratic in W, the same as a dedicated multiplier's partial products.

The problem is the **reduction network**. Every sub-product is placed into a full
`3W`-bit accumulator field *before* being summed, so the adder tree carries
`(W/4)²` terms of `3W` bits each: **cubic in W**. A dedicated multiplier reduces
its partial products at their natural narrow width and only widens at the end.

That is a fixable architectural mistake, not a fact about multi-precision
arithmetic. Reducing within the lane before placing — what a Wallace or Dadda
tree does — restores quadratic growth. At 16 bits the cost is invisible, which is
exactly why one width is not enough.

### 14.2 Being careful about how much to claim

The structure-preserving column suggests a much bigger effect than the mapped
one. The ratio grows 1.79× per doubling before mapping and only **1.29× after**,
because ABC removes much of the redundancy the shared design creates.
Extrapolating the mapped rate puts W=64 near 1.6×, not 4.96×.

The 64-bit row is structure-preserving only — technology-mapping a behavioural
64×64 multiply does not finish in useful time. So it indicates a direction, not a
size, and it is labelled that way.

The general habit: **notice which of your columns is actually load-bearing.**
Here two views of the same designs differ by a factor of two in how big the
effect is, and at 16 bits they differ in *sign*. Quoting the more dramatic one
would have been easy and wrong.

---

## A worked example, all the way through

Abstractions land better with numbers in them. Let us multiply **−3 × 5** in
`M4` mode, in lane 0, and follow it through every stage.

**Setting up.** In `M4` each 4-bit digit is its own lane, so lane 0 uses digit 0
of each operand. We want `a₀ = −3` and `b₀ = 5`. In 4-bit two's complement:

```
−3 = 1101      (−8 + 4 + 0 + 1 = −3)
+5 = 0101      (0 + 4 + 0 + 1  = +5)
```

Drive `a = 16'h000D` and `b = 16'h0005`, with the other digits zero, `sgn = 1`
and `mode = M4`.

**The front end.** `mp_frontend` splits the operands into digits and decides
which are lane-tops. In `M4` every digit is the top of its own lane, so all are
signed. Digit 0 of `a` is `1101`; sign-extending to 5 bits gives `11101`, which
is −3 as a 5-bit signed value. Digit 0 of `b` is `0101` → `00101` = +5.

The sub-multiplier computes `−3 × 5 = −15`, held in 10 bits signed:
`1111110001`.

Only `pp[0][0]` matters here. The other fifteen sub-products involve digits that
are zero, so they are zero — but note they are still *computed*. The hardware
does not know they are uninteresting, and that idleness is a real cost we return
to below.

**Placement.** In `M4`, sub-product (i,j) contributes only when `i == j`, and
lane `i` occupies bits `[12i +: 12]`. So `pp[0][0]` is sign-extended from 10 to
12 bits — `111111110001` — and placed at bits 11:0. Everything above bit 11 is
zero, because lane 0 must not touch lane 1.

**Reduction.** The tree sums sixteen placed terms. Fifteen are zero, so the sum
is our one term. The segmented adder is in `M4`, so all three carry boundaries
are broken and nothing can cross between lanes even if it wanted to.

**Accumulate.** Assume the accumulator was zero. Lane 0 becomes
`111111110001` = −15 in 12-bit two's complement. Lanes 1–3 stay zero. Read the
48-bit accumulator and lane 0 says −15. Correct.

**Now do it again.** Accumulate `−3 × 5` a second time. Lane 0's adder computes
`−15 + −15 = −30` = `111111100010`. Still comfortably inside 12 bits, which hold
−2048 to +2047. We have four bits of headroom in `M4`, so we can accumulate
roughly sixteen full-scale products before wrapping — and the testbench pushes
64 deep specifically to confirm that when it *does* wrap, it wraps inside its own
lane and leaves the neighbours alone.

**The same operands in M16.** Now `a = 16'h000D` means the whole 16-bit number
13, not −3, because digit 0 is no longer a lane top — only digit 3 is, and it is
zero, so the value is positive. The identical bit pattern means a different
number in a different mode. That is not a flaw; it is what mode *means*, and it
is why the testbench checks every mode separately against a golden model that
knows which interpretation applies.

## Reading the Verilog

A few constructs appear constantly in this repository and are worth recognising.

**`parameter`** is a compile-time constant. `mpmac_gen #(.W(32))` builds a
32-bit instance. Parameters let one source file describe a family of designs,
which is how the width study exists at all.

**`generate` and `genvar`** are compile-time loops. This:

```verilog
genvar i;
generate
  for (i = 0; i < 4; i = i + 1) begin : dig
    assign da[i] = a[4*i +: 4];
  end
endgenerate
```

does not loop at runtime — hardware has no runtime in that sense. It **creates
four separate pieces of circuitry**, one per value of `i`. Think of it as the
compiler writing out four copies of the line for you.

**`a[4*i +: 4]`** is an indexed part-select: "four bits starting at `4*i`". It
exists because `a[4*i+3 : 4*i]` is illegal when `i` is not a constant, and this
form is legal as long as the *width* is constant.

**`{{38{sbit}}, p}`** is replication inside concatenation: 38 copies of `sbit`,
then `p`. This is how sign extension is written — copy the sign bit as many times
as you need.

**`localparam integer OK8 = ((i/2) == (j/2)) ? 1 : 0;`** — a compile-time
constant derived from loop variables. It decides whether a particular
sub-product is used in `M8`. Because it is compile-time, the unused terms are
literally not built, rather than being computed and discarded.

**Blocking (`=`) versus non-blocking (`<=`)**. Inside `always @(posedge clk)`,
use `<=`: all right-hand sides are evaluated before any assignment happens, which
matches how real flip-flops behave. Inside `always @*` for combinational logic,
use `=`. Mixing them up is one of the classic sources of designs that simulate
correctly and synthesise wrongly.

## Running it yourself

Everything reproduces from a clean clone. You need Verilator, Yosys with ABC,
SymbiYosys and z3 — all in the OSS CAD Suite — plus Python 3.10+.

```bash
# the algebra, before any hardware
python3 model/mpmac.py

# the design against an independent golden model
verilator --binary --timing -sv rtl/adders.v rtl/mpmac.v \
  tb/dut_wrap.v tb/tb_mpmac.v --top-module tb_mpmac -o sim \
  -DDUT=dut_shared -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
./obj_dir/sim

# area and depth
./sweep.sh        # the adder study
./sweep_mac.sh    # the MAC against its baselines
./dse.sh          # the full design space

# proofs
cd formal
sby -f equiv_seg.sby     # the carry-propagate choices agree
sby -f mode4.sby         # M4 implements four dedicated 4x4 multipliers
sby -f dist_wide.sby     # distributivity, widened intermediate: PASS
sby -f dist_narrow.sby   # truncated intermediate: FAIL, on purpose
eqy -f mpmac_eq.eqy      # the two architectures are equivalent

# the conditional rewrite
cd ../egraph && cargo run --release
```

If a proof fails that should pass, or an area number differs from `DESIGN.md`,
that is worth investigating rather than ignoring — the numbers in the
documentation were produced by exactly these commands, and they have been
corrected more than once when a change moved them.

## 15. What to take away

**On arithmetic.** Multiplication is shifted addition; a wide multiply
decomposes into small ones; two's complement means only the top digit of a lane
carries a sign; carry containment is what makes independent lanes possible.

**On measurement.** Every metric is a proxy for something you actually care
about, and proxies can rank designs backwards. Generic cells ranked two
architectures the wrong way round. `ltp` ranked Kogge-Stone the wrong way round.
Both were caught by measuring again with a better tool.

**On verification.** Simulation checks what you thought of; formal checks
everything, at the cost of only working on small enough problems. Choose the
smallest thing that carries the obligation. Say which proofs did not close.

**On honesty.** The most useful results here are the ones that went against the
design: the shared unit losing to dedicated units, hand-written adders losing to
`+`, and the cost of runtime flexibility being four times the cost of signedness.
None of them are what we set out to show, and all of them are more informative
than the result we expected.

### Questions you might reasonably ask

**Why 4-bit digits? Why not 2 or 8?**
It sets the granularity of everything. With 4-bit digits a 16-bit operand splits
into four, which gives exactly the 1/2/4-lane modes we wanted. Smaller digits
mean more sub-products (`(W/d)²` grows fast) and a bigger reduction network.
Larger digits mean fewer, bigger multipliers and less flexibility — 8-bit digits
would give at most two lanes from a 16-bit operand. Four is the choice that makes
the three modes fall out naturally.

**Why is the accumulator 3× the operand width?**
So headroom works out to `W/lanes` bits in every mode, which keeps the modes
comparable. It also lands on 48 bits for a 16-bit operand, matching the DSP48,
which makes the FPGA comparison meaningful rather than arbitrary.

**Why do narrow modes leave sub-multipliers idle?**
In `M4` only four of sixteen sub-multipliers do useful work. That looks wasteful,
and it is — but it is not fixable by better design. With 16-bit operand *ports*,
four 4-bit lanes is all the data you can feed in per cycle. The idleness is an
operand-bandwidth limit, not an architectural mistake. Narrow modes buy lane
parallelism, not throughput per gate, and it is worth saying so before someone
asks.

**Why prove things when the testbench passes?**
Because the testbench only generates inputs someone thought of. The `mode =
2'b11` bug sat behind 1.47 million passing vectors. Formal asks "is there *any*
input", which is a categorically different question.

**Why did you keep results that made the design look bad?**
Because they are true, and because they are the useful part. "We built a shared
multi-precision MAC and it beat the alternatives" would be a weaker claim than
"we built one, measured it properly, and found it loses at 16 bits for a specific
and fixable reason". The second tells you something about arithmetic hardware.
The first mostly tells you we chose our baseline carefully.

**What would you do next?**
Three things, in order. Fix the reduction network to sum within a lane before
placing, which §14 shows is the real scaling problem. Try Baugh-Wooley to
recover the 1218 cells that runtime signedness costs. And close the loop between
the e-graph and the synthesis flow, so an extracted expression becomes RTL that
gets measured rather than a cost-model number.

### Glossary

| term | meaning |
|---|---|
| **ABC** | logic optimisation tool used by Yosys |
| **accumulator** | register holding a running total |
| **ABFT** | algorithm-based fault tolerance |
| **CARRY4** | dedicated fast carry hardware on a Xilinx FPGA |
| **cell** | one gate in a synthesised netlist |
| **DSP48** | hard multiply-accumulate block on a Xilinx FPGA |
| **e-class** | a set of expressions known to be equivalent |
| **e-graph** | data structure holding many equivalent expressions compactly |
| **equality saturation** | applying rewrites until nothing new appears |
| **extraction** | picking the cheapest form out of a saturated e-graph |
| **fixed point** | integer with an agreed scaling factor |
| **generate / propagate** | signals saying a bit position makes or passes a carry |
| **headroom** | accumulator bits above the product width |
| **lane** | one independent slice of a SIMD datapath |
| **LUT** | look-up table; general-purpose FPGA logic |
| **ltp** | longest topological path; a depth proxy |
| **MAC** | multiply-accumulate |
| **modulo** | remainder after division |
| **partial product** | one shifted copy in long multiplication |
| **posit** | number format with a variable-length regime field |
| **ripple carry** | adder where carries propagate one bit at a time |
| **parallel prefix** | adder computing all carries in log₂(n) levels |
| **SIMD** | one instruction operating on several data items at once |
| **slack** | spare time on a timing path; negative means too slow |
| **SMT solver** | program deciding satisfiability of logical formulas |
| **synthesis** | turning HDL into a gate netlist |
| **two's complement** | signed representation where the top bit's weight is negative |

### Why any of this matters outside this repository

It is fair to ask what a 16-bit MAC has to do with anything.

Modern machine-learning hardware is, structurally, an enormous array of exactly
this circuit. A tensor unit in a GPU or a systolic array in an accelerator is
thousands of multiply-accumulates arranged so that data flows between them. Every
choice examined here scales up: how wide the accumulator is, whether one unit can
serve several precisions, whether the carry chain maps to dedicated hardware.

The multi-precision question in particular is live and commercial. Reduced
precision is how inference gets fast and cheap — 8-bit is routine, 4-bit is
common, and hardware that can switch between them without duplicating silicon is
worth real money. Every major accelerator vendor ships something along these
lines. This repository builds a small honest version of it and reports what it
actually costs, including the parts that did not work out.

The verification half generalises further still. "Prove the small thing rather
than the big thing", "a test that cannot distinguish pass from failure is not a
test", and "check whether your metric is measuring what you care about" are not
facts about arithmetic. They are how you avoid confidently shipping something
wrong, in any engineering discipline.

### Where to look next

| file | what it holds |
|---|---|
| `model/mpmac.py` | the algebra, proved before any hardware |
| `rtl/adders.v` | ripple, serial-carry and Kogge-Stone adders |
| `rtl/mpmac.v` | the front end, segmented adder, and both architectures |
| `rtl/mac_ref.v` | the baselines |
| `tb/tb_mpmac.v` | the self-checking testbench |
| `formal/` | every proof, including the one that fails on purpose |
| `egraph/` | the conditional rewrite |
| `DESIGN.md` | the full results with all the caveats |
| `DSE.md` | design-space exploration, formats, and the width study |
| `SWEEP.md` | the standalone adder width study |
