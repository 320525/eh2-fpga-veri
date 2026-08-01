`timescale 1ps / 1ps

// Integrated receive path:
//   Tri-Mode Ethernet MAC -> 8-to-16 RX FIFO -> frame controller
//   -> AXI DataMover S2MM -> external 32-bit AXI memory destination.
//
// rx_fifo_clock is shared by the RX FIFO read side, frame controller,
// DataMover S2MM data interface, and DataMover command/status interface.
module mac_fifo_dma_top (
  // MAC clocks and resets.
  input  wire        gtx_clk,
  input  wire        glbl_rstn,
  input  wire        rx_axi_rstn,
  input  wire        tx_axi_rstn,
  input  wire        refclk,

  output wire        rx_mac_aclk,
  output wire        rx_reset,
  output wire [27:0] rx_statistics_vector,
  output wire        rx_statistics_valid,

  // Common 125 MHz receive/DMA clock domain.
  input  wire        rx_fifo_clock,
  input  wire        rx_fifo_resetn,
  output wire        rx_fifo_readable,
  output wire        rx_frame_accepted,
  output wire [3:0]  rx_fifo_status,
  output wire        rx_fifo_overflow,

  // MAC transmit-side status and controls.
  output wire        tx_mac_aclk,
  output wire        tx_reset,
  input  wire [7:0]  tx_ifg_delay,
  output wire [31:0] tx_statistics_vector,
  output wire        tx_statistics_valid,
  input  wire        pause_req,
  input  wire [15:0] pause_val,

  // External RGMII interface.
  output wire [3:0]  rgmii_txd,
  output wire        rgmii_tx_ctl,
  output wire        rgmii_txc,
  input  wire [3:0]  rgmii_rxd,
  input  wire        rgmii_rx_ctl,
  input  wire        rgmii_rxc,
  output wire        inband_link_status,
  output wire [1:0]  inband_clock_speed,
  output wire        inband_duplex_status,

  // PHY management.
  inout  wire        mdio,
  output wire        mdc,

  // MAC AXI4-Lite configuration interface.
  input  wire        s_axi_aclk,
  input  wire        s_axi_resetn,
  input  wire [11:0] s_axi_awaddr,
  input  wire        s_axi_awvalid,
  output wire        s_axi_awready,
  input  wire [31:0] s_axi_wdata,
  input  wire        s_axi_wvalid,
  output wire        s_axi_wready,
  output wire [1:0]  s_axi_bresp,
  output wire        s_axi_bvalid,
  input  wire        s_axi_bready,
  input  wire [11:0] s_axi_araddr,
  input  wire        s_axi_arvalid,
  output wire        s_axi_arready,
  output wire [31:0] s_axi_rdata,
  output wire [1:0]  s_axi_rresp,
  output wire        s_axi_rvalid,
  input  wire        s_axi_rready,
  output wire        mac_irq,

  // DataMover 32-bit AXI4 S2MM memory-mapped master interface.
  output wire [3:0]  m_axi_s2mm_awid,
  output wire [31:0] m_axi_s2mm_awaddr,
  output wire [7:0]  m_axi_s2mm_awlen,
  output wire [2:0]  m_axi_s2mm_awsize,
  output wire [1:0]  m_axi_s2mm_awburst,
  output wire [2:0]  m_axi_s2mm_awprot,
  output wire [3:0]  m_axi_s2mm_awcache,
  output wire [3:0]  m_axi_s2mm_awuser,
  output wire        m_axi_s2mm_awvalid,
  input  wire        m_axi_s2mm_awready,
  output wire [31:0] m_axi_s2mm_wdata,
  output wire [3:0]  m_axi_s2mm_wstrb,
  output wire        m_axi_s2mm_wlast,
  output wire        m_axi_s2mm_wvalid,
  input  wire        m_axi_s2mm_wready,
  input  wire [1:0]  m_axi_s2mm_bresp,
  input  wire        m_axi_s2mm_bvalid,
  output wire        m_axi_s2mm_bready,

  // Receive/DMA monitoring.
  output wire [31:0] frame_count,
  output wire [31:0] dma_write_addr,
  output wire        frame_done,
  output wire        dma_done,
  output wire        dma_error,
  output wire        frame_length_error,
  output wire [31:0] last_dma_status,
  output wire        dma_busy,
  output wire        s2mm_err
);

  wire [15:0] rx_fifo_tdata;
  wire        rx_fifo_tvalid;
  wire        rx_fifo_tlast;
  wire        rx_fifo_tready;

  assign rx_fifo_readable = rx_fifo_tvalid;

  wire [15:0] payload_tdata;
  wire        payload_tvalid;
  wire        payload_tlast;
  wire        payload_tready;

  wire [71:0] s2mm_cmd_tdata;
  wire        s2mm_cmd_tvalid;
  wire        s2mm_cmd_tready;
  wire [31:0] s2mm_sts_tdata;
  wire        s2mm_sts_tvalid;
  wire        s2mm_sts_tready;
  wire [3:0]  s2mm_sts_tkeep_unused;
  wire        s2mm_sts_tlast_unused;

  // The frame controller raises command valid only after the complete
  // Ethernet header has matched 02:12:34:56:78:FF.
  assign rx_frame_accepted = s2mm_cmd_tvalid;

  tri_mode_ethernet_mac_0_rx_fifo_block mac_rx_fifo_i (
    .gtx_clk(gtx_clk),
    .glbl_rstn(glbl_rstn),
    .rx_axi_rstn(rx_axi_rstn),
    .tx_axi_rstn(tx_axi_rstn),
    .refclk(refclk),
    .rx_mac_aclk(rx_mac_aclk),
    .rx_reset(rx_reset),
    .rx_statistics_vector(rx_statistics_vector),
    .rx_statistics_valid(rx_statistics_valid),
    .rx_fifo_clock(rx_fifo_clock),
    .rx_fifo_resetn(rx_fifo_resetn),
    .rx_axis_fifo_tdata(rx_fifo_tdata),
    .rx_axis_fifo_tvalid(rx_fifo_tvalid),
    .rx_axis_fifo_tready(rx_fifo_tready),
    .rx_axis_fifo_tlast(rx_fifo_tlast),
    .rx_fifo_status(rx_fifo_status),
    .rx_fifo_overflow(rx_fifo_overflow),
    .tx_mac_aclk(tx_mac_aclk),
    .tx_reset(tx_reset),
    .tx_ifg_delay(tx_ifg_delay),
    .tx_statistics_vector(tx_statistics_vector),
    .tx_statistics_valid(tx_statistics_valid),
    .pause_req(pause_req),
    .pause_val(pause_val),
    .rgmii_txd(rgmii_txd),
    .rgmii_tx_ctl(rgmii_tx_ctl),
    .rgmii_txc(rgmii_txc),
    .rgmii_rxd(rgmii_rxd),
    .rgmii_rx_ctl(rgmii_rx_ctl),
    .rgmii_rxc(rgmii_rxc),
    .inband_link_status(inband_link_status),
    .inband_clock_speed(inband_clock_speed),
    .inband_duplex_status(inband_duplex_status),
    .mdio(mdio),
    .mdc(mdc),
    .s_axi_aclk(s_axi_aclk),
    .s_axi_resetn(s_axi_resetn),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .mac_irq(mac_irq)
  );

  rx_fifo_frame_ctrl rx_fifo_frame_ctrl_i (
    .clk(rx_fifo_clock),
    .resetn(rx_fifo_resetn),
    .rx_fifo_tdata(rx_fifo_tdata),
    .rx_fifo_tvalid(rx_fifo_tvalid),
    .rx_fifo_tlast(rx_fifo_tlast),
    .rx_fifo_tready(rx_fifo_tready),
    .payload_tdata(payload_tdata),
    .payload_tvalid(payload_tvalid),
    .payload_tlast(payload_tlast),
    .payload_tready(payload_tready),
    .s_axis_s2mm_cmd_tdata(s2mm_cmd_tdata),
    .s_axis_s2mm_cmd_tvalid(s2mm_cmd_tvalid),
    .s_axis_s2mm_cmd_tready(s2mm_cmd_tready),
    .m_axis_s2mm_sts_tdata(s2mm_sts_tdata),
    .m_axis_s2mm_sts_tvalid(s2mm_sts_tvalid),
    .m_axis_s2mm_sts_tready(s2mm_sts_tready),
    .frame_count(frame_count),
    .dma_write_addr(dma_write_addr),
    .frame_done(frame_done),
    .dma_done(dma_done),
    .dma_error(dma_error),
    .frame_length_error(frame_length_error),
    .last_dma_status(last_dma_status),
    .dma_busy(dma_busy)
  );

  axi_datamover_0 axi_datamover_i (
    .m_axi_s2mm_aclk(rx_fifo_clock),
    .m_axi_s2mm_aresetn(rx_fifo_resetn),
    .s2mm_err(s2mm_err),
    .m_axis_s2mm_cmdsts_awclk(rx_fifo_clock),
    .m_axis_s2mm_cmdsts_aresetn(rx_fifo_resetn),
    .s_axis_s2mm_cmd_tvalid(s2mm_cmd_tvalid),
    .s_axis_s2mm_cmd_tready(s2mm_cmd_tready),
    .s_axis_s2mm_cmd_tdata(s2mm_cmd_tdata),
    .m_axis_s2mm_sts_tvalid(s2mm_sts_tvalid),
    .m_axis_s2mm_sts_tready(s2mm_sts_tready),
    .m_axis_s2mm_sts_tdata(s2mm_sts_tdata),
    .m_axis_s2mm_sts_tkeep(s2mm_sts_tkeep_unused),
    .m_axis_s2mm_sts_tlast(s2mm_sts_tlast_unused),
    .m_axi_s2mm_awid(m_axi_s2mm_awid),
    .m_axi_s2mm_awaddr(m_axi_s2mm_awaddr),
    .m_axi_s2mm_awlen(m_axi_s2mm_awlen),
    .m_axi_s2mm_awsize(m_axi_s2mm_awsize),
    .m_axi_s2mm_awburst(m_axi_s2mm_awburst),
    .m_axi_s2mm_awprot(m_axi_s2mm_awprot),
    .m_axi_s2mm_awcache(m_axi_s2mm_awcache),
    .m_axi_s2mm_awuser(m_axi_s2mm_awuser),
    .m_axi_s2mm_awvalid(m_axi_s2mm_awvalid),
    .m_axi_s2mm_awready(m_axi_s2mm_awready),
    .m_axi_s2mm_wdata(m_axi_s2mm_wdata),
    .m_axi_s2mm_wstrb(m_axi_s2mm_wstrb),
    .m_axi_s2mm_wlast(m_axi_s2mm_wlast),
    .m_axi_s2mm_wvalid(m_axi_s2mm_wvalid),
    .m_axi_s2mm_wready(m_axi_s2mm_wready),
    .m_axi_s2mm_bresp(m_axi_s2mm_bresp),
    .m_axi_s2mm_bvalid(m_axi_s2mm_bvalid),
    .m_axi_s2mm_bready(m_axi_s2mm_bready),
    .s_axis_s2mm_tdata(payload_tdata),
    .s_axis_s2mm_tkeep(2'b11),
    .s_axis_s2mm_tlast(payload_tlast),
    .s_axis_s2mm_tvalid(payload_tvalid),
    .s_axis_s2mm_tready(payload_tready)
  );

endmodule
