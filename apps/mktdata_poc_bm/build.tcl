# build.tcl -- build the bare-metal app via xsct (Vitis Classic command line).
#
# Run from this directory:
#   source /tools/Xilinx/Vitis/2024.1/settings64.sh
#   xsct build.tcl
#
# Outputs:
#   vitis_ws/                                      Vitis workspace
#   vitis_ws/mktdata_poc_bm/Debug/mktdata_poc_bm.elf
#
# After build, load to the board via load.tcl (separate JTAG flow).

set this_dir [file dirname [file normalize [info script]]]
set xsa_path [file normalize "$this_dir/../../vivado/mktdata_poc.xsa"]
set ws_path  [file normalize "$this_dir/vitis_ws"]
set platform mktdata_poc
set app      mktdata_poc_bm
# KR260 = ZynqMP ZU5EV: quad Cortex-A53 APU. PS0 is the boot APU.
set domain   standalone_domain
set cpu      psu_cortexa53_0

puts "build.tcl: workspace = $ws_path"
puts "build.tcl: XSA       = $xsa_path"

if {![file exists $xsa_path]} {
    error "XSA not found at $xsa_path -- run 'make xsa' in ../../vivado first"
}

file mkdir $ws_path
setws $ws_path

# Create platform if not already present. xsct throws "No platform exist" on
# an empty workspace instead of returning an empty list -- catch it.
if {[catch {platform list} existing] || [lsearch $existing $platform] < 0} {
    puts "build.tcl: creating platform $platform"
    platform create -name $platform -hw $xsa_path -proc $cpu \
                    -os standalone -fsbl-target $cpu
    platform write
    platform generate
} else {
    puts "build.tcl: platform $platform already exists, skipping create"
    platform active $platform
}

# Create application if not already present.
if {[catch {app list} existing] || [lsearch $existing $app] < 0} {
    puts "build.tcl: creating app $app"
    app create -name $app -platform $platform -domain $domain \
               -template "Empty Application(C)" -lang C
}

# Always re-import main.c so edits flow through on incremental rebuilds.
puts "build.tcl: importing main.c"
importsources -name $app -path $this_dir/main.c

puts "build.tcl: building $app"
app build -name $app

set elf $ws_path/$app/Debug/$app.elf
if {[file exists $elf]} {
    puts "build.tcl: built $elf"
} else {
    error "build failed -- no $elf"
}
