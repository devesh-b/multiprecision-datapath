# Out-of-context synthesis for the multi-precision MAC and its baselines.
#
# Run twice on purpose:
#   dsp   - Vivado free to infer DSP48E1. The behavioural baselines map their
#           whole multiply-accumulate (accumulator included) into hard macros;
#           the hand-decomposed datapath cannot. This is what the FPGA really
#           gives you, and it is not an apples-to-apples logic comparison.
#   nodsp - -max_dsp 0 forces everything into LUTs. This is the fair
#           architecture-vs-architecture number.
set part xc7a100tcsg324-1
set period 10.000
set designs [list mpmac_split mpmac_shared mpmac_rca mpmac_ksa mac_separate mac_fixed16]
set fh [open "ooc_results.txt" w]
puts $fh [format "%-6s %-14s %7s %7s %6s %8s %10s %10s" mode design LUT FF DSP CARRY4 "WNS_r2r" "WNS_all"]
foreach {tag maxdsp} {dsp -1 nodsp 0} {
  foreach top $designs {
    read_verilog -sv [list ../rtl/adders.v ../rtl/mpmac.v ../rtl/mac_ref.v]
    if {$maxdsp >= 0} {
      synth_design -top $top -part $part -mode out_of_context \
                   -flatten_hierarchy full -max_dsp $maxdsp
    } else {
      synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy full
    }
    create_clock -name clk -period $period [get_ports clk]

    set lut [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
    set ff  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
    set dsp [llength [get_cells -hier -filter {REF_NAME =~ "DSP*"}]]
    set cy  [llength [get_cells -hier -filter {REF_NAME == CARRY4}]]

    set p_r2r [get_timing_paths -from [all_registers] -to [all_registers] \
                                -delay_type max -max_paths 1]
    set wns_r2r [expr {[llength $p_r2r] ? [get_property SLACK $p_r2r] : "n/a"}]

    set_input_delay  -clock clk 0.000 [filter [all_inputs] {NAME != "clk"}]
    set_output_delay -clock clk 0.000 [all_outputs]
    set p_all [get_timing_paths -delay_type max -max_paths 1]
    set wns_all [expr {[llength $p_all] ? [get_property SLACK $p_all] : "n/a"}]

    puts $fh [format "%-6s %-14s %7d %7d %6d %8d %10s %10s" \
                     $tag $top $lut $ff $dsp $cy $wns_r2r $wns_all]
    flush $fh
    close_design
  }
}
close $fh
