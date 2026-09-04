#!/usr/bin/env bash
# Does the best adder depend on operand width? Sweep and see.
# Two views per design:
#   as-written  = techmap+opt only, structure preserved
#   abc         = after ABC technology-independent optimisation
set -u
printf '%-4s %-6s | %-22s | %-22s\n' 'W' 'design' 'as-written (cells/depth)' 'after ABC (cells/depth)'
printf '%s\n' '---------------------------------------------------------------------------'
for W in 8 16 32 64; do
  for top in rca cla ksa; do
    raw=$(yosys -p "read_verilog rtl/adders.v; hierarchy -top $top -chparam W $W; proc; opt -full; techmap; opt -full; ltp; stat" 2>/dev/null)
    rc=$(echo "$raw" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
    rd=$(echo "$raw" |  grep -oE 'Longest topological path.*length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
    opt=$(yosys -p "read_verilog rtl/adders.v; hierarchy -top $top -chparam W $W; proc; opt -full; techmap; opt -full; abc -g AND,OR,XOR; opt -full; ltp; stat" 2>/dev/null)
    ac=$(echo "$opt" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
    ad=$(echo "$opt" |  grep -oE 'Longest topological path.*length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
    printf '%-4s %-6s | %10s / %-9s | %10s / %-9s\n' "$W" "$top" "${rc:-?}" "${rd:-?}" "${ac:-?}" "${ad:-?}"
  done
done
