`timescale 1ns/1ps

module program_dma_subsystem (
  input  logic clk,
  input  logic resetn,

  input  logic [15:0] s_axis_tdata,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  output logic [31:0] frame_count,
  output logic [31:0] dma_write_addr,
  output logic        frame_done,
  output logic        dma_done,
  output logic        dma_error,
  output logic        frame_length_error,
  output logic [31:0] last_dma_status,
  output logic        dma_busy,
  output logic        datamover_error,
  output logic        first_write_pulse,

  axi4_if.master m_axi
);
  logic [15:0] payload_tdata;
  logic payload_tvalid, payload_tlast, payload_tready;
  logic [71:0] cmd_tdata;
  logic cmd_tvalid, cmd_tready;
  logic [31:0] sts_tdata;
  logic sts_tvalid, sts_tready;
  logic [3:0] sts_tkeep_unused;
  logic sts_tlast_unused;
  logic [3:0] awuser_unused;

  program_rx_dma_ctrl #(.DMA_BASE_ADDR(32'h8000_0000)) frame_ctrl_i (
    .clk, .resetn,
    .rx_fifo_tdata(s_axis_tdata), .rx_fifo_tvalid(s_axis_tvalid),
    .rx_fifo_tlast(s_axis_tlast), .rx_fifo_tready(s_axis_tready),
    .payload_tdata, .payload_tvalid, .payload_tlast, .payload_tready,
    .s_axis_s2mm_cmd_tdata(cmd_tdata),
    .s_axis_s2mm_cmd_tvalid(cmd_tvalid),
    .s_axis_s2mm_cmd_tready(cmd_tready),
    .m_axis_s2mm_sts_tdata(sts_tdata),
    .m_axis_s2mm_sts_tvalid(sts_tvalid),
    .m_axis_s2mm_sts_tready(sts_tready),
    .frame_count, .dma_write_addr, .frame_done, .dma_done, .dma_error,
    .frame_length_error, .last_dma_status, .dma_busy
  );

  assign m_axi.awlock   = 1'b0;
  assign m_axi.awregion = 4'b0;
  assign m_axi.awqos    = 4'b0;
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

  assign first_write_pulse = m_axi.awvalid && m_axi.awready;

  axi_datamover_0 datamover_i (
    .m_axi_s2mm_aclk(clk), .m_axi_s2mm_aresetn(resetn),
    .s2mm_err(datamover_error),
    .m_axis_s2mm_cmdsts_awclk(clk),
    .m_axis_s2mm_cmdsts_aresetn(resetn),
    .s_axis_s2mm_cmd_tvalid(cmd_tvalid),
    .s_axis_s2mm_cmd_tready(cmd_tready),
    .s_axis_s2mm_cmd_tdata(cmd_tdata),
    .m_axis_s2mm_sts_tvalid(sts_tvalid),
    .m_axis_s2mm_sts_tready(sts_tready),
    .m_axis_s2mm_sts_tdata(sts_tdata),
    .m_axis_s2mm_sts_tkeep(sts_tkeep_unused),
    .m_axis_s2mm_sts_tlast(sts_tlast_unused),
    .m_axi_s2mm_awid(m_axi.awid),
    .m_axi_s2mm_awaddr(m_axi.awaddr[31:0]),
    .m_axi_s2mm_awlen(m_axi.awlen),
    .m_axi_s2mm_awsize(m_axi.awsize),
    .m_axi_s2mm_awburst(m_axi.awburst),
    .m_axi_s2mm_awprot(m_axi.awprot),
    .m_axi_s2mm_awcache(m_axi.awcache),
    .m_axi_s2mm_awuser(awuser_unused),
    .m_axi_s2mm_awvalid(m_axi.awvalid),
    .m_axi_s2mm_awready(m_axi.awready),
    .m_axi_s2mm_wdata(m_axi.wdata),
    .m_axi_s2mm_wstrb(m_axi.wstrb),
    .m_axi_s2mm_wlast(m_axi.wlast),
    .m_axi_s2mm_wvalid(m_axi.wvalid),
    .m_axi_s2mm_wready(m_axi.wready),
    .m_axi_s2mm_bresp(m_axi.bresp),
    .m_axi_s2mm_bvalid(m_axi.bvalid),
    .m_axi_s2mm_bready(m_axi.bready),
    .s_axis_s2mm_tdata(payload_tdata),
    .s_axis_s2mm_tkeep(2'b11),
    .s_axis_s2mm_tlast(payload_tlast),
    .s_axis_s2mm_tvalid(payload_tvalid),
    .s_axis_s2mm_tready(payload_tready)
  );

  assign m_axi.awaddr[32] = 1'b0;
endmodule
