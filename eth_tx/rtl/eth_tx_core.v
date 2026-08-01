`timescale 1ns / 1ps

// Ethernet transmit core.  TEMAC configuration and DP83867 initialization
// are kept equivalent to mac_fifo_dma_proj.  After both complete, a second
// System-Init ATG programs an 8-bit Streaming ATG for ten 64-byte transfers.
module eth_tx_core #(
  parameter integer PHY_INIT_BYPASS = 0,
  parameter [15:0]  TX_ETHERTYPE    = 16'h88B5
) (
  input  wire        gtx_clk,
  input  wire        refclk,
  input  wire        s_axi_aclk,
  input  wire        system_resetn,

  output wire [3:0]  rgmii_txd,
  output wire        rgmii_tx_ctl,
  output wire        rgmii_txc,
  input  wire [3:0]  rgmii_rxd,
  input  wire        rgmii_rx_ctl,
  input  wire        rgmii_rxc,
  inout  wire        mdio,
  output wire        mdc,
  output wire        phy_resetn,

  output wire        mac_config_done,
  output wire        mac_config_error,
  output wire        phy_init_busy,
  output wire        phy_init_done,
  output wire        phy_init_success,
  output wire [3:0]  phy_init_error,
  output wire [4:0]  phy_addr,
  output wire [15:0] phy_id1,
  output wire [15:0] phy_id2,
  output wire        phy_link_up,
  output wire        phy_autoneg_complete,

  output wire        tx_control_done,
  output wire [31:0] tx_control_status,
  output wire        tx_atg_error,
  output wire [3:0]  tx_fifo_status,
  output wire        tx_fifo_overflow,
  output wire [3:0]  tx_fifo_frame_count,
  output wire [3:0]  tx_mac_frame_count,
  output wire        tx_length_error,
  output wire        inband_link_status,
  output wire [1:0]  inband_clock_speed,
  output wire        inband_duplex_status,
  output wire        mac_irq
);

  // ------------------------------------------------------------------------
  // Original TEMAC System-Init ATG and DP83867 AXI-Lite arbitration.
  // ------------------------------------------------------------------------
  wire [31:0] mac_atg_awaddr;
  wire [2:0]  mac_atg_awprot_unused;
  wire        mac_atg_awvalid;
  wire        mac_atg_awready;
  wire [31:0] mac_atg_wdata;
  wire [3:0]  mac_atg_wstrb_unused;
  wire        mac_atg_wvalid;
  wire        mac_atg_wready;
  wire [1:0]  mac_atg_bresp;
  wire        mac_atg_bvalid;
  wire        mac_atg_bready;
  wire        mac_atg_done;
  wire [31:0] mac_atg_status;

  reg mac_config_done_reg;
  reg mac_config_error_reg;
  assign mac_config_done  = mac_config_done_reg;
  assign mac_config_error = mac_config_error_reg;

  always @(posedge s_axi_aclk or negedge system_resetn) begin
    if (!system_resetn) begin
      mac_config_done_reg  <= 1'b0;
      mac_config_error_reg <= 1'b0;
    end
    else if (!mac_config_done_reg && mac_atg_done) begin
      mac_config_done_reg  <= 1'b1;
      mac_config_error_reg <= (mac_atg_status[1:0] != 2'b01);
    end
  end

  wire        phy_resetn_int;
  wire        phy_init_busy_int;
  wire        phy_init_done_int;
  wire        phy_init_success_int;
  wire [3:0]  phy_init_error_int;
  wire [4:0]  phy_addr_int;
  wire [15:0] phy_id1_int;
  wire [15:0] phy_id2_int;
  wire        phy_link_up_int;
  wire        phy_autoneg_complete_int;

  wire [11:0] phy_axi_awaddr;
  wire        phy_axi_awvalid;
  wire        phy_axi_awready;
  wire [31:0] phy_axi_wdata;
  wire        phy_axi_wvalid;
  wire        phy_axi_wready;
  wire [1:0]  phy_axi_bresp;
  wire        phy_axi_bvalid;
  wire        phy_axi_bready;
  wire [11:0] phy_axi_araddr;
  wire        phy_axi_arvalid;
  wire        phy_axi_arready;
  wire [31:0] phy_axi_rdata;
  wire [1:0]  phy_axi_rresp;
  wire        phy_axi_rvalid;
  wire        phy_axi_rready;

  wire mac_atg_active = !mac_config_done_reg;
  wire phy_axi_active = (PHY_INIT_BYPASS == 0) &&
                        mac_config_done_reg && !mac_config_error_reg &&
                        !phy_init_done_int;

  wire [11:0] mac_axi_awaddr = mac_atg_active ? mac_atg_awaddr[11:0] :
                                 phy_axi_active ? phy_axi_awaddr : 12'd0;
  wire        mac_axi_awvalid = mac_atg_active ? mac_atg_awvalid :
                                  phy_axi_active ? phy_axi_awvalid : 1'b0;
  wire        mac_axi_awready;
  wire [31:0] mac_axi_wdata = mac_atg_active ? mac_atg_wdata :
                                phy_axi_active ? phy_axi_wdata : 32'd0;
  wire        mac_axi_wvalid = mac_atg_active ? mac_atg_wvalid :
                                 phy_axi_active ? phy_axi_wvalid : 1'b0;
  wire        mac_axi_wready;
  wire [1:0]  mac_axi_bresp;
  wire        mac_axi_bvalid;
  wire        mac_axi_bready = mac_atg_active ? mac_atg_bready :
                                 phy_axi_active ? phy_axi_bready : 1'b1;
  wire [11:0] mac_axi_araddr = phy_axi_active ? phy_axi_araddr : 12'd0;
  wire        mac_axi_arvalid = phy_axi_active ? phy_axi_arvalid : 1'b0;
  wire        mac_axi_arready;
  wire [31:0] mac_axi_rdata;
  wire [1:0]  mac_axi_rresp;
  wire        mac_axi_rvalid;
  wire        mac_axi_rready = phy_axi_active ? phy_axi_rready : 1'b1;

  assign mac_atg_awready = mac_atg_active ? mac_axi_awready : 1'b0;
  assign mac_atg_wready  = mac_atg_active ? mac_axi_wready : 1'b0;
  assign mac_atg_bresp   = mac_axi_bresp;
  assign mac_atg_bvalid  = mac_atg_active ? mac_axi_bvalid : 1'b0;

  assign phy_axi_awready = phy_axi_active ? mac_axi_awready : 1'b0;
  assign phy_axi_wready  = phy_axi_active ? mac_axi_wready : 1'b0;
  assign phy_axi_bresp   = mac_axi_bresp;
  assign phy_axi_bvalid  = phy_axi_active ? mac_axi_bvalid : 1'b0;
  assign phy_axi_arready = phy_axi_active ? mac_axi_arready : 1'b0;
  assign phy_axi_rdata   = mac_axi_rdata;
  assign phy_axi_rresp   = mac_axi_rresp;
  assign phy_axi_rvalid  = phy_axi_active ? mac_axi_rvalid : 1'b0;

  axi_traffic_gen_0 mac_config_atg_i (
    .s_axi_aclk               (s_axi_aclk),
    .s_axi_aresetn            (system_resetn),
    .m_axi_lite_ch1_awaddr    (mac_atg_awaddr),
    .m_axi_lite_ch1_awprot    (mac_atg_awprot_unused),
    .m_axi_lite_ch1_awvalid   (mac_atg_awvalid),
    .m_axi_lite_ch1_awready   (mac_atg_awready),
    .m_axi_lite_ch1_wdata     (mac_atg_wdata),
    .m_axi_lite_ch1_wstrb     (mac_atg_wstrb_unused),
    .m_axi_lite_ch1_wvalid    (mac_atg_wvalid),
    .m_axi_lite_ch1_wready    (mac_atg_wready),
    .m_axi_lite_ch1_bresp     (mac_atg_bresp),
    .m_axi_lite_ch1_bvalid    (mac_atg_bvalid),
    .m_axi_lite_ch1_bready    (mac_atg_bready),
    .done                     (mac_atg_done),
    .status                   (mac_atg_status)
  );

  generate
    if (PHY_INIT_BYPASS == 0) begin : gen_dp83867_init
      dp83867_phy_init phy_init_i (
        .clk                    (s_axi_aclk),
        .resetn                 (system_resetn),
        .start                  (mac_config_done_reg &&
                                 !mac_config_error_reg),
        .phy_resetn             (phy_resetn_int),
        .init_busy              (phy_init_busy_int),
        .init_done              (phy_init_done_int),
        .init_success           (phy_init_success_int),
        .init_error             (phy_init_error_int),
        .detected_phy_addr      (phy_addr_int),
        .phy_id1                (phy_id1_int),
        .phy_id2                (phy_id2_int),
        .phy_link_up            (phy_link_up_int),
        .phy_autoneg_complete   (phy_autoneg_complete_int),
        .m_axi_awaddr           (phy_axi_awaddr),
        .m_axi_awvalid          (phy_axi_awvalid),
        .m_axi_awready          (phy_axi_awready),
        .m_axi_wdata            (phy_axi_wdata),
        .m_axi_wvalid           (phy_axi_wvalid),
        .m_axi_wready           (phy_axi_wready),
        .m_axi_bresp            (phy_axi_bresp),
        .m_axi_bvalid           (phy_axi_bvalid),
        .m_axi_bready           (phy_axi_bready),
        .m_axi_araddr           (phy_axi_araddr),
        .m_axi_arvalid          (phy_axi_arvalid),
        .m_axi_arready          (phy_axi_arready),
        .m_axi_rdata            (phy_axi_rdata),
        .m_axi_rresp            (phy_axi_rresp),
        .m_axi_rvalid           (phy_axi_rvalid),
        .m_axi_rready           (phy_axi_rready)
      );
    end
    else begin : gen_phy_bypass
      assign phy_resetn_int           = system_resetn;
      assign phy_init_busy_int        = 1'b0;
      assign phy_init_done_int        = mac_config_done_reg;
      assign phy_init_success_int     = mac_config_done_reg &&
                                        !mac_config_error_reg;
      assign phy_init_error_int       = mac_config_error_reg ? 4'h1 : 4'h0;
      assign phy_addr_int             = 5'd0;
      assign phy_id1_int              = 16'h2000;
      assign phy_id2_int              = 16'hA230;
      assign phy_link_up_int          = 1'b1;
      assign phy_autoneg_complete_int = 1'b1;
      assign phy_axi_awaddr           = 12'd0;
      assign phy_axi_awvalid          = 1'b0;
      assign phy_axi_wdata            = 32'd0;
      assign phy_axi_wvalid           = 1'b0;
      assign phy_axi_bready           = 1'b0;
      assign phy_axi_araddr           = 12'd0;
      assign phy_axi_arvalid          = 1'b0;
      assign phy_axi_rready           = 1'b0;
    end
  endgenerate

  assign phy_resetn           = phy_resetn_int;
  assign phy_init_busy        = phy_init_busy_int;
  assign phy_init_done        = phy_init_done_int;
  assign phy_init_success     = phy_init_success_int;
  assign phy_init_error       = phy_init_error_int;
  assign phy_addr             = phy_addr_int;
  assign phy_id1              = phy_id1_int;
  assign phy_id2              = phy_id2_int;
  assign phy_link_up          = phy_link_up_int;
  assign phy_autoneg_complete = phy_autoneg_complete_int;

  // ------------------------------------------------------------------------
  // Streaming ATG control.  In hardware, PHY initialization does not report
  // success until link and auto-negotiation have remained complete across
  // the stabilization interval.  This keeps the one-shot ten-frame burst
  // from being consumed while the DP83867 is still renegotiating.
  // ------------------------------------------------------------------------
  wire tx_path_resetn = system_resetn && mac_config_done_reg &&
                        !mac_config_error_reg && phy_init_success_int;

  wire [31:0] tx_ctl_awaddr;
  wire [2:0]  tx_ctl_awprot;
  wire        tx_ctl_awvalid;
  wire        tx_ctl_awready;
  wire [31:0] tx_ctl_wdata;
  wire [3:0]  tx_ctl_wstrb;
  wire        tx_ctl_wvalid;
  wire        tx_ctl_wready;
  wire [1:0]  tx_ctl_bresp;
  wire        tx_ctl_bvalid;
  wire        tx_ctl_bready;
  wire        tx_ctl_done;
  wire [31:0] tx_ctl_status;

  assign tx_control_done   = tx_ctl_done;
  assign tx_control_status = tx_ctl_status;

  tx_control_atg tx_control_atg_i (
    .s_axi_aclk               (s_axi_aclk),
    .s_axi_aresetn            (tx_path_resetn),
    .m_axi_lite_ch1_awaddr    (tx_ctl_awaddr),
    .m_axi_lite_ch1_awprot    (tx_ctl_awprot),
    .m_axi_lite_ch1_awvalid   (tx_ctl_awvalid),
    .m_axi_lite_ch1_awready   (tx_ctl_awready),
    .m_axi_lite_ch1_wdata     (tx_ctl_wdata),
    .m_axi_lite_ch1_wstrb     (tx_ctl_wstrb),
    .m_axi_lite_ch1_wvalid    (tx_ctl_wvalid),
    .m_axi_lite_ch1_wready    (tx_ctl_wready),
    .m_axi_lite_ch1_bresp     (tx_ctl_bresp),
    .m_axi_lite_ch1_bvalid    (tx_ctl_bvalid),
    .m_axi_lite_ch1_bready    (tx_ctl_bready),
    .done                     (tx_ctl_done),
    .status                   (tx_ctl_status)
  );

  wire [0:0] tx_stream_bid_unused;
  wire [0:0] tx_stream_rid_unused;
  wire       tx_stream_rlast_unused;
  wire [31:0] tx_stream_rdata_unused;
  wire [1:0] tx_stream_rresp_unused;
  wire       tx_stream_rvalid_unused;
  wire [7:0] atg_axis_tdata;
  wire       atg_axis_tvalid;
  wire       atg_axis_tlast;
  wire       atg_axis_tready;
  wire [0:0] atg_axis_tuser_unused;
  wire [0:0] atg_axis_tid_unused;
  wire [0:0] atg_axis_tdest_unused;

  tx_axi_traffic_gen tx_axi_traffic_gen_i (
    .s_axi_aclk      (s_axi_aclk),
    .s_axi_aresetn   (tx_path_resetn),
    .core_ext_start  (1'b0),
    .core_ext_stop   (1'b0),
    .s_axi_awid      (1'b0),
    .s_axi_awaddr    (tx_ctl_awaddr),
    .s_axi_awlen     (8'd0),
    .s_axi_awsize    (3'b010),
    .s_axi_awburst   (2'b01),
    .s_axi_awlock    (1'b0),
    .s_axi_awcache   (4'd0),
    .s_axi_awprot    (tx_ctl_awprot),
    .s_axi_awqos     (4'd0),
    .s_axi_awuser    (8'd0),
    .s_axi_awvalid   (tx_ctl_awvalid),
    .s_axi_awready   (tx_ctl_awready),
    .s_axi_wlast     (1'b1),
    .s_axi_wdata     (tx_ctl_wdata),
    .s_axi_wstrb     (tx_ctl_wstrb),
    .s_axi_wvalid    (tx_ctl_wvalid),
    .s_axi_wready    (tx_ctl_wready),
    .s_axi_bid       (tx_stream_bid_unused),
    .s_axi_bresp     (tx_ctl_bresp),
    .s_axi_bvalid    (tx_ctl_bvalid),
    .s_axi_bready    (tx_ctl_bready),
    .s_axi_arid      (1'b0),
    .s_axi_araddr    (32'd0),
    .s_axi_arlen     (8'd0),
    .s_axi_arsize    (3'b010),
    .s_axi_arburst   (2'b01),
    .s_axi_arlock    (1'b0),
    .s_axi_arcache   (4'd0),
    .s_axi_arprot    (3'd0),
    .s_axi_arqos     (4'd0),
    .s_axi_aruser    (8'd0),
    .s_axi_arvalid   (1'b0),
    .s_axi_arready   (),
    .s_axi_rid       (tx_stream_rid_unused),
    .s_axi_rlast     (tx_stream_rlast_unused),
    .s_axi_rdata     (tx_stream_rdata_unused),
    .s_axi_rresp     (tx_stream_rresp_unused),
    .s_axi_rvalid    (tx_stream_rvalid_unused),
    .s_axi_rready    (1'b1),
    .m_axis_1_tready (atg_axis_tready),
    .m_axis_1_tvalid (atg_axis_tvalid),
    .m_axis_1_tlast  (atg_axis_tlast),
    .m_axis_1_tdata  (atg_axis_tdata),
    .m_axis_1_tuser  (atg_axis_tuser_unused),
    .m_axis_1_tid    (atg_axis_tid_unused),
    .m_axis_1_tdest  (atg_axis_tdest_unused),
    .err_out         (tx_atg_error)
  );

  wire [7:0] tx_fifo_tdata;
  wire       tx_fifo_tvalid;
  wire       tx_fifo_tlast;
  wire       tx_fifo_tready;

  eth_tx_frame_formatter #(
    .ETHERTYPE      (TX_ETHERTYPE)
  ) frame_formatter_i (
    .clk            (s_axi_aclk),
    .resetn         (tx_path_resetn),
    .s_axis_tdata   (atg_axis_tdata),
    .s_axis_tvalid  (atg_axis_tvalid),
    .s_axis_tlast   (atg_axis_tlast),
    .s_axis_tready  (atg_axis_tready),
    .m_axis_tdata   (tx_fifo_tdata),
    .m_axis_tvalid  (tx_fifo_tvalid),
    .m_axis_tlast   (tx_fifo_tlast),
    .m_axis_tready  (tx_fifo_tready),
    .frame_count    (tx_fifo_frame_count),
    .length_error   (tx_length_error)
  );

  // ------------------------------------------------------------------------
  // TEMAC and dual-clock client FIFOs.
  // ------------------------------------------------------------------------
  wire        rx_mac_aclk;
  wire        rx_reset;
  wire [27:0] rx_statistics_vector_unused;
  wire        rx_statistics_valid_unused;
  wire [15:0] rx_fifo_tdata_unused;
  wire        rx_fifo_tvalid_unused;
  wire        rx_fifo_tlast_unused;
  wire [3:0]  rx_fifo_status_unused;
  wire        rx_fifo_overflow_unused;
  wire        tx_mac_aclk;
  wire        tx_reset;
  wire [31:0] tx_statistics_vector;
  wire        tx_statistics_valid;

  eth_tx_mac_fifo_block mac_fifo_i (
    .gtx_clk               (gtx_clk),
    .glbl_rstn             (system_resetn),
    .rx_axi_rstn           (system_resetn),
    .tx_axi_rstn           (system_resetn),
    .refclk                (refclk),
    .rx_mac_aclk           (rx_mac_aclk),
    .rx_reset              (rx_reset),
    .rx_statistics_vector  (rx_statistics_vector_unused),
    .rx_statistics_valid   (rx_statistics_valid_unused),
    .rx_fifo_clock         (rx_mac_aclk),
    .rx_fifo_resetn        (system_resetn),
    .rx_axis_fifo_tdata    (rx_fifo_tdata_unused),
    .rx_axis_fifo_tvalid   (rx_fifo_tvalid_unused),
    .rx_axis_fifo_tready   (1'b1),
    .rx_axis_fifo_tlast    (rx_fifo_tlast_unused),
    .rx_fifo_status        (rx_fifo_status_unused),
    .rx_fifo_overflow      (rx_fifo_overflow_unused),
    .tx_mac_aclk           (tx_mac_aclk),
    .tx_reset              (tx_reset),
    .tx_ifg_delay          (8'h00),
    .tx_statistics_vector  (tx_statistics_vector),
    .tx_statistics_valid   (tx_statistics_valid),
    .tx_fifo_clock         (s_axi_aclk),
    .tx_fifo_resetn        (tx_path_resetn),
    .tx_axis_fifo_tdata    (tx_fifo_tdata),
    .tx_axis_fifo_tvalid   (tx_fifo_tvalid),
    .tx_axis_fifo_tready   (tx_fifo_tready),
    .tx_axis_fifo_tlast    (tx_fifo_tlast),
    .tx_fifo_status        (tx_fifo_status),
    .tx_fifo_overflow      (tx_fifo_overflow),
    .pause_req             (1'b0),
    .pause_val             (16'h0000),
    .rgmii_txd             (rgmii_txd),
    .rgmii_tx_ctl          (rgmii_tx_ctl),
    .rgmii_txc             (rgmii_txc),
    .rgmii_rxd             (rgmii_rxd),
    .rgmii_rx_ctl          (rgmii_rx_ctl),
    .rgmii_rxc             (rgmii_rxc),
    .inband_link_status    (inband_link_status),
    .inband_clock_speed    (inband_clock_speed),
    .inband_duplex_status  (inband_duplex_status),
    .mdio                  (mdio),
    .mdc                   (mdc),
    .s_axi_aclk            (s_axi_aclk),
    .s_axi_resetn          (system_resetn),
    .s_axi_awaddr          (mac_axi_awaddr),
    .s_axi_awvalid         (mac_axi_awvalid),
    .s_axi_awready         (mac_axi_awready),
    .s_axi_wdata           (mac_axi_wdata),
    .s_axi_wvalid          (mac_axi_wvalid),
    .s_axi_wready          (mac_axi_wready),
    .s_axi_bresp           (mac_axi_bresp),
    .s_axi_bvalid          (mac_axi_bvalid),
    .s_axi_bready          (mac_axi_bready),
    .s_axi_araddr          (mac_axi_araddr),
    .s_axi_arvalid         (mac_axi_arvalid),
    .s_axi_arready         (mac_axi_arready),
    .s_axi_rdata           (mac_axi_rdata),
    .s_axi_rresp           (mac_axi_rresp),
    .s_axi_rvalid          (mac_axi_rvalid),
    .s_axi_rready          (mac_axi_rready),
    .mac_irq               (mac_irq)
  );

  reg [3:0] tx_mac_frame_count_reg;
  always @(posedge tx_mac_aclk) begin
    if (tx_reset)
      tx_mac_frame_count_reg <= 4'd0;
    else if (tx_statistics_valid)
      tx_mac_frame_count_reg <= tx_mac_frame_count_reg + 1'b1;
  end
  assign tx_mac_frame_count = tx_mac_frame_count_reg;

endmodule
