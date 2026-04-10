# ==============================================================================
# S80 NPU - FP16 MAC Synthesis Script
# Vivado 2025.2 Batch Mode
#
# Usage:
#   cd D:/_program/_aitest/ailab_test/scripts/vivado
#   C:/AMDDesignTools/2025.2/Vivado/bin/vivado -mode batch -source synth_fp16_mac.tcl
# ==============================================================================

set project_name "s80_fp16_mac"
set part         "xcku5p-ffvb676-2-e"
set top_module   "fp16_mac"
set rtl_dir      "../../rtl/common"
set report_dir   "reports"

# Create report directory
file mkdir $report_dir

# Create in-memory project
create_project -in_memory -part $part

# Add RTL sources
set sv_files [glob ${rtl_dir}/*.sv]
add_files $sv_files
set_property file_type SystemVerilog [get_files *.sv]

# Set FPGA define for DSP48E2 instantiation
set_property verilog_define {FPGA} [current_fileset]

# Set top module
set_property top $top_module [current_fileset]

# =========================================================================
# Synthesis
# =========================================================================

synth_design \
    -top $top_module \
    -part $part \
    -flatten_hierarchy rebuilt \
    -retiming

# =========================================================================
# Reports
# =========================================================================

report_utilization -file ${report_dir}/utilization.rpt
report_timing_summary -delay_type max -file ${report_dir}/timing_summary.rpt
report_timing -max_paths 10 -file ${report_dir}/timing_paths.rpt
report_drc -file ${report_dir}/drc.rpt
report_methodology -file ${report_dir}/methodology.rpt

# =========================================================================
# Summary to stdout
# =========================================================================

puts "======================================"
puts "  S80 FP16 MAC Synthesis Complete"
puts "======================================"
puts ""

# Print key utilization numbers
set util_rpt [report_utilization -return_string]
puts $util_rpt

# Print timing summary
set timing_rpt [report_timing_summary -return_string]
puts $timing_rpt

puts ""
puts "Reports saved to: ${report_dir}/"
puts "======================================"
