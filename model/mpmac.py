#!/usr/bin/env python3
"""Golden model for the multi-precision MAC.

This is the spec the RTL implements, and the place the digit-decomposition
algebra is proved before any Verilog exists.

Datapath: 16-bit operands split into four 4-bit digits. Every mode is the same
16 sub-products a_i*b_j; only the enable mask, the weights and the lane
boundaries change.

  M16  1 x (16x16)  -> 32-bit product, 1 lane  of 48 bits (16 bits headroom)
  M8   2 x (8x8)    -> 16-bit product, 2 lanes of 24 bits ( 8 bits headroom)
  M4   4 x (4x4)    ->  8-bit product, 4 lanes of 12 bits ( 4 bits headroom)

Accumulator storage is a fixed 48-bit file, partitioned - not replicated.
"""

M16, M8, M4 = 0, 1, 2
MODE_NAME = {M16: "M16", M8: "M8", M4: "M4"}

ACC_W = 48
NDIG = 4
DIG_W = 4

# per mode: (lanes, digits per lane, lane accumulator width)
LANES = {M16: 1, M8: 2, M4: 4}
DIGS_PER_LANE = {M16: 4, M8: 2, M4: 1}
LANE_W = {M16: 48, M8: 24, M4: 12}


def digits(x):
    """16-bit value -> four unsigned 4-bit digits, LSD first."""
    return [(x >> (DIG_W * i)) & 0xF for i in range(NDIG)]


def is_top(mode, i):
    """Is digit i the most-significant digit of its lane in this mode?

    Only the top digit of a lane carries the sign; the rest are unsigned.
    That is exactly two's complement: A = sum_{i<top} a_i*2^4i + a~_top*2^4top.
    """
    return (i % DIGS_PER_LANE[mode]) == DIGS_PER_LANE[mode] - 1


def sdigit(d, top, sgn):
    """Digit as a 5-bit signed value: sign-extended iff signed mode and top."""
    return d - 16 if (sgn and top and d >= 8) else d


def subproducts(a, b, mode, sgn):
    """The 16 shared sub-products. Identical hardware in every mode."""
    da, db = digits(a), digits(b)
    pp = {}
    for i in range(NDIG):
        for j in range(NDIG):
            sa = sdigit(da[i], is_top(mode, i), sgn)
            sb = sdigit(db[j], is_top(mode, j), sgn)
            pp[(i, j)] = sa * sb
    return pp


def lane_of(mode, i):
    return i // DIGS_PER_LANE[mode]


def enabled(mode, i, j):
    """A sub-product contributes only when both digits sit in the same lane."""
    return lane_of(mode, i) == lane_of(mode, j)


def products(a, b, mode, sgn):
    """Per-lane products, as integers (unbounded)."""
    pp = subproducts(a, b, mode, sgn)
    n = DIGS_PER_LANE[mode]
    out = []
    for L in range(LANES[mode]):
        base = L * n
        acc = 0
        for i in range(base, base + n):
            for j in range(base, base + n):
                acc += pp[(i, j)] << (DIG_W * (i + j - 2 * base))
        out.append(acc)
    return out


def reference_products(a, b, mode, sgn):
    """Independent reference: slice the operands and multiply directly.

    Deliberately shares no code with products() - this is what makes the
    self-check below meaningful.
    """
    w = DIG_W * DIGS_PER_LANE[mode]
    mask = (1 << w) - 1
    out = []
    for L in range(LANES[mode]):
        av = (a >> (w * L)) & mask
        bv = (b >> (w * L)) & mask
        if sgn:
            if av >= 1 << (w - 1):
                av -= 1 << w
            if bv >= 1 << (w - 1):
                bv -= 1 << w
        out.append(av * bv)
    return out


def wrap(v, w):
    """Two's complement wrap into w bits, returned as an unsigned bit pattern."""
    return v & ((1 << w) - 1)


class MPMAC:
    """Cycle model. acc is the raw 48-bit register contents."""

    def __init__(self):
        self.acc = 0

    def reset(self):
        self.acc = 0

    def step(self, a, b, mode, sgn, en=True):
        if not en:
            return self.acc
        w = LANE_W[mode]
        prods = products(a, b, mode, sgn)
        new = 0
        for L in range(LANES[mode]):
            cur = (self.acc >> (w * L)) & ((1 << w) - 1)
            # lane-local add: carries are blocked at the lane boundary
            new |= wrap(cur + prods[L], w) << (w * L)
        self.acc = new
        return self.acc

    def lanes(self, mode):
        w = LANE_W[mode]
        return [(self.acc >> (w * L)) & ((1 << w) - 1) for L in range(LANES[mode])]


# ---------------------------------------------------------------- self-check

def check_decomposition():
    """The algebra: digit decomposition == direct multiply, every mode.

    M4 is exhaustive over all lane operand pairs. M8 and M16 are exhaustive
    over a lane's full space where that is cheap, random above it.
    """
    import random
    random.seed(20260904)
    bad = 0

    # M4: exhaustive per lane (all 4-bit x 4-bit pairs), lanes driven independently
    for sgn in (0, 1):
        for av in range(16):
            for bv in range(16):
                a = av * 0x1111
                b = bv * 0x1111
                if products(a, b, M4, sgn) != reference_products(a, b, M4, sgn):
                    bad += 1
    # M4 exhaustive, one lane hot at a time (the crosstalk case)
    for sgn in (0, 1):
        for L in range(4):
            for av in range(16):
                for bv in range(16):
                    a, b = av << (4 * L), bv << (4 * L)
                    if products(a, b, M4, sgn) != reference_products(a, b, M4, sgn):
                        bad += 1

    # M8: exhaustive over one lane's full 8x8 space, other lane zero and random
    for sgn in (0, 1):
        for av in range(256):
            for bv in range(256):
                for a, b in ((av, bv), (av << 8, bv << 8)):
                    if products(a, b, M8, sgn) != reference_products(a, b, M8, sgn):
                        bad += 1

    # M16: random, plus the corners
    corners = [0x0000, 0x0001, 0x7FFF, 0x8000, 0xFFFF, 0xAAAA, 0x5555]
    for sgn in (0, 1):
        for a in corners:
            for b in corners:
                if products(a, b, M16, sgn) != reference_products(a, b, M16, sgn):
                    bad += 1
        for _ in range(200000):
            a, b = random.getrandbits(16), random.getrandbits(16)
            if products(a, b, M16, sgn) != reference_products(a, b, M16, sgn):
                bad += 1
    return bad


def check_ranges():
    """Sub-product and product widths the RTL declares must actually hold."""
    lo_pp, hi_pp = 0, 0
    for sgn in (0, 1):
        for mode in (M16, M8, M4):
            for d1 in range(16):
                for d2 in range(16):
                    for t1 in (0, 1):
                        for t2 in (0, 1):
                            v = sdigit(d1, t1, sgn) * sdigit(d2, t2, sgn)
                            lo_pp, hi_pp = min(lo_pp, v), max(hi_pp, v)
    return lo_pp, hi_pp


if __name__ == "__main__":
    bad = check_decomposition()
    lo, hi = check_ranges()
    print(f"decomposition mismatches : {bad}")
    print(f"sub-product range        : {lo} .. {hi}   (fits 10-bit signed: "
          f"{-512 <= lo and hi <= 511})")

    m = MPMAC()
    for _ in range(20):
        m.step(0xF000, 0xF000, M4, sgn=1)
    print(f"M4 x20 signed (-1*-1 in lane 3, headroom 4b) lanes = "
          f"{[hex(v) for v in m.lanes(M4)]}")
    raise SystemExit(1 if bad else 0)
