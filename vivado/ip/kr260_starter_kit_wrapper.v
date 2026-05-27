//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2022.1 (lin64) Build 3526262 Mon Apr 18 15:47:01 MDT 2022
//Date        : Mon Oct 17 17:21:09 2022
//Host        : dje-X500 running 64-bit Ubuntu 20.04.5 LTS
//Command     : generate_target kr260_starter_kit_wrapper.bd
//Design      : kr260_starter_kit_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module kr260_starter_kit_wrapper
   (fan_en_b,
    gt_ref_clk_0_clk_n,
    gt_ref_clk_0_clk_p,
    gt_rx_0_gt_port_0_n,
    gt_rx_0_gt_port_0_p,
    gt_tx_0_gt_port_0_n,
    gt_tx_0_gt_port_0_p,
    sfp_tx_dis,
    som240_1_connector_sfp_led_tri_o,
    som240_2_connector_sfp_iic_scl_io,
    som240_2_connector_sfp_iic_sda_io);
  output [0:0]fan_en_b;
  input gt_ref_clk_0_clk_n;
  input gt_ref_clk_0_clk_p;
  input gt_rx_0_gt_port_0_n;
  input gt_rx_0_gt_port_0_p;
  output gt_tx_0_gt_port_0_n;
  output gt_tx_0_gt_port_0_p;
  output [0:0]sfp_tx_dis;
  output [1:0]som240_1_connector_sfp_led_tri_o;
  inout som240_2_connector_sfp_iic_scl_io;
  inout som240_2_connector_sfp_iic_sda_io;

  wire [0:0]fan_en_b;
  wire gt_ref_clk_0_clk_n;
  wire gt_ref_clk_0_clk_p;
  wire gt_rx_0_gt_port_0_n;
  wire gt_rx_0_gt_port_0_p;
  wire gt_tx_0_gt_port_0_n;
  wire gt_tx_0_gt_port_0_p;
  wire [0:0]sfp_tx_dis;
  wire [1:0]som240_1_connector_sfp_led_tri_o;
  wire som240_2_connector_sfp_iic_scl_i;
  wire som240_2_connector_sfp_iic_scl_io;
  wire som240_2_connector_sfp_iic_scl_o;
  wire som240_2_connector_sfp_iic_scl_t;
  wire som240_2_connector_sfp_iic_sda_i;
  wire som240_2_connector_sfp_iic_sda_io;
  wire som240_2_connector_sfp_iic_sda_o;
  wire som240_2_connector_sfp_iic_sda_t;

  kr260_starter_kit kr260_starter_kit_i
       (.fan_en_b(fan_en_b),
        .gt_ref_clk_0_clk_n(gt_ref_clk_0_clk_n),
        .gt_ref_clk_0_clk_p(gt_ref_clk_0_clk_p),
        .gt_rx_0_gt_port_0_n(gt_rx_0_gt_port_0_n),
        .gt_rx_0_gt_port_0_p(gt_rx_0_gt_port_0_p),
        .gt_tx_0_gt_port_0_n(gt_tx_0_gt_port_0_n),
        .gt_tx_0_gt_port_0_p(gt_tx_0_gt_port_0_p),
        .sfp_tx_dis(sfp_tx_dis),
        .som240_1_connector_sfp_led_tri_o(som240_1_connector_sfp_led_tri_o),
        .som240_2_connector_sfp_iic_scl_i(som240_2_connector_sfp_iic_scl_i),
        .som240_2_connector_sfp_iic_scl_o(som240_2_connector_sfp_iic_scl_o),
        .som240_2_connector_sfp_iic_scl_t(som240_2_connector_sfp_iic_scl_t),
        .som240_2_connector_sfp_iic_sda_i(som240_2_connector_sfp_iic_sda_i),
        .som240_2_connector_sfp_iic_sda_o(som240_2_connector_sfp_iic_sda_o),
        .som240_2_connector_sfp_iic_sda_t(som240_2_connector_sfp_iic_sda_t));
  IOBUF som240_2_connector_sfp_iic_scl_iobuf
       (.I(som240_2_connector_sfp_iic_scl_o),
        .IO(som240_2_connector_sfp_iic_scl_io),
        .O(som240_2_connector_sfp_iic_scl_i),
        .T(som240_2_connector_sfp_iic_scl_t));
  IOBUF som240_2_connector_sfp_iic_sda_iobuf
       (.I(som240_2_connector_sfp_iic_sda_o),
        .IO(som240_2_connector_sfp_iic_sda_io),
        .O(som240_2_connector_sfp_iic_sda_i),
        .T(som240_2_connector_sfp_iic_sda_t));
endmodule
