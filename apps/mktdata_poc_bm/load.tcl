# load.tcl -- program the FPGA via JTAG, run psu_init, download + run the ELF.
#
# Prereq: a JTAG cable on the KR260's J7 FTDI USB. Board powered on.
# To get back to Ubuntu after a session: power-cycle the board.
#
# Two modes of operation:
#   1. Hot takeover (default) -- Linux is running, we stop the kernel, reprogram
#      PL, and run our ELF. Skips full psu_init (DDR/PLL/MIO already done).
#   2. Cold JTAG boot -- board booted with DIPs in JTAG mode, PS needs full
#      init. Set env COLD_BOOT=1 before running to use this mode.
#
# Handles multiple JTAG cables: filters for the KR260 (Xilinx SCK-KR) so it
# works even with other boards connected simultaneously.
#
# Run from this directory:
#   source /tools/Xilinx/Vitis/2024.1/settings64.sh
#   xsct load.tcl
#
# UART comes out on the FTDI USB at 115200 8N1.

set this_dir [file dirname [file normalize [info script]]]
set ws_path  [file normalize "$this_dir/vitis_ws"]
set platform mktdata_poc
set app      mktdata_poc_bm
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
    # Halt A53 #0 before any register writes -- after rst -system the core is
    # running BootROM, and psu_init's mwr fails with "not stopped" otherwise.
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    catch {stop}
    after 500
    targets -set -filter "name =~ \"PS TAP\" && $kr260_cable"
    fpga $bit
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    catch {stop}
    source $psu_init_file

    # On a JTAG cold boot the USB/SATA/DP/PCIe power islands are never brought
    # up (no FSBL ran), so psu_resetout_init_data's writes to peripheral-PHY
    # registers such as GUSB2PHYCFG (0xFE20C200) fault with "AXI AP transaction
    # error". xsct's mask_write only tolerates write-only-register reads, so any
    # other read fault aborts psu_init *before* it releases the PL (FCLK resets,
    # AFI). None of those peripherals are needed for the PL self-tests, so wrap
    # mask_write/mask_poll to skip-and-log a faulting access; the PL-relevant
    # writes (always-on CRL/CRF/SLCR space) still go through.
    #
    # The override must be installed on ::xsdb::mask_write / ::xsdb::mask_poll,
    # not the global imports: psu_init's init_ps lives in ::xsdb, so it resolves
    # these names there first -- a global override is bypassed.
    set ::psu_skips {}
    rename ::xsdb::mask_write ::xsdb::__real_mask_write
    proc ::xsdb::mask_write {addr mask data} {
        if {[catch {::xsdb::__real_mask_write $addr $mask $data} msg]} {
            lappend ::psu_skips $addr
            puts "load.tcl: skip mask_write $addr ($msg)"
        }
    }
    rename ::xsdb::mask_poll ::xsdb::__real_mask_poll
    proc ::xsdb::mask_poll {addr mask} {
        if {[catch {::xsdb::__real_mask_poll $addr $mask} msg]} {
            lappend ::psu_skips $addr
            puts "load.tcl: skip mask_poll $addr ($msg)"
        }
    }

    psu_init

    rename ::xsdb::mask_write {}
    rename ::xsdb::__real_mask_write ::xsdb::mask_write
    rename ::xsdb::mask_poll {}
    rename ::xsdb::__real_mask_poll ::xsdb::mask_poll
    puts "load.tcl: psu_init complete ([llength $::psu_skips] inaccessible reg writes skipped)"

    # psu_init does NOT remove PS-PL isolation or release the PL resets -- in the
    # FSBL flow that is psu_post_config. Without it the PL stays held in reset
    # and the first AXI access to a PL slave (e.g. axi_gpio at 0xA0040000) hangs
    # the core. Do the same PS-PL bring-up the hot path does. The A53 is stopped
    # at reset (MMU off) so writes via the core target work with force-mem.
    configparams force-mem-accesses 1
    psu_ps_pl_isolation_removal
    mask_write 0XFD1A0100 0x00001F80 0x00000000
    psu_ps_pl_reset_config
    configparams force-mem-accesses 0
    puts "load.tcl: PS-PL isolation removed + resets released"
} else {
    puts "load.tcl: hot takeover from Linux"
    # Stop A53 #0 (running Linux kernel, or already stopped from prior run).
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    catch {stop}
    after 500

    # Program PL -- PS stays alive, DDR contents preserved.
    targets -set -filter "name =~ \"PS TAP\" && $kr260_cable"
    fpga $bit
    after 500

    # Source psu_init.tcl for its helper procs and data variables.
    targets -set -filter "name =~ \"Cortex-A53 #0\" && $kr260_cable"
    source $psu_init_file

    # Run the subset of psu_init needed for PL access on the FPD path:
    #   1. PS-PL isolation removal (power up PL domain)
    #   2. AFI deassert + fabric-width config (FPD AFI 0-5)
    #   3. PS-PL reset release (deassert FCLKRESETN via EMIO)
    # These touch LPD/FPD SLCR registers by physical address. Linux left the
    # A53 MMU enabled, so issuing them through the core faults (translation
    # fault). Target the PSU node instead -- its accesses go through the DAP
    # MEM-AP, which are physical and bypass the core MMU. (There is no target
    # literally named "DAP" in this board's xsct tree; "PSU" is that node.)
    targets -set -filter "name =~ \"PSU\" && $kr260_cable"
    configparams force-mem-accesses 1
    psu_ps_pl_isolation_removal
    puts "load.tcl: PS-PL isolation removed"

    # Deassert FPD AFI resets (FM0-FM5).
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
