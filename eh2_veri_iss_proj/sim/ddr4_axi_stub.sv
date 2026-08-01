`timescale 1ns/1ps

`define DDR4_STUB_PORTS \
  output logic c0_init_calib_complete, output wire dbg_clk, \
  input wire c0_sys_clk_p, input wire c0_sys_clk_n, output wire [511:0] dbg_bus, \
  output wire [16:0] c0_ddr4_adr, output wire [1:0] c0_ddr4_ba, \
  output wire [0:0] c0_ddr4_cke, output wire [0:0] c0_ddr4_cs_n, \
  inout wire [8:0] c0_ddr4_dm_dbi_n, inout wire [71:0] c0_ddr4_dq, \
  inout wire [8:0] c0_ddr4_dqs_c, inout wire [8:0] c0_ddr4_dqs_t, \
  output wire [0:0] c0_ddr4_odt, output wire [1:0] c0_ddr4_bg, \
  output wire c0_ddr4_reset_n, output wire c0_ddr4_act_n, \
  output wire [0:0] c0_ddr4_ck_c, output wire [0:0] c0_ddr4_ck_t, \
  output wire c0_ddr4_ui_clk, output logic c0_ddr4_ui_clk_sync_rst, \
  input wire c0_ddr4_aresetn, \
  input wire c0_ddr4_s_axi_ctrl_awvalid, output wire c0_ddr4_s_axi_ctrl_awready, \
  input wire [31:0] c0_ddr4_s_axi_ctrl_awaddr, input wire c0_ddr4_s_axi_ctrl_wvalid, \
  output wire c0_ddr4_s_axi_ctrl_wready, input wire [31:0] c0_ddr4_s_axi_ctrl_wdata, \
  output wire c0_ddr4_s_axi_ctrl_bvalid, input wire c0_ddr4_s_axi_ctrl_bready, \
  output wire [1:0] c0_ddr4_s_axi_ctrl_bresp, input wire c0_ddr4_s_axi_ctrl_arvalid, \
  output wire c0_ddr4_s_axi_ctrl_arready, input wire [31:0] c0_ddr4_s_axi_ctrl_araddr, \
  output wire c0_ddr4_s_axi_ctrl_rvalid, input wire c0_ddr4_s_axi_ctrl_rready, \
  output wire [31:0] c0_ddr4_s_axi_ctrl_rdata, output wire [1:0] c0_ddr4_s_axi_ctrl_rresp, \
  output wire c0_ddr4_interrupt, input wire [3:0] c0_ddr4_s_axi_awid, \
  input wire [32:0] c0_ddr4_s_axi_awaddr, input wire [7:0] c0_ddr4_s_axi_awlen, \
  input wire [2:0] c0_ddr4_s_axi_awsize, input wire [1:0] c0_ddr4_s_axi_awburst, \
  input wire [0:0] c0_ddr4_s_axi_awlock, input wire [3:0] c0_ddr4_s_axi_awcache, \
  input wire [2:0] c0_ddr4_s_axi_awprot, input wire [3:0] c0_ddr4_s_axi_awqos, \
  input wire c0_ddr4_s_axi_awvalid, output wire c0_ddr4_s_axi_awready, \
  input wire [511:0] c0_ddr4_s_axi_wdata, input wire [63:0] c0_ddr4_s_axi_wstrb, \
  input wire c0_ddr4_s_axi_wlast, input wire c0_ddr4_s_axi_wvalid, \
  output wire c0_ddr4_s_axi_wready, input wire c0_ddr4_s_axi_bready, \
  output wire [3:0] c0_ddr4_s_axi_bid, output wire [1:0] c0_ddr4_s_axi_bresp, \
  output wire c0_ddr4_s_axi_bvalid, input wire [3:0] c0_ddr4_s_axi_arid, \
  input wire [32:0] c0_ddr4_s_axi_araddr, input wire [7:0] c0_ddr4_s_axi_arlen, \
  input wire [2:0] c0_ddr4_s_axi_arsize, input wire [1:0] c0_ddr4_s_axi_arburst, \
  input wire [0:0] c0_ddr4_s_axi_arlock, input wire [3:0] c0_ddr4_s_axi_arcache, \
  input wire [2:0] c0_ddr4_s_axi_arprot, input wire [3:0] c0_ddr4_s_axi_arqos, \
  input wire c0_ddr4_s_axi_arvalid, output wire c0_ddr4_s_axi_arready, \
  input wire c0_ddr4_s_axi_rready, output wire c0_ddr4_s_axi_rlast, \
  output wire c0_ddr4_s_axi_rvalid, output wire [1:0] c0_ddr4_s_axi_rresp, \
  output wire [3:0] c0_ddr4_s_axi_rid, output wire [511:0] c0_ddr4_s_axi_rdata, \
  input wire sys_rst

