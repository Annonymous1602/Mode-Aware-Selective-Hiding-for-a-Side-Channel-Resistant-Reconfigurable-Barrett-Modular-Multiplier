# Vivado synthesis flow for baseline/QGSP RBMM hardware overhead.
# Usage:
#   vivado -mode batch -source vivado_synth.tcl -tclargs qgsp 64
#   vivado -mode batch -source vivado_synth.tcl -tclargs baseline 64
# Optional environment variable:
#   export FPGA_PART=xcku5p-ffvb676-2-e

set design [lindex $argv 0]
set nbits  [lindex $argv 1]
if {$design eq ""} { set design "qgsp" }
if {$nbits eq ""} { set nbits "64" }
if {[info exists ::env(FPGA_PART)]} {
    set part $::env(FPGA_PART)
} else {
    set part "xcku5p-ffvb676-2-e"
}

file mkdir reports/vivado

if {$design eq "baseline"} {
    read_verilog -sv rtl/rbmm_baseline.v
    set top rbmm
} else {
    read_verilog -sv rtl/rbmm_qgsp.v
    set top rbmm_qgsp
}

synth_design -top $top -part $part -generic N=$nbits
opt_design
place_design
route_design

report_utilization -file reports/vivado/${design}_N${nbits}_util.rpt
report_timing_summary -file reports/vivado/${design}_N${nbits}_timing.rpt
report_power -file reports/vivado/${design}_N${nbits}_power.rpt
write_checkpoint -force reports/vivado/${design}_N${nbits}.dcp
