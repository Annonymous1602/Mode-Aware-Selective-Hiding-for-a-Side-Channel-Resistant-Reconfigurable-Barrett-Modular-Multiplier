# Usage inside Vivado Tcl shell:
#   set PART xcku5p-ffvb676-2-e
#   source vivado_synth_qgsp.tcl
set TOP rbmm_qgsp
if {![info exists PART]} { set PART xcku5p-ffvb676-2-e }
read_verilog -sv rtl/rbmm_qgsp.v
synth_design -top $TOP -part $PART -flatten_hierarchy rebuilt
report_utilization -file reports/qgsp_utilization.rpt
report_timing_summary -file reports/qgsp_timing.rpt
report_power -file reports/qgsp_power.rpt
write_checkpoint -force reports/qgsp_post_synth.dcp
