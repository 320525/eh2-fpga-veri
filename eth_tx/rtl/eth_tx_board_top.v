`timescale 1ns / 1ps

// Physical board wrapper.  Clock, reset, LED, RGMII, MDIO and PHY-reset pins
// are identical to mac_fifo_dma_proj; DDR4 is intentionally not part of this
// transmit-only image.
module eth_tx_board_top (
  input  wire        sw3_1,
  input  wire        sw4_1,
  input  wire        gtx_clk_p,
  input  wire        gtx_clk_n,
  input  wire        refclk_p,
  input  wire        refclk_n,
  input  wire        s_axi_aclk_p,
  input  wire        s_axi_aclk_n,

  output wire [3:0]  rgmii_txd,
  output wire        rgmii_tx_ctl,
  output wire        rgmii_txc,
  input  wire [3:0]  rgmii_rxd,
  input  wire        rgmii_rx_ctl,
  input  wire        rgmii_rxc,
  inout  wire        mdio,
  output wire        mdc,
  output wire        phy_resetn,
  output wire [3:0]  led_t
);

  wire gtx_clk_ibuf;
  wire gtx_clk;
  wire refclk_ibuf;
  wire refclk;
  wire s_axi_aclk_ibuf;
  wire s_axi_aclk;

  IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("FALSE")
  ) gtx_clk_ibufds_i (
    .I  (gtx_clk_p),
    .IB (gtx_clk_n),
    .O  (gtx_clk_ibuf)
  );
  BUFG gtx_clk_bufg_i (.I(gtx_clk_ibuf), .O(gtx_clk));

  IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("FALSE")
  ) refclk_ibufds_i (
    .I  (refclk_p),
    .IB (refclk_n),
    .O  (refclk_ibuf)
  );
  BUFG refclk_bufg_i (.I(refclk_ibuf), .O(refclk));

  IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("FALSE")
  ) s_axi_aclk_ibufds_i (
    .I  (s_axi_aclk_p),
    .IB (s_axi_aclk_n),
    .O  (s_axi_aclk_ibuf)
  );
  BUFG s_axi_aclk_bufg_i (.I(s_axi_aclk_ibuf), .O(s_axi_aclk));

  wire system_resetn = sw3_1 & sw4_1;
  wire mac_config_done;
  wire mac_config_error;
  wire phy_init_success;
  wire tx_control_done;
  wire [31:0] tx_control_status;
  wire tx_atg_error;
  wire tx_fifo_overflow;
  wire [3:0] tx_fifo_frame_count;
  wire [3:0] tx_mac_frame_count;
  wire tx_length_error;

  eth_tx_core core_i (
    .gtx_clk                 (gtx_clk),
    .refclk                  (refclk),
    .s_axi_aclk              (s_axi_aclk),
    .system_resetn           (system_resetn),
    .rgmii_txd               (rgmii_txd),
    .rgmii_tx_ctl            (rgmii_tx_ctl),
    .rgmii_txc               (rgmii_txc),
    .rgmii_rxd               (rgmii_rxd),
    .rgmii_rx_ctl            (rgmii_rx_ctl),
    .rgmii_rxc               (rgmii_rxc),
    .mdio                    (mdio),
    .mdc                     (mdc),
    .phy_resetn              (phy_resetn),
    .mac_config_done         (mac_config_done),
    .mac_config_error        (mac_config_error),
    .phy_init_busy           (),
    .phy_init_done           (),
    .phy_init_success        (phy_init_success),
    .phy_init_error          (),
    .phy_addr                (),
    .phy_id1                 (),
    .phy_id2                 (),
    .phy_link_up             (),
    .phy_autoneg_complete    (),
    .tx_control_done         (tx_control_done),
    .tx_control_status       (tx_control_status),
    .tx_atg_error            (tx_atg_error),
    .tx_fifo_status          (),
    .tx_fifo_overflow        (tx_fifo_overflow),
    .tx_fifo_frame_count     (tx_fifo_frame_count),
    .tx_mac_frame_count      (tx_mac_frame_count),
    .tx_length_error         (tx_length_error),
    .inband_link_status      (),
    .inband_clock_speed      (),
    .inband_duplex_status    (),
    .mac_irq                 ()
  );

  assign led_t[0] = mac_config_done && !mac_config_error;
  assign led_t[1] = phy_init_success;
  assign led_t[2] = tx_control_done && (tx_control_status[1:0] == 2'b01);
  assign led_t[3] = (tx_mac_frame_count == 4'd10) &&
                    (tx_fifo_frame_count == 4'd10) &&
                    !tx_atg_error && !tx_fifo_overflow && !tx_length_error;

endmodule
