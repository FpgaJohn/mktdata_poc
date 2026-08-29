# (C) Copyright 2020 - 2021 Xilinx, Inc.
# SPDX-License-Identifier: Apache-2.0

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

#Fan Speed Enable
set_property PACKAGE_PIN A12 [get_ports {fan_en_b}]
set_property IOSTANDARD LVCMOS33 [get_ports {fan_en_b}]
set_property SLEW SLOW [get_ports {fan_en_b}]
set_property DRIVE 4 [get_ports {fan_en_b}]

# GTH pins
set_property PACKAGE_PIN Y6 [get_ports gt_ref_clk_0_clk_p]
set_property PACKAGE_PIN T2 [get_ports gt_rx_0_gt_port_0_p]
set_property PACKAGE_PIN R4 [get_ports gt_tx_0_gt_port_0_p]

#K260 Robotics Card pins
# sfp pins
set_property IOSTANDARD LVCMOS33 [get_ports {sfp_tx_dis[0]}]
set_property PACKAGE_PIN Y10 [get_ports {sfp_tx_dis[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {som240_1_connector_sfp_led_tri_o[0]}]
set_property PACKAGE_PIN G8 [get_ports {som240_1_connector_sfp_led_tri_o[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {som240_1_connector_sfp_led_tri_o[1]}]
set_property PACKAGE_PIN F7 [get_ports {som240_1_connector_sfp_led_tri_o[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {som240_2_connector_sfp_iic_scl_io}]
set_property PACKAGE_PIN AB11 [get_ports {som240_2_connector_sfp_iic_scl_io}]
set_property IOSTANDARD LVCMOS33 [get_ports {som240_2_connector_sfp_iic_sda_io}]
set_property PACKAGE_PIN AC11 [get_ports {som240_2_connector_sfp_iic_sda_io}]

#set_property IOSTANDARD LVCMOS33 [get_ports {sfp_tx_fault[0]}]
#set_property PACKAGE_PIN A10 [get_ports {sfp_tx_fault[0]}]
#set_property IOSTANDARD LVCMOS33 [get_ports {sfp_mod_abs[0]}]
#set_property PACKAGE_PIN AA11 [get_ports {sfp_mod_abs[0]}]

# ---------------------------------------------------------------------------
# CDC exceptions: clk_pl_0 (PS 100 MHz) <-> S02_ACLK_1 (10G RX userclk,
# 156.25 MHz recovered from the SFP line by the GTH, xxv_ethernet_0).
#
# WHY: the two clocks come from different oscillators (PS PLL vs GT CDR), so
# they have no usable phase relationship. Without an exception Vivado still
# times every path between them against their worst-case computed edge
# alignment -- a 0.4 ns "requirement" that no logic can meet and no logic
# needs to meet. Before this exception the pair carried ~3.4k failing
# endpoints at WNS -2.5 ns and report_clock_interaction classified it
# "No Common Clock / Partial False Path (unsafe)".
#
# WHY THIS IS SAFE (audited via report_cdc + routed-DCP path analysis):
#   - single-bit crossings (incl. the GPIO-driven ctrlind_20_ip_reset, a
#     set-and-forget soft reset) land on NI DoubleSync two-flop synchronizers;
#   - multi-bit data between the LabVIEW 100 MHz and 156.25 MHz loops moves
#     through LabVIEW FPGA FIFOs (async-FIFO handshake), never raw registers.
#
# WHY set_max_delay AND NOT set_clock_groups: the NI IP's own exported
# constraints already bound its other domain pairs (clk_pl_0<->S01_ACLK_1,
# S01<->S02) with set_max_delay -datapath_only at one SOURCE-clock period.
# We complete that same pattern for the one pair the export misses.
# A blanket set_clock_groups -asynchronous would take precedence over and
# cancel those NI bounds, leaving every crossing entirely untimed; max_delay
# keeps the datapath (and therefore inter-bit skew into the FIFO/DoubleSync
# capture window) bounded. -datapath_only excludes clock skew/pessimism, as
# is standard for CDC bounds.
#
# Clock names are the auto-derived generated-clock names (stable for this BD;
# re-derive with report_clocks if the ethernet IP is reconfigured). get_clocks
# fails loudly if a name disappears -- do not add -quiet.
# ---------------------------------------------------------------------------
set_max_delay -datapath_only -from [get_clocks clk_pl_0]   -to [get_clocks S02_ACLK_1] 10.000
set_max_delay -datapath_only -from [get_clocks S02_ACLK_1] -to [get_clocks clk_pl_0]    6.400

# timing constraints
set_false_path -to [get_ports {som240_2_connector_sfp_iic_scl_io*}]
set_false_path -to [get_ports {som240_2_connector_sfp_iic_sda_io*}]
set_false_path -from [get_ports {som240_2_connector_sfp_iic_scl_io*}]
set_false_path -from [get_ports {som240_2_connector_sfp_iic_sda_io*}]

set_false_path -to [get_ports {som240_1_connector_sfp_led_tri_o*}]
