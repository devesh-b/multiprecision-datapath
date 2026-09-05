#!/usr/bin/env bash
# Does the shared-vs-dedicated verdict move with operand width?
#
# At 16 bits the shared multi-precision MAC loses to seven dedicated units.
# The width-dependence literature says a result at one width does not transfer,
# so this re-measures at 32 and 64. Sub-products grow as (W/4)^2 -- 16, 64, 256
# -- while the dedicated baseline grows as W^2 in its multipliers, so the two
# do not have to scale the same way.
set -u
cd "$(dirname "$0")"
mkdir -p results
OUT=results/width.csv
echo "W,design,cells_abc,depth_abc,ff" > $OUT

printf '%-4s %-14s %10s %8s %7s\n' 'W' 'design' 'cells' 'depth' 'FF'
printf '%s\n' '-----------------------------------------------'
for W in 16 32 64; do
  for base in mpmac_gen mac_sep_gen; do
    top=${base}${W}
    o=$(yosys -p "read_verilog -sv rtl/mpmac_gen.v; hierarchy -top $top; proc; opt -full; flatten; techmap; opt -full; abc -g AND,OR,XOR; opt -full; ltp; stat" 2>/dev/null)
    c=$(echo "$o" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
    d=$(echo "$o" | grep -oE 'length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
    f=$(echo "$o" | grep -oE '[0-9]+ +\$_S?DFF[A-Z0-9_]*_' | awk '{s+=$1} END {print s+0}')
    echo "$W,$base,${c:-},${d:-},${f:-}" >> $OUT
    printf '%-4s %-14s %10s %8s %7s\n' "$W" "$base" "${c:-?}" "${d:-?}" "${f:-?}"
  done
done
echo; echo "wrote $OUT"
