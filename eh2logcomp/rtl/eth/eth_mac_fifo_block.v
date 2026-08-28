`timescale 1ps / 1ps

// TEMAC wrapper derived from mac_fifo_dma_proj's receive wrapper.  The RX
// path is unchanged (8-bit MAC side to 16-bit user side); the TX path is the
// full-duplex client FIFO from the TEMAC example design.
(* DowngradeIPIdentifiedWarnings = "yes" *)
module eth_mac_fifo_block (
  input  wire        gtx_clk,
  input  wire        glbl_rstn,
  input  wire        rx_axi_rstn,
  input  wire        tx_axi_rstn,
  input  wire        refclk,

  output wire        rx_mac_aclk,
  output wire        rx_reset,
  output wire [27:0] rx_statistics_vector,
  output wire        rx_statistics_valid,

  input  wire        rx_fifo_clock,
  input  wire        rx_fifo_resetn,
  output wire [15:0] rx_axis_fifo_tdata,
  output wire        rx_axis_fifo_tvalid,
  input  wire        rx_axis_fifo_tready,
  output wire        rx_axis_fifo_tlast,
  output wire [3:0]  rx_fifo_status,
  output wire        rx_fifo_overflow,

  output wire        tx_mac_aclk,
  output wire        tx_reset,
  input  wire [7:0]  tx_ifg_delay,
  output wire [31:0] tx_statistics_vector,
  output wire        tx_statistics_valid,

  input  wire        tx_fifo_clock,
  input  wire        tx_fifo_resetn,
  input  wire [7:0]  tx_axis_fifo_tdata,
  input  wire        tx_axis_fifo_tvalid,
  output wire        tx_axis_fifo_tready,
  input  wire        tx_axis_fifo_tlast,
  output wire [3:0]  tx_fifo_status,
  output wire        tx_fifo_overflow,

  input  wire        pause_req,
  input  wire [15:0] pause_val,

  output wire [3:0]  rgmii_txd,
  output wire        rgmii_tx_ctl,
  output wire        rgmii_txc,
  input  wire [3:0]  rgmii_rxd,
  input  wire        rgmii_rx_ctl,
  input  wire        rgmii_rxc,
  output wire        inband_link_status,
  output wire [1:0]  inband_clock_speed,
  output wire        inband_duplex_status,

  inout  wire        mdio,
  output wire        mdc,

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
  output wire        mac_irq
);

  wire       rx_mac_aclk_int;
  wire       tx_mac_aclk_int;
  wire       rx_reset_int;
  wire       tx_reset_int;
  wire       rx_mac_reset;
  wire       tx_mac_reset;
  wire       rx_mac_resetn;
  wire       tx_mac_resetn;

  wire [7:0] rx_axis_mac_tdata;
  wire       rx_axis_mac_tvalid;
  wire       rx_axis_mac_tlast;
  wire       rx_axis_mac_tuser;

  wire [7:0] tx_axis_mac_tdata;
  wire       tx_axis_mac_tvalid;
  wire       tx_axis_mac_tready;
  wire       tx_axis_mac_tlast;
  wire       tx_axis_mac_tuser;

  assign rx_mac_aclk = rx_mac_aclk_int;
  assign tx_mac_aclk = tx_mac_aclk_int;
  assign rx_reset    = rx_reset_int;
  assign tx_reset    = tx_reset_int;

  tri_mode_ethernet_mac_0 tri_mode_ethernet_mac_i (
    .gtx_clk              (gtx_clk),
    .refclk               (refclk),
    .glbl_rstn            (glbl_rstn),
    .rx_axi_rstn          (rx_axi_rstn),
    .tx_axi_rstn          (tx_axi_rstn),

    .rx_statistics_vector (rx_statistics_vector),
    .rx_statistics_valid  (rx_statistics_valid),
    .rx_mac_aclk          (rx_mac_aclk_int),
    .rx_reset             (rx_reset_int),
    .rx_axis_mac_tdata    (rx_axis_mac_tdata),
    .rx_axis_mac_tvalid   (rx_axis_mac_tvalid),
    .rx_axis_mac_tlast    (rx_axis_mac_tlast),
    .rx_axis_mac_tuser    (rx_axis_mac_tuser),

    .tx_ifg_delay         (tx_ifg_delay),
    .tx_statistics_vector (tx_statistics_vector),
    .tx_statistics_valid  (tx_statistics_valid),
    .tx_mac_aclk          (tx_mac_aclk_int),
    .tx_reset             (tx_reset_int),
    .tx_axis_mac_tdata    (tx_axis_mac_tdata),
    .tx_axis_mac_tvalid   (tx_axis_mac_tvalid),
    .tx_axis_mac_tlast    (tx_axis_mac_tlast),
    .tx_axis_mac_tuser    (tx_axis_mac_tuser),
    .tx_axis_mac_tready   (tx_axis_mac_tready),

    .pause_req            (pause_req),
    .pause_val            (pause_val),
    .speedis100           (),
    .speedis10100         (),

    .rgmii_txd            (rgmii_txd),
    .rgmii_tx_ctl         (rgmii_tx_ctl),
    .rgmii_txc            (rgmii_txc),
    .rgmii_rxd            (rgmii_rxd),
    .rgmii_rx_ctl         (rgmii_rx_ctl),
    .rgmii_rxc            (rgmii_rxc),
    .inband_link_status   (inband_link_status),
    .inband_clock_speed   (inband_clock_speed),
    .inband_duplex_status (inband_duplex_status),

    .mdio                 (mdio),
    .mdc                  (mdc),

    .s_axi_aclk           (s_axi_aclk),
    .s_axi_resetn         (s_axi_resetn),
    .s_axi_awaddr         (s_axi_awaddr),
    .s_axi_awvalid        (s_axi_awvalid),
    .s_axi_awready        (s_axi_awready),
    .s_axi_wdata          (s_axi_wdata),
    .s_axi_wvalid         (s_axi_wvalid),
    .s_axi_wready         (s_axi_wready),
    .s_axi_bresp          (s_axi_bresp),
    .s_axi_bvalid         (s_axi_bvalid),
    .s_axi_bready         (s_axi_bready),
    .s_axi_araddr         (s_axi_araddr),
    .s_axi_arvalid        (s_axi_arvalid),
    .s_axi_arready        (s_axi_arready),
    .s_axi_rdata          (s_axi_rdata),
    .s_axi_rresp          (s_axi_rresp),
    .s_axi_rvalid         (s_axi_rvalid),
    .s_axi_rready         (s_axi_rready),
    .mac_irq              (mac_irq)
  );

  tri_mode_ethernet_mac_0_reset_sync rx_mac_reset_gen (
    .clk       (rx_mac_aclk_int),
    .enable    (1'b1),
    .reset_in  (rx_reset_int),
    .reset_out (rx_mac_reset)
  );

  tri_mode_ethernet_mac_0_reset_sync tx_mac_reset_gen (
    .clk       (tx_mac_aclk_int),
    .enable    (1'b1),
    .reset_in  (tx_reset_int),
    .reset_out (tx_mac_reset)
  );

  assign rx_mac_resetn = ~rx_mac_reset;
  assign tx_mac_resetn = ~tx_mac_reset;

  tri_mode_ethernet_mac_0_rx_client_fifo_8to16 rx_client_fifo_i (
    .rx_fifo_aclk        (rx_fifo_clock),
    .rx_fifo_resetn      (rx_fifo_resetn),
    .rx_axis_fifo_tdata  (rx_axis_fifo_tdata),
    .rx_axis_fifo_tvalid (rx_axis_fifo_tvalid),
    .rx_axis_fifo_tlast  (rx_axis_fifo_tlast),
    .rx_axis_fifo_tready (rx_axis_fifo_tready),
    .rx_mac_aclk         (rx_mac_aclk_int),
    .rx_mac_resetn       (rx_mac_resetn),
    .rx_axis_mac_tdata   (rx_axis_mac_tdata),
    .rx_axis_mac_tvalid  (rx_axis_mac_tvalid),
    .rx_axis_mac_tlast   (rx_axis_mac_tlast),
    .rx_axis_mac_tuser   (rx_axis_mac_tuser),
    .fifo_status         (rx_fifo_status),
    .fifo_overflow       (rx_fifo_overflow)
  );

  tri_mode_ethernet_mac_0_tx_client_fifo #(
    .FULL_DUPLEX_ONLY (1)
  ) tx_client_fifo_i (
    .tx_fifo_aclk        (tx_fifo_clock),
    .tx_fifo_resetn      (tx_fifo_resetn),
    .tx_axis_fifo_tdata  (tx_axis_fifo_tdata),
    .tx_axis_fifo_tvalid (tx_axis_fifo_tvalid),
    .tx_axis_fifo_tlast  (tx_axis_fifo_tlast),
    .tx_axis_fifo_tready (tx_axis_fifo_tready),
    .tx_mac_aclk         (tx_mac_aclk_int),
    .tx_mac_resetn       (tx_mac_resetn),
    .tx_axis_mac_tdata   (tx_axis_mac_tdata),
    .tx_axis_mac_tvalid  (tx_axis_mac_tvalid),
    .tx_axis_mac_tlast   (tx_axis_mac_tlast),
    .tx_axis_mac_tready  (tx_axis_mac_tready),
    .tx_axis_mac_tuser   (tx_axis_mac_tuser),
    .fifo_overflow       (tx_fifo_overflow),
    .fifo_status         (tx_fifo_status),
    .tx_collision        (1'b0),
    .tx_retransmit       (1'b0)
  );

endmodule