`define DDR4_STUB_BODY \
  logic [5:0] calib_count; \
  assign c0_ddr4_ui_clk = c0_sys_clk_p; \
  always_ff @(posedge c0_sys_clk_p) begin \
    if (sys_rst) begin \
      calib_count <= '0; c0_ddr4_ui_clk_sync_rst <= 1'b1; c0_init_calib_complete <= 1'b0; \
    end else if (!c0_init_calib_complete) begin \
      calib_count <= calib_count + 1'b1; \
      if (calib_count == 6'd12) c0_ddr4_ui_clk_sync_rst <= 1'b0; \
      if (calib_count == 6'd20) c0_init_calib_complete <= 1'b1; \
    end \
  end \
  assign dbg_clk = c0_sys_clk_p; assign dbg_bus = '0; \
  assign c0_ddr4_adr = '0; assign c0_ddr4_ba = '0; assign c0_ddr4_cke = '0; \
  assign c0_ddr4_cs_n = '1; assign c0_ddr4_odt = '0; assign c0_ddr4_bg = '0; \
  assign c0_ddr4_reset_n = !sys_rst; assign c0_ddr4_act_n = 1'b1; \
  assign c0_ddr4_ck_c = ~c0_sys_clk_p; assign c0_ddr4_ck_t = c0_sys_clk_p; \
  assign c0_ddr4_dm_dbi_n = 'z; assign c0_ddr4_dq = 'z; \
  assign c0_ddr4_dqs_c = 'z; assign c0_ddr4_dqs_t = 'z; \
  assign c0_ddr4_s_axi_ctrl_awready = 1'b0; assign c0_ddr4_s_axi_ctrl_wready = 1'b0; \
  assign c0_ddr4_s_axi_ctrl_bvalid = 1'b0; assign c0_ddr4_s_axi_ctrl_bresp = 2'b00; \
  assign c0_ddr4_s_axi_ctrl_arready = 1'b0; assign c0_ddr4_s_axi_ctrl_rvalid = 1'b0; \
  assign c0_ddr4_s_axi_ctrl_rdata = '0; assign c0_ddr4_s_axi_ctrl_rresp = 2'b00; \
  assign c0_ddr4_interrupt = 1'b0; \
  axi_ram_model_512 ram_i ( \
    .clk(c0_ddr4_ui_clk), .resetn(c0_ddr4_aresetn), \
    .s_axi_awid(c0_ddr4_s_axi_awid), .s_axi_awaddr(c0_ddr4_s_axi_awaddr), \
    .s_axi_awlen(c0_ddr4_s_axi_awlen), .s_axi_awsize(c0_ddr4_s_axi_awsize), \
    .s_axi_awburst(c0_ddr4_s_axi_awburst), .s_axi_awvalid(c0_ddr4_s_axi_awvalid), \
    .s_axi_awready(c0_ddr4_s_axi_awready), .s_axi_wdata(c0_ddr4_s_axi_wdata), \
    .s_axi_wstrb(c0_ddr4_s_axi_wstrb), .s_axi_wlast(c0_ddr4_s_axi_wlast), \
    .s_axi_wvalid(c0_ddr4_s_axi_wvalid), .s_axi_wready(c0_ddr4_s_axi_wready), \
    .s_axi_bid(c0_ddr4_s_axi_bid), .s_axi_bresp(c0_ddr4_s_axi_bresp), \
    .s_axi_bvalid(c0_ddr4_s_axi_bvalid), .s_axi_bready(c0_ddr4_s_axi_bready), \
    .s_axi_arid(c0_ddr4_s_axi_arid), .s_axi_araddr(c0_ddr4_s_axi_araddr), \
    .s_axi_arlen(c0_ddr4_s_axi_arlen), .s_axi_arsize(c0_ddr4_s_axi_arsize), \
    .s_axi_arburst(c0_ddr4_s_axi_arburst), .s_axi_arvalid(c0_ddr4_s_axi_arvalid), \
    .s_axi_arready(c0_ddr4_s_axi_arready), .s_axi_rid(c0_ddr4_s_axi_rid), \
    .s_axi_rdata(c0_ddr4_s_axi_rdata), .s_axi_rresp(c0_ddr4_s_axi_rresp), \
    .s_axi_rlast(c0_ddr4_s_axi_rlast), .s_axi_rvalid(c0_ddr4_s_axi_rvalid), \
    .s_axi_rready(c0_ddr4_s_axi_rready));

module ddr4_0 (`DDR4_STUB_PORTS);
  `DDR4_STUB_BODY
endmodule

module ddr4_1 (`DDR4_STUB_PORTS);
  `DDR4_STUB_BODY
endmodule

`undef DDR4_STUB_BODY
`undef DDR4_STUB_PORTS
