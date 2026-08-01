`timescale 1ns/1ps

// PRECONFIG data-DDR writer.  The underlying Xilinx AXI Traffic Generator is
// clocked by the 50 MHz processor clock and its MIF contains 256 consecutive
// all-ones word writes (1024 bytes).
module data_test_atg_wrapper (
  input  logic clk,
  input  logic hard_resetn,
  input  logic start,
  output logic done,
  output logic error,
  output logic [31:0] status,
  axi4_if.master m_axi
);
  logic atg_resetn;
  logic atg_done;
  logic [31:0] atg_status;
  logic [31:0] awaddr;
  logic [2:0] awprot;
  logic awvalid;
  logic [31:0] wdata;
  logic [3:0] wstrb;
  logic wvalid;
  logic bready;

  always_ff @(posedge clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      atg_resetn <= 1'b0;
      done       <= 1'b0;
      error      <= 1'b0;
      status     <= 32'b0;
    end else begin
      if (start)
        atg_resetn <= 1'b1;
      if (atg_done && !done) begin
        done   <= 1'b1;
        status <= atg_status;
        error  <= (atg_status[1:0] != 2'b01);
      end
    end
  end

  assign m_axi.awid     = 4'b0;
  assign m_axi.awaddr   = {1'b0,awaddr};
  assign m_axi.awlen    = 8'b0;
  assign m_axi.awsize   = 3'd2;
  assign m_axi.awburst  = 2'b01;
  assign m_axi.awlock   = 1'b0;
  assign m_axi.awcache  = 4'b0;
  assign m_axi.awprot   = awprot;
  assign m_axi.awregion = 4'b0;
  assign m_axi.awqos    = 4'b0;
  assign m_axi.awvalid  = awvalid;
  assign m_axi.wdata    = wdata;
  assign m_axi.wstrb    = wstrb;
  assign m_axi.wlast    = 1'b1;
  assign m_axi.wvalid   = wvalid;
  assign m_axi.bready   = bready;
  assign m_axi.arid     = 4'b0;
  assign m_axi.araddr   = 33'b0;
  assign m_axi.arlen    = 8'b0;
  assign m_axi.arsize   = 3'd2;
  assign m_axi.arburst  = 2'b01;
  assign m_axi.arlock   = 1'b0;
  assign m_axi.arcache  = 4'b0;
  assign m_axi.arprot   = 3'b0;
  assign m_axi.arregion = 4'b0;
  assign m_axi.arqos    = 4'b0;
  assign m_axi.arvalid  = 1'b0;
  assign m_axi.rready   = 1'b1;

  data_test_atg atg_i (
    .s_axi_aclk(clk), .s_axi_aresetn(atg_resetn),
    .m_axi_lite_ch1_awaddr(awaddr), .m_axi_lite_ch1_awprot(awprot),
    .m_axi_lite_ch1_awvalid(awvalid),
    .m_axi_lite_ch1_awready(m_axi.awready),
    .m_axi_lite_ch1_wdata(wdata), .m_axi_lite_ch1_wstrb(wstrb),
    .m_axi_lite_ch1_wvalid(wvalid), .m_axi_lite_ch1_wready(m_axi.wready),
    .m_axi_lite_ch1_bresp(m_axi.bresp),
    .m_axi_lite_ch1_bvalid(m_axi.bvalid),
    .m_axi_lite_ch1_bready(bready),
    .done(atg_done), .status(atg_status)
  );
endmodule

