#!/usr/bin/env python3
"""Number-format accuracy study, to pair with the measured areas in results/dse.csv.

Two questions, kept separate because they have different answers:

  1. PRECISION (ar2-2). The datapath's three modes are 16-, 8- and 4-bit fixed
     point. Narrow modes buy lanes -- 1, 2 and 4 products per cycle -- so the
     honest cost axis is cells per product per cycle, not cells. Plotted against
     accuracy this is a real Pareto over hardware that exists and was measured.

  2. FORMAT (ar2-3). At a FIXED 16-bit width, how do fixed point, IEEE binary16
     and posit(16,1) compare on the same workload? This one is numerical only:
     there is no float or posit RTL here, so no area number belongs beside it.
     Saying so is more useful than inventing a cost model.

Posit values are obtained by decoding all 2^16 bit patterns and quantising to
the nearest representable value. Enumeration rather than an encoder because it
is obviously correct, and 65536 values is nothing.
"""
import math
import numpy as np

# ----------------------------------------------------------------- posit

def posit_decode(bits, n=16, es=1):
    """Decode an n-bit posit with es exponent bits. None means NaR."""
    if bits == 0:
        return 0.0
    if bits == 1 << (n - 1):
        return None                                   # NaR
    sign = bits >> (n - 1)
    if sign:
        bits = ((~bits) + 1) & ((1 << n) - 1)         # two's complement
    rest = bits & ((1 << (n - 1)) - 1)                # n-1 bits below the sign
    width = n - 1

    idx = width - 1
    first = (rest >> idx) & 1
    run = 0
    while idx >= 0 and ((rest >> idx) & 1) == first:
        run += 1
        idx -= 1
    k = (run - 1) if first == 1 else -run
    idx -= 1                                          # consume the terminating bit

    e = 0
    for _ in range(es):
        e <<= 1
        if idx >= 0:
            e |= (rest >> idx) & 1
            idx -= 1

    frac_bits = idx + 1
    f = (rest & ((1 << frac_bits) - 1)) if frac_bits > 0 else 0
    frac = 1.0 + (f / (1 << frac_bits) if frac_bits > 0 else 0.0)

    useed_pow = (1 << es)                             # log2(useed)
    val = frac * (2.0 ** (k * useed_pow + e))
    return -val if sign else val


def posit_table(n=16, es=1):
    vals = []
    for b in range(1 << n):
        v = posit_decode(b, n, es)
        if v is not None:
            vals.append(v)
    return np.array(sorted(set(vals)))


def quantise_to(table, x):
    """Round to the nearest entry of a sorted table."""
    idx = np.searchsorted(table, x)
    idx = np.clip(idx, 1, len(table) - 1)
    lo, hi = table[idx - 1], table[idx]
    return np.where(np.abs(x - lo) <= np.abs(hi - x), lo, hi)


# ------------------------------------------------------------ fixed point

def quantise_fixed(x, total_bits):
    """Signed fixed point with one sign bit and the rest fractional (Q1.f),
    saturating. Matches what the datapath's lanes actually hold."""
    f = total_bits - 1
    step = 2.0 ** (-f)
    lo, hi = -1.0, 1.0 - step
    return np.clip(np.round(x / step) * step, lo, hi)


def quantise_f16(x):
    return np.asarray(x, dtype=np.float16).astype(np.float64)


# -------------------------------------------------------------- workload

def workload(n_vec=2000, length=64, seed=20260905, kind="uniform"):
    """Dot products -- the operation the MAC performs.

    Two distributions, because the format comparison depends entirely on which
    one you use and quoting only the first would be misleading:

      uniform   values in [-1, 1). Bounded, known range. Fixed point's home
                ground, and what a normalised DNN layer looks like.
      wide      log-uniform over ~8 decades with random signs. Fixed point has
                to saturate at the top and underflow at the bottom; tapered and
                floating formats do not.
    """
    rng = np.random.default_rng(seed)
    if kind == "uniform":
        a = rng.uniform(-1.0, 1.0, size=(n_vec, length))
        b = rng.uniform(-1.0, 1.0, size=(n_vec, length))
    else:
        mag = lambda: 10.0 ** rng.uniform(-4.0, 4.0, size=(n_vec, length))
        sgn = lambda: rng.choice([-1.0, 1.0], size=(n_vec, length))
        a, b = sgn() * mag(), sgn() * mag()
    return a, b


def rel_err(ref, got):
    d = np.abs(got - ref)
    scale = np.abs(ref)
    ok = scale > 1e-12
    return float(np.sqrt(np.mean((d[ok] / scale[ok]) ** 2)))


def study_precision(kind="uniform"):
    a, b = workload(kind=kind)
    ref = np.einsum('ij,ij->i', a, b)
    out = {}
    for bits, lanes, mode in ((16, 1, 'M16'), (8, 2, 'M8'), (4, 4, 'M4')):
        qa, qb = quantise_fixed(a, bits), quantise_fixed(b, bits)
        out[mode] = (bits, lanes, rel_err(ref, np.einsum('ij,ij->i', qa, qb)))
    return out


def study_formats(kind="uniform"):
    a, b = workload(kind=kind)
    ref = np.einsum('ij,ij->i', a, b)
    tbl = posit_table(16, 1)
    out = {}
    for name, fn in (("fixed Q1.15", lambda x: quantise_fixed(x, 16)),
                     ("IEEE binary16", quantise_f16),
                     ("posit(16,1)", lambda x: quantise_to(tbl, x))):
        qa, qb = fn(a), fn(b)
        out[name] = rel_err(ref, np.einsum('ij,ij->i', qa, qb))
    return out, tbl


if __name__ == "__main__":
    t = posit_table(16, 1)
    print(f"posit(16,1): {len(t)} distinct values, "
          f"maxpos = 2^{math.log2(t.max()):.0f}, minpos = 2^{math.log2(t[t>0].min()):.0f}")
    assert abs(math.log2(t.max()) - 28) < 1e-9, "maxpos should be useed^(n-2) = 4^14 = 2^28"

    print("\nprecision modes (fixed point, dot product of length 64, uniform):")
    print("  mode  bits  lanes   RMS relative error")
    for mode, (bits, lanes, e) in study_precision().items():
        print(f"  {mode:4s}  {bits:4d}  {lanes:5d}   {e:.3e}")

    print("\n16-bit formats -- numerical only, no RTL for float or posit:")
    print(f"  {'format':15s} {'uniform [-1,1)':>16s} {'wide (8 decades)':>18s}")
    uni, _ = study_formats("uniform")
    wide, _ = study_formats("wide")
    for k in uni:
        print(f"  {k:15s} {uni[k]:16.3e} {wide[k]:18.3e}")
    print("\n  The ranking inverts, and posit is second in BOTH columns.")
    print("  Fixed point is best where the range is known and bounded, and fails")
    print("  outright where it is not. Posit(16,1) beats binary16 near 1, where its")
    print("  tapered accuracy spends bits on the fraction; binary16 beats posit over")
    print("  8 decades, because out at the extremes posit\'s regime field has eaten")
    print("  the bits the fraction needed. Tapered accuracy is a bet on the data")
    print("  sitting near 1, not a free win -- which is the useful thing to be able")
    print("  to say about posits, and the opposite of how they are usually pitched.")
