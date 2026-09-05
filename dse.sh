#!/usr/bin/env bash
# Design-space exploration: generate every variant of the datapath and
# synthesise it, emitting a machine-readable table.
#
# The space is (architecture x carry-propagate structure x precision mode).
# Locking `mode` to a constant lets synthesis specialise the design to one lane
# width, which is what makes a per-mode comparison meaningful rather than a
# worst-case-over-all-modes number.
#
# Output: results/dse.csv  (arch,cpa,mode,lanes,cells_raw,depth_raw,cells_abc,depth_abc)
set -u
cd "$(dirname "$0")"
mkdir -p results
OUT=results/dse.csv
FILES="rtl/adders.v rtl/mpmac.v rtl/mac_ref.v"
echo "arch,cpa,mode,lanes,cells_raw,depth_raw,cells_abc,depth_abc" > $OUT

syn () {   # $1=top  $2..=chparams
  local top=$1; shift
  local base="read_verilog -sv $FILES; hierarchy -top $top $*; proc; opt -full; flatten; techmap; opt -full"
  local raw abc
  raw=$(yosys -p "$base; ltp; stat" 2>/dev/null)
  abc=$(yosys -p "$base; abc -g AND,OR,XOR; opt -full; ltp; stat" 2>/dev/null)
  RC=$(echo "$raw" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
  RD=$(echo "$raw" | grep -oE 'length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
  AC=$(echo "$abc" | grep -E '^ +[0-9]+ cells' | tail -1 | awk '{print $1}')
  AD=$(echo "$abc" | grep -oE 'length=[0-9]+' | grep -oE '[0-9]+$' | tail -1)
}

for ARCH in 0 1; do
  aname=$([ $ARCH -eq 0 ] && echo shared || echo split)
  # split has no CPA family, so only the inferred adder is meaningful for it
  cpas=$([ $ARCH -eq 0 ] && echo "0 1 2" || echo "0")
  for CPA in $cpas; do
    cname=$([ $CPA -eq 0 ] && echo infer || { [ $CPA -eq 1 ] && echo rca || echo ksa; })
    for MODE in 0 1 2; do
      mname=$([ $MODE -eq 0 ] && echo M16 || { [ $MODE -eq 1 ] && echo M8 || echo M4; })
      lanes=$([ $MODE -eq 0 ] && echo 1 || { [ $MODE -eq 1 ] && echo 2 || echo 4; })
      syn mpmac_locked -chparam ARCH $ARCH -chparam CPA $CPA -chparam MODE $MODE
      echo "$aname,$cname,$mname,$lanes,${RC:-},${RD:-},${AC:-},${AD:-}" >> $OUT
      printf '%-7s %-6s %-4s lanes=%s  %6s/%-4s  %6s/%-4s\n' \
             "$aname" "$cname" "$mname" "$lanes" "${RC:-?}" "${RD:-?}" "${AC:-?}" "${AD:-?}"
    done
  done
done

# baselines, for reference rows
for top in mac_separate mac_fixed16; do
  syn $top
  echo "baseline,-,all,1,${RC:-},${RD:-},${AC:-},${AD:-}" >> $OUT
  printf '%-7s %-6s %-4s lanes=-  %6s/%-4s  %6s/%-4s\n' "$top" "-" "all" "${RC:-?}" "${RD:-?}" "${AC:-?}" "${AD:-?}"
done
echo
echo "wrote $OUT"
