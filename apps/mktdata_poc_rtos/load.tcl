# load.tcl -- program the FPGA via JTAG, run psu_init, download + run the ELF.
#
# Identical flow to apps/mktdata_poc_bm/load.tcl -- only the app name differs.
# The JTAG layer doesn't know (or care) that the ELF contains a FreeRTOS
# scheduler.
#
# Two modes:
#   1. Hot takeover (default) -- Linux is running, we stop A53 #0, reprogram
#      PL, deassert PS-PL isolation/AFI/reset, run our ELF.
#   2. Cold JTAG boot -- DIPs in JTAG mode. Set COLD_BOOT=1 to run full psu_init.

set this_dir [file dirname [file normalize [info script]]]
set ws_path  [file normalize "$this_dir/vitis_ws"]
set platform mktdata_poc
set app      mktdata_poc_rtos
set elf      $ws_path/$app/Debug/$app.elf

set bit      [file normalize "$this_dir/vitis_ws/$platform/hw/mktdata_poc.bit"]
set psu_init_file [file normalize "$this_dir/vitis_ws/$platform/hw/psu_init.tcl"]

foreach f [list $elf $bit $psu_init_file] {
    if {![file exists $f]} { error "missing: $f" }
}

set cold_boot [expr {[info exists ::env(COLD_BOOT)] && $::env(COLD_BOOT)}]

set kr260_cable {jtag_cable_name =~ "Xilinx*"}

connect

if {$cold_boot} {
    puts "load.tcl: cold JTAG boot -- full psu_init"
    targets -set -filter "name =~ \"PSU\" && $kr260_cable"
    rst -system
    after 1000
    targets -set -filter "name =~ \"PS TAP\" && $kr260_cable"
    fpga $bit
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    source $psu_init_file
    psu_init
    puts "load.tcl: psu_init complete"
} else {
    puts "load.tcl: hot takeover from Linux"
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    catch {stop}
    after 500

    targets -set -filter "name =~ \"PS TAP\" && $kr260_cable"
    fpga $bit
    after 500

    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    source $psu_init_file

    configparams force-mem-accesses 1
    psu_ps_pl_isolation_removal
    puts "load.tcl: PS-PL isolation removed"

    mask_write 0XFD1A0100 0x00001F80 0x00000000
    puts "load.tcl: AFI configured"

    psu_ps_pl_reset_config
    puts "load.tcl: PS-PL resets released"
    configparams force-mem-accesses 0
}

targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
rst -processor
after 200

dow $elf
con

puts "load.tcl: ELF running. UART output on ttyUSB at 115200 8N1."
