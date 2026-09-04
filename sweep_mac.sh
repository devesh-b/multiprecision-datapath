#!/usr/bin/env bash
# Area/depth of the multi-precision MAC against its baselines.
# Same flow as sweep.sh so the numbers sit next to the adder study.
#
#   as-written = proc/opt/techmap/opt, structure preserved
#   abc        = + technology-independent optimisation
set -u
cd "$(dirname "$0")"

designs="mpmac_split mpmac_shared mac_separate mac_fixed16"

printf '%-14s | %-21s | %-21s | %-7s | %s\n' 'design' 'as-written cells/depth' 'after ABC cells/depth' 'FF bits' 'logic cells (ABC)'
printf '%s\n' '----------------------------------------------------------------------------------------------------'
for top in $designs; do
  base="read_verilog -sv rtl/adders.v rtl/mpmac.v rtl/mac_ref.v; hierarchy -top $top; proc; opt -full; flatten; techmap; opt -full"
  raw=$(yosys -p "$base; ltp; stat" 2>/dev/null)
  opt=$(yosys -p "$base; abc -g AND,OR,XOR; opt -full; ltp; stat" 2>/dev/null)

  rc=$(echo "$raw" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
  rd=$(echo "$raw" | grep -oE 'Longest topological path.*length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
  ac=$(echo "$opt" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
  ad=$(echo "$opt" | grep -oE 'Longest topological path.*length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
  ff=$(echo "$opt" | grep -oE '[0-9]+ +\$_S?DFF[A-Z0-9_]*_' | awk '{s+=$1} END {print s+0}')
  logic=$(( ${ac:-0} - ${ff:-0} ))

  printf '%-14s | %9s / %-9s | %9s / %-9s | %7s | %s\n' \
         "$top" "${rc:-?}" "${rd:-?}" "${ac:-?}" "${ad:-?}" "${ff:-?}" "$logic"
done
