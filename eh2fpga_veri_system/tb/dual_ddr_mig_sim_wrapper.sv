`timescale 1ns/1ps

// Presimulation replacement for the physical MIG wrapper.  It keeps the
// exact two 512-bit AXI UI ports used by the design, models calibration and
// UI clocks, and stores 1 MiB per DDR.  The instruction-memory line index
// intentionally ignores the high reset-vector address bits, matching the
// compact address-window model used by the validated EH2 RTL simulation.
module dual_ddr_mig_wrapper (
  input  logic hard_resetn,
  input  logic c0_sys_clk_p,
  input  logic c0_sys_clk_n,
  input  logic c1_sys_clk_p,
  input  logic c1_sys_clk_n,
  output logic c0_ui_clk,
  output logic c0_ui_resetn,
  output logic c0_calib_done,
  output logic c1_ui_clk,
  output logic c1_ui_resetn,
  output logic c1_calib_done,
  axi4_if.slave c0_axi,
  axi4_if.slave c1_axi,

  output logic        c0_ddr4_act_n,
  output logic [16:0] c0_ddr4_adr,
  output logic [1:0]  c0_ddr4_ba,
  output logic [1:0]  c0_ddr4_bg,
  output logic [0:0]  c0_ddr4_cke,
  output logic [0:0]  c0_ddr4_odt,
  output logic [0:0]  c0_ddr4_cs_n,
  output logic [0:0]  c0_ddr4_ck_t,
  output logic [0:0]  c0_ddr4_ck_c,
  output logic        c0_ddr4_reset_n,
  inout  wire [8:0]   c0_ddr4_dm_dbi_n,
  inout  wire [71:0]  c0_ddr4_dq,
  inout  wire [8:0]   c0_ddr4_dqs_c,
  inout  wire [8:0]   c0_ddr4_dqs_t,

  output logic        c1_ddr4_act_n,
  output logic [16:0] c1_ddr4_adr,
  output logic [1:0]  c1_ddr4_ba,
  output logic [1:0]  c1_ddr4_bg,
  output logic [0:0]  c1_ddr4_cke,
  output logic [0:0]  c1_ddr4_odt,
  output logic [0:0]  c1_ddr4_cs_n,
  output logic [0:0]  c1_ddr4_ck_t,
  output logic [0:0]  c1_ddr4_ck_c,
  output logic        c1_ddr4_reset_n,
  inout  wire [8:0]   c1_ddr4_dm_dbi_n,
  inout  wire [71:0]  c1_ddr4_dq,
  inout  wire [8:0]   c1_ddr4_dqs_c,
  inout  wire [8:0]   c1_ddr4_dqs_t
);
  logic protocol_error0, protocol_error1;
  logic [31:0] write_beat_count0, write_beat_count1;
  logic [31:0] read_beat_count0, read_beat_count1;
  integer calib_count;

  initial begin
    c0_ui_clk = 1'b0;
    c1_ui_clk = 1'b0;
  end
  always #1.876 c0_ui_clk = ~c0_ui_clk;
  always #1.876 c1_ui_clk = ~c1_ui_clk;

  always @(posedge c0_ui_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      calib_count   <= 0;
      c0_calib_done <= 1'b0;
      c1_calib_done <= 1'b0;
    end else if (calib_count == 239) begin
      c0_calib_done <= 1'b1;
      c1_calib_done <= 1'b1;
    end else begin
      calib_count <= calib_count + 1;
    end
  end

  always_comb begin
    c0_ui_resetn = hard_resetn && c0_calib_done;
    c1_ui_resetn = hard_resetn && c1_calib_done;

    c0_ddr4_act_n = 1'b1;
    c0_ddr4_adr = '0;
    c0_ddr4_ba = '0;
    c0_ddr4_bg = '0;
    c0_ddr4_cke = '0;
    c0_ddr4_odt = '0;
    c0_ddr4_cs_n = '1;
    c0_ddr4_ck_t = c0_ui_clk;
    c0_ddr4_ck_c = ~c0_ui_clk;
    c0_ddr4_reset_n = hard_resetn;

    c1_ddr4_act_n = 1'b1;
    c1_ddr4_adr = '0;
    c1_ddr4_ba = '0;
    c1_ddr4_bg = '0;
    c1_ddr4_cke = '0;
    c1_ddr4_odt = '0;
    c1_ddr4_cs_n = '1;
    c1_ddr4_ck_t = c1_ui_clk;
    c1_ddr4_ck_c = ~c1_ui_clk;
    c1_ddr4_reset_n = hard_resetn;
  end

  axi512_memory_model #(.LINE_COUNT(16384)) ddr0_memory_i (
    .clk(c0_ui_clk), .resetn(c0_ui_resetn),
    .awid(c0_axi.awid), .awaddr(c0_axi.awaddr), .awlen(c0_axi.awlen),
    .awsize(c0_axi.awsize), .awburst(c0_axi.awburst),
    .awvalid(c0_axi.awvalid), .awready(c0_axi.awready),
    .wdata(c0_axi.wdata), .wstrb(c0_axi.wstrb), .wlast(c0_axi.wlast),
    .wvalid(c0_axi.wvalid), .wready(c0_axi.wready),
    .bid(c0_axi.bid), .bresp(c0_axi.bresp), .bvalid(c0_axi.bvalid),
    .bready(c0_axi.bready),
    .arid(c0_axi.arid), .araddr(c0_axi.araddr), .arlen(c0_axi.arlen),
    .arsize(c0_axi.arsize), .arburst(c0_axi.arburst),
    .arvalid(c0_axi.arvalid), .arready(c0_axi.arready),
    .rid(c0_axi.rid), .rdata(c0_axi.rdata), .rresp(c0_axi.rresp),
    .rlast(c0_axi.rlast), .rvalid(c0_axi.rvalid),
    .rready(c0_axi.rready),
    .protocol_error(protocol_error0),
    .write_beat_count(write_beat_count0),
    .read_beat_count(read_beat_count0)
  );

  axi512_memory_model #(.LINE_COUNT(16384)) ddr1_memory_i (
    .clk(c1_ui_clk), .resetn(c1_ui_resetn),
    .awid(c1_axi.awid), .awaddr(c1_axi.awaddr), .awlen(c1_axi.awlen),
    .awsize(c1_axi.awsize), .awburst(c1_axi.awburst),
    .awvalid(c1_axi.awvalid), .awready(c1_axi.awready),
    .wdata(c1_axi.wdata), .wstrb(c1_axi.wstrb), .wlast(c1_axi.wlast),
    .wvalid(c1_axi.wvalid), .wready(c1_axi.wready),
    .bid(c1_axi.bid), .bresp(c1_axi.bresp), .bvalid(c1_axi.bvalid),
    .bready(c1_axi.bready),
    .arid(c1_axi.arid), .araddr(c1_axi.araddr), .arlen(c1_axi.arlen),
    .arsize(c1_axi.arsize), .arburst(c1_axi.arburst),
    .arvalid(c1_axi.arvalid), .arready(c1_axi.arready),
    .rid(c1_axi.rid), .rdata(c1_axi.rdata), .rresp(c1_axi.rresp),
    .rlast(c1_axi.rlast), .rvalid(c1_axi.rvalid),
    .rready(c1_axi.rready),
    .protocol_error(protocol_error1),
    .write_beat_count(write_beat_count1),
    .read_beat_count(read_beat_count1)
  );

  assign c0_ddr4_dm_dbi_n = 'z;
  assign c0_ddr4_dq       = 'z;
  assign c0_ddr4_dqs_c    = 'z;
  assign c0_ddr4_dqs_t    = 'z;
  assign c1_ddr4_dm_dbi_n = 'z;
  assign c1_ddr4_dq       = 'z;
  assign c1_ddr4_dqs_c    = 'z;
  assign c1_ddr4_dqs_t    = 'z;
endmodule
