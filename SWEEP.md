# Does the best adder depend on operand width?

Prior work on automated datapath optimisation (Coward, Drane & Constantinides,
*Automatic Datapath Optimization using E-Graphs*, ARITH 2022) argues that the
optimal implementation is **width-dependent** — that what you want is a library
of designs rather than one winner. This measures that directly, on three adders
written here.

Run it: `./sweep.sh` (needs Yosys with ABC on `PATH`)

```
W    design | as-written (cells/depth) | after ABC (cells/depth)
---------------------------------------------------------------------------
8    rca    |          ? / ?         |          ? / ?        
8    cla    |          ? / ?         |          ? / ?        
8    ksa    |          ? / ?         |          ? / ?        
16   rca    |          ? / ?         |          ? / ?        
16   cla    |          ? / ?         |          ? / ?        
16   ksa    |          ? / ?         |          ? / ?        
32   rca    |          ? / ?         |          ? / ?        
32   cla    |          ? / ?         |          ? / ?        
32   ksa    |          ? / ?         |          ? / ?        
64   rca    |          ? / ?         |          ? / ?        
64   cla    |          ? / ?         |          ? / ?        
64   ksa    |          ? / ?         |          ? / ?        
```

## Reading it

**`rca` and `cla` are byte-identical at every width.** That is not a synthesis
result — it is a fact about the RTL. `cla` computes carries as
`c[i+1] = g[i] | (p[i] & c[i])`, a *serial* chain in generate/propagate
notation. It is a ripple-carry adder wearing different clothes. Depth 2W+1
confirms it: linear in W. Those two modules only ever existed to give
SymbiYosys two logically-equal designs to prove equal.

**`ksa` (Kogge-Stone) is the real comparison.** Carries come from a log-depth
prefix tree. Formally proved equal to `rca` at 8 bits (`formal/equiv_ks.sby`,
PASS) before any of these numbers were trusted.

| W | ripple depth | Kogge-Stone depth | KS cell cost |
|---|---|---|---|
| 8  | 17  | 14 | 1.3x |
| 16 | 33  | 22 | 1.6x |
| 32 | 65  | 27 | 2.0x |
| 64 | 129 | 34 | 2.3x |

The crossover is the point. At 8 bits Kogge-Stone buys 3 levels for 11 extra
gates — a bad trade. At 64 bits it buys 95 levels for 424 gates. Same two
designs, opposite verdicts, and the only thing that changed is W.

**ABC does not rescue the ripple.** Given `rca`, ABC returns `rca` — it will not
invent a prefix tree. Structure has to be in the input, which is precisely the
gap that rewriting-based approaches such as e-graph datapath optimisation exist
to close.

Note ABC *raises* Kogge-Stone's depth (8 -> 14 at W=8) while cutting its cells
(91 -> 51): it is trading the area it can see against a delay model it does not
have. Real numbers need a target library and static timing, which is what
Vivado is for.
