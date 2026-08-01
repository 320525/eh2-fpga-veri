`timescale 1ps / 1ps

// Simulation-only boundary stub for AXI checks immediately before the MIG.
// The testbench force-drives the UI clock, calibration status and AXI write
// slave response signals.  The real ddr4_0.xci remains enabled for synthesis.
module ddr4_0 (
  input  wire         sys_rst,
  input  wire         c0_sys_clk_p,
  input  wire         c0_sys_clk_n,
  output wire         c0_ddr4_act_n,
  output wire [16:0]  c0_ddr4_adr,
  output wire [1:0]   c0_ddr4_ba,
  output wire [1:0]   c0_ddr4_bg,
  output wire [0:0]   c0_ddr4_cke,
  output wire [0:0]   c0_ddr4_odt,
  output wire [0:0]   c0_ddr4_cs_n,
  output wire [0:0]   c0_ddr4_ck_t,
  output wire [0:0]   c0_ddr4_ck_c,
  output wire         c0_ddr4_reset_n,
  inout  wire [8:0]   c0_ddr4_dm_dbi_n,
  inout  wire [71:0]  c0_ddr4_dq,
  inout  wire [8:0]   c0_ddr4_dqs_c,
  inout  wire [8:0]   c0_ddr4_dqs_t,
  output wire         c0_init_calib_complete,
  output wire         c0_ddr4_ui_clk,
  output wire         c0_ddr4_ui_clk_sync_rst,
  output wire         dbg_clk,
  output wire [511:0] dbg_bus,

  input  wire         c0_ddr4_aresetn,
  input  wire         c0_ddr4_s_axi_ctrl_awvalid,
  output wire         c0_ddr4_s_axi_ctrl_awready,
  input  wire [31:0]  c0_ddr4_s_axi_ctrl_awaddr,
  input  wire         c0_ddr4_s_axi_ctrl_wvalid,
  output wire         c0_ddr4_s_axi_ctrl_wready,
  input  wire [31:0]  c0_ddr4_s_axi_ctrl_wdata,
  output wire         c0_ddr4_s_axi_ctrl_bvalid,
  input  wire         c0_ddr4_s_axi_ctrl_bready,
  output wire [1:0]   c0_ddr4_s_axi_ctrl_bresp,
  input  wire         c0_ddr4_s_axi_ctrl_arvalid,
  output wire         c0_ddr4_s_axi_ctrl_arready,
  input  wire [31:0]  c0_ddr4_s_axi_ctrl_araddr,
  output wire         c0_ddr4_s_axi_ctrl_rvalid,
  input  wire         c0_ddr4_s_axi_ctrl_rready,
  output wire [31:0]  c0_ddr4_s_axi_ctrl_rdata,
  output wire [1:0]   c0_ddr4_s_axi_ctrl_rresp,
  output wire         c0_ddr4_interrupt,

  input  wire [3:0]   c0_ddr4_s_axi_awid,
  input  wire [32:0]  c0_ddr4_s_axi_awaddr,
  input  wire [7:0]   c0_ddr4_s_axi_awlen,
  input  wire [2:0]   c0_ddr4_s_axi_awsize,
  input  wire [1:0]   c0_ddr4_s_axi_awburst,
  input  wire [0:0]   c0_ddr4_s_axi_awlock,
  input  wire [3:0]   c0_ddr4_s_axi_awcache,
  input  wire [2:0]   c0_ddr4_s_axi_awprot,
  input  wire [3:0]   c0_ddr4_s_axi_awqos,
  input  wire         c0_ddr4_s_axi_awvalid,
  output wire         c0_ddr4_s_axi_awready,
  input  wire [511:0] c0_ddr4_s_axi_wdata,
  input  wire [63:0]  c0_ddr4_s_axi_wstrb,
  input  wire         c0_ddr4_s_axi_wlast,
  input  wire         c0_ddr4_s_axi_wvalid,
  output wire         c0_ddr4_s_axi_wready,
  input  wire         c0_ddr4_s_axi_bready,
  output wire [3:0]   c0_ddr4_s_axi_bid,
  output wire [1:0]   c0_ddr4_s_axi_bresp,
  output wire         c0_ddr4_s_axi_bvalid,

  input  wire [3:0]   c0_ddr4_s_axi_arid,
  input  wire [32:0]  c0_ddr4_s_axi_araddr,
  input  wire [7:0]   c0_ddr4_s_axi_arlen,
  input  wire [2:0]   c0_ddr4_s_axi_arsize,
  input  wire [1:0]   c0_ddr4_s_axi_arburst,
  input  wire [0:0]   c0_ddr4_s_axi_arlock,
  input  wire [3:0]   c0_ddr4_s_axi_arcache,
  input  wire [2:0]   c0_ddr4_s_axi_arprot,
  input  wire [3:0]   c0_ddr4_s_axi_arqos,
  input  wire         c0_ddr4_s_axi_arvalid,
  output wire         c0_ddr4_s_axi_arready,
  input  wire         c0_ddr4_s_axi_rready,
  output wire [3:0]   c0_ddr4_s_axi_rid,
  output wire [511:0] c0_ddr4_s_axi_rdata,
  output wire [1:0]   c0_ddr4_s_axi_rresp,
  output wire         c0_ddr4_s_axi_rlast,
  output wire         c0_ddr4_s_axi_rvalid
);

  // Unused read/control/physical outputs are kept deterministic.  The write
  // response signals below are overridden by the testbench backend model.
  assign c0_ddr4_act_n               = 1'b1;
  assign c0_ddr4_adr                 = 17'd0;
  assign c0_ddr4_ba                  = 2'd0;
  assign c0_ddr4_bg                  = 2'd0;
  assign c0_ddr4_cke                 = 1'b0;
  assign c0_ddr4_odt                 = 1'b0;
  assign c0_ddr4_cs_n                = 1'b1;
  assign c0_ddr4_ck_t                = 1'b0;
  assign c0_ddr4_ck_c                = 1'b1;
  assign c0_ddr4_reset_n             = 1'b0;
  assign c0_init_calib_complete      = 1'b0;
  assign c0_ddr4_ui_clk              = 1'b0;
  assign c0_ddr4_ui_clk_sync_rst     = 1'b1;
  assign dbg_clk                     = 1'b0;
  assign dbg_bus                     = 512'd0;
  assign c0_ddr4_interrupt           = 1'b0;
  assign c0_ddr4_s_axi_ctrl_awready  = 1'b0;
  assign c0_ddr4_s_axi_ctrl_wready   = 1'b0;
  assign c0_ddr4_s_axi_ctrl_bvalid   = 1'b0;
  assign c0_ddr4_s_axi_ctrl_bresp    = 2'b00;
  assign c0_ddr4_s_axi_ctrl_arready  = 1'b0;
  assign c0_ddr4_s_axi_ctrl_rvalid   = 1'b0;
  assign c0_ddr4_s_axi_ctrl_rdata    = 32'd0;
  assign c0_ddr4_s_axi_ctrl_rresp    = 2'b00;
  assign c0_ddr4_s_axi_awready       = 1'b0;
  assign c0_ddr4_s_axi_wready        = 1'b0;
  assign c0_ddr4_s_axi_bid           = 4'd0;
  assign c0_ddr4_s_axi_bresp         = 2'b00;
  assign c0_ddr4_s_axi_bvalid        = 1'b0;
  assign c0_ddr4_s_axi_arready       = 1'b0;
  assign c0_ddr4_s_axi_rid           = 4'd0;
  assign c0_ddr4_s_axi_rdata         = 512'd0;
  assign c0_ddr4_s_axi_rresp         = 2'b00;
  assign c0_ddr4_s_axi_rlast         = 1'b0;
  assign c0_ddr4_s_axi_rvalid        = 1'b0;

endmodule
