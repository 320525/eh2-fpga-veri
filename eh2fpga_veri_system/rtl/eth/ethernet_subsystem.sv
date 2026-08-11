`timescale 1ns/1ps

// One full-duplex TEMAC shared by the program, system-information and log
// paths.  The initialization sequence is copied from the validated eth_tx
// project: TEMAC System-Init ATG first, then DP83867 MDIO programming and
// stable-link polling.  READY soft resets never reach this module.
module ethernet_subsystem #(
  parameter integer PHY_INIT_BYPASS = 0,
  // Hardware waits one millisecond after the 200 MHz reference/reset release
  // before it can declare the input-delay calibration window complete.
  parameter integer IDELAY_GUARD_CYCLES = 100_000,
  // Require a continuous recovered receive clock before releasing RX logic.
  parameter integer RX_CLOCK_STABLE_EDGES = 4_096
) (
  input  logic       gtx_clk,
  input  logic       refclk,
  input  logic       ctrl_clk,
  input  logic       hard_resetn,

  output logic [15:0] rx_axis_tdata,
  output logic        rx_axis_tvalid,
  output logic        rx_axis_tlast,
  input  logic        rx_axis_tready,

  input  logic [7:0]  tx_axis_tdata,
  input  logic        tx_axis_tvalid,
  input  logic        tx_axis_tlast,
  output logic        tx_axis_tready,

  output logic [3:0]  rgmii_txd,
  output logic        rgmii_tx_ctl,
  output logic        rgmii_txc,
  input  logic [3:0]  rgmii_rxd,
  input  logic        rgmii_rx_ctl,
  input  logic        rgmii_rxc,
  inout  wire         mdio,
  output logic        mdc,
  output logic        phy_resetn,

  output logic        mac_config_done,
  output logic        mac_config_error,
  output logic        phy_init_busy,
  output logic        phy_init_done,
  output logic        phy_init_success,
  output logic [3:0]  phy_init_error,
  output logic        phy_link_up,
  output logic        phy_autoneg_complete,
  output logic        rgmii_rx_ready,
  output logic        rx_fcs_error_pulse,
  output logic [31:0] rx_fcs_error_count,
  output logic [31:0] tx_frame_complete_count,
  output logic [3:0]  rx_fifo_status,
  output logic        rx_fifo_overflow,
  output logic [3:0]  tx_fifo_status,
  output logic        tx_fifo_overflow,
  output logic        inband_link_status,
  output logic [1:0]  inband_clock_speed,
  output logic        inband_duplex_status,
  output logic        mac_irq
);
  logic [31:0] mac_atg_awaddr;
  logic [2:0]  mac_atg_awprot_unused;
  logic        mac_atg_awvalid;
  logic        mac_atg_awready;
  logic [31:0] mac_atg_wdata;
  logic [3:0]  mac_atg_wstrb_unused;
  logic        mac_atg_wvalid;
  logic        mac_atg_wready;
  logic [1:0]  mac_atg_bresp;
  logic        mac_atg_bvalid;
  logic        mac_atg_bready;
  logic        mac_atg_done;
  logic [31:0] mac_atg_status;

  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      mac_config_done  <= 1'b0;
      mac_config_error <= 1'b0;
    end else if (!mac_config_done && mac_atg_done) begin
      mac_config_done  <= 1'b1;
      mac_config_error <= (mac_atg_status[1:0] != 2'b01);
    end
  end

  logic [11:0] phy_axi_awaddr;
  logic        phy_axi_awvalid;
  logic        phy_axi_awready;
  logic [31:0] phy_axi_wdata;
  logic        phy_axi_wvalid;
  logic        phy_axi_wready;
  logic [1:0]  phy_axi_bresp;
  logic        phy_axi_bvalid;
  logic        phy_axi_bready;
  logic [11:0] phy_axi_araddr;
  logic        phy_axi_arvalid;
  logic        phy_axi_arready;
  logic [31:0] phy_axi_rdata;
  logic [1:0]  phy_axi_rresp;
  logic        phy_axi_rvalid;
  logic        phy_axi_rready;
  logic [4:0]  phy_addr_unused;
  logic [15:0] phy_id1_unused;
  logic [15:0] phy_id2_unused;

  wire mac_atg_active = !mac_config_done;
  wire phy_axi_active = (PHY_INIT_BYPASS == 0) && mac_config_done &&
                        !mac_config_error && !phy_init_done;

  logic [11:0] mac_axi_awaddr;
  logic        mac_axi_awvalid;
  logic        mac_axi_awready;
  logic [31:0] mac_axi_wdata;
  logic        mac_axi_wvalid;
  logic        mac_axi_wready;
  logic [1:0]  mac_axi_bresp;
  logic        mac_axi_bvalid;
  logic        mac_axi_bready;
  logic [11:0] mac_axi_araddr;
  logic        mac_axi_arvalid;
  logic        mac_axi_arready;
  logic [31:0] mac_axi_rdata;
  logic [1:0]  mac_axi_rresp;
  logic        mac_axi_rvalid;
  logic        mac_axi_rready;

  always_comb begin
    mac_axi_awaddr  = mac_atg_active ? mac_atg_awaddr[11:0] :
                      phy_axi_active ? phy_axi_awaddr : 12'b0;
    mac_axi_awvalid = mac_atg_active ? mac_atg_awvalid :
                      phy_axi_active ? phy_axi_awvalid : 1'b0;
    mac_axi_wdata   = mac_atg_active ? mac_atg_wdata :
                      phy_axi_active ? phy_axi_wdata : 32'b0;
    mac_axi_wvalid  = mac_atg_active ? mac_atg_wvalid :
                      phy_axi_active ? phy_axi_wvalid : 1'b0;
    mac_axi_bready  = mac_atg_active ? mac_atg_bready :
                      phy_axi_active ? phy_axi_bready : 1'b1;
    mac_axi_araddr  = phy_axi_active ? phy_axi_araddr : 12'b0;
    mac_axi_arvalid = phy_axi_active ? phy_axi_arvalid : 1'b0;
    mac_axi_rready  = phy_axi_active ? phy_axi_rready : 1'b1;

    mac_atg_awready = mac_atg_active ? mac_axi_awready : 1'b0;
    mac_atg_wready  = mac_atg_active ? mac_axi_wready : 1'b0;
    mac_atg_bresp   = mac_axi_bresp;
    mac_atg_bvalid  = mac_atg_active ? mac_axi_bvalid : 1'b0;

    phy_axi_awready = phy_axi_active ? mac_axi_awready : 1'b0;
    phy_axi_wready  = phy_axi_active ? mac_axi_wready : 1'b0;
    phy_axi_bresp   = mac_axi_bresp;
    phy_axi_bvalid  = phy_axi_active ? mac_axi_bvalid : 1'b0;
    phy_axi_arready = phy_axi_active ? mac_axi_arready : 1'b0;
    phy_axi_rdata   = mac_axi_rdata;
    phy_axi_rresp   = mac_axi_rresp;
    phy_axi_rvalid  = phy_axi_active ? mac_axi_rvalid : 1'b0;
  end

  axi_traffic_gen_0 mac_config_atg_i (
    .s_axi_aclk(ctrl_clk), .s_axi_aresetn(hard_resetn),
    .m_axi_lite_ch1_awaddr(mac_atg_awaddr),
    .m_axi_lite_ch1_awprot(mac_atg_awprot_unused),
    .m_axi_lite_ch1_awvalid(mac_atg_awvalid),
    .m_axi_lite_ch1_awready(mac_atg_awready),
    .m_axi_lite_ch1_wdata(mac_atg_wdata),
    .m_axi_lite_ch1_wstrb(mac_atg_wstrb_unused),
    .m_axi_lite_ch1_wvalid(mac_atg_wvalid),
    .m_axi_lite_ch1_wready(mac_atg_wready),
    .m_axi_lite_ch1_bresp(mac_atg_bresp),
    .m_axi_lite_ch1_bvalid(mac_atg_bvalid),
    .m_axi_lite_ch1_bready(mac_atg_bready),
    .done(mac_atg_done), .status(mac_atg_status)
  );

  generate
    if (PHY_INIT_BYPASS == 0) begin : g_phy_init
      dp83867_phy_init phy_init_i (
        .clk(ctrl_clk), .resetn(hard_resetn),
        .start(mac_config_done && !mac_config_error),
        .phy_resetn, .init_busy(phy_init_busy), .init_done(phy_init_done),
        .init_success(phy_init_success), .init_error(phy_init_error),
        .detected_phy_addr(phy_addr_unused), .phy_id1(phy_id1_unused),
        .phy_id2(phy_id2_unused), .phy_link_up,
        .phy_autoneg_complete,
        .m_axi_awaddr(phy_axi_awaddr), .m_axi_awvalid(phy_axi_awvalid),
        .m_axi_awready(phy_axi_awready), .m_axi_wdata(phy_axi_wdata),
        .m_axi_wvalid(phy_axi_wvalid), .m_axi_wready(phy_axi_wready),
        .m_axi_bresp(phy_axi_bresp), .m_axi_bvalid(phy_axi_bvalid),
        .m_axi_bready(phy_axi_bready), .m_axi_araddr(phy_axi_araddr),
        .m_axi_arvalid(phy_axi_arvalid), .m_axi_arready(phy_axi_arready),
        .m_axi_rdata(phy_axi_rdata), .m_axi_rresp(phy_axi_rresp),
        .m_axi_rvalid(phy_axi_rvalid), .m_axi_rready(phy_axi_rready)
      );
    end else begin : g_phy_bypass
      always_comb begin
        phy_resetn             = hard_resetn;
        phy_init_busy          = 1'b0;
        phy_init_done          = mac_config_done;
        phy_init_success       = mac_config_done && !mac_config_error;
        phy_init_error         = mac_config_error ? 4'h1 : 4'h0;
        phy_link_up            = 1'b1;
        phy_autoneg_complete   = 1'b1;
        phy_axi_awaddr         = 12'b0;
        phy_axi_awvalid        = 1'b0;
        phy_axi_wdata          = 32'b0;
        phy_axi_wvalid         = 1'b0;
        phy_axi_bready         = 1'b0;
        phy_axi_araddr         = 12'b0;
        phy_axi_arvalid        = 1'b0;
        phy_axi_rready         = 1'b0;
      end
    end
  endgenerate

  logic rx_mac_aclk;
  logic tx_mac_aclk_unused;
  logic rx_reset_unused;
  logic tx_reset_unused;
  logic rx_fifo_overflow_raw;
  logic [27:0] rx_statistics_vector;
  logic rx_statistics_valid;
  logic [31:0] tx_statistics_unused;
  logic tx_statistics_valid_unused;
  localparam integer EFFECTIVE_IDELAY_GUARD =
      (PHY_INIT_BYPASS != 0) ? 16 : IDELAY_GUARD_CYCLES;
  localparam integer EFFECTIVE_RX_STABLE_EDGES =
      (PHY_INIT_BYPASS != 0) ? 16 : RX_CLOCK_STABLE_EDGES;
  localparam integer IDELAY_COUNT_WIDTH =
      (EFFECTIVE_IDELAY_GUARD <= 2) ? 1 : $clog2(EFFECTIVE_IDELAY_GUARD);
  localparam integer RX_STABLE_COUNT_WIDTH =
      (EFFECTIVE_RX_STABLE_EDGES <= 2) ? 1 :
      $clog2(EFFECTIVE_RX_STABLE_EDGES);

  logic [IDELAY_COUNT_WIDTH-1:0] idelay_guard_count;
  logic idelay_guard_done;
  logic [RX_STABLE_COUNT_WIDTH-1:0] rx_stable_count;
  logic rx_clock_stable_rx;
  logic [0:0] rx_clock_stable_ctrl;
  logic [0:0] rx_stability_enable_rx;
  logic [31:0] tx_complete_count_tx;
  logic [31:0] tx_complete_count_gray_tx;
  logic [31:0] tx_complete_count_gray_ctrl;

  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      idelay_guard_count <= '0;
      idelay_guard_done  <= 1'b0;
    end else if (!idelay_guard_done) begin
      if (idelay_guard_count == EFFECTIVE_IDELAY_GUARD - 1) begin
        idelay_guard_done <= 1'b1;
      end else begin
        idelay_guard_count <= idelay_guard_count + 1'b1;
      end
    end
  end

  wire rx_stability_enable_ctrl = hard_resetn && idelay_guard_done &&
                                  mac_config_done && !mac_config_error &&
                                  phy_init_success && phy_link_up;
  sync_bits #(.WIDTH(1)) rx_stability_enable_sync_i (
    .clk(rx_mac_aclk), .resetn(hard_resetn),
    .async_in(rx_stability_enable_ctrl), .sync_out(rx_stability_enable_rx)
  );

  // rx_mac_aclk is derived directly from the RGMII RXC input by the TEMAC
  // physical wrapper and is available while the client datapath is reset.
  // Start the edge qualification only after PHY delay programming/readback,
  // link detection and the conservative IDELAYCTRL calibration guard.  This
  // prevents a pre-autonegotiation 2.5/25 MHz RXC from satisfying the test for
  // the final 125 MHz gigabit clock.
  always_ff @(posedge rx_mac_aclk or negedge hard_resetn) begin
    if (!hard_resetn || !rx_stability_enable_rx[0]) begin
      rx_stable_count   <= '0;
      rx_clock_stable_rx <= 1'b0;
    end else if (!rx_clock_stable_rx) begin
      if (rx_stable_count == EFFECTIVE_RX_STABLE_EDGES - 1)
        rx_clock_stable_rx <= 1'b1;
      else
        rx_stable_count <= rx_stable_count + 1'b1;
    end
  end

  sync_bits #(.WIDTH(1)) rx_clock_stable_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in(rx_clock_stable_rx), .sync_out(rx_clock_stable_ctrl)
  );

  always_comb begin
    rgmii_rx_ready = hard_resetn && idelay_guard_done &&
                     mac_config_done && !mac_config_error &&
                     phy_init_success && phy_link_up &&
                     rx_clock_stable_ctrl[0];
  end

  wire tx_client_resetn = hard_resetn && mac_config_done &&
                          !mac_config_error && phy_init_success;
  wire rx_client_resetn = rgmii_rx_ready;

  eth_mac_fifo_block mac_fifo_i (
    .gtx_clk, .glbl_rstn(hard_resetn), .rx_axi_rstn(rx_client_resetn),
    .tx_axi_rstn(hard_resetn), .refclk,
    .rx_mac_aclk(rx_mac_aclk), .rx_reset(rx_reset_unused),
    .rx_statistics_vector(rx_statistics_vector),
    .rx_statistics_valid(rx_statistics_valid),
    .rx_fifo_clock(ctrl_clk), .rx_fifo_resetn(rx_client_resetn),
    .rx_axis_fifo_tdata(rx_axis_tdata),
    .rx_axis_fifo_tvalid(rx_axis_tvalid),
    .rx_axis_fifo_tready(rx_axis_tready),
    .rx_axis_fifo_tlast(rx_axis_tlast),
    .rx_fifo_status, .rx_fifo_overflow(rx_fifo_overflow_raw),
    .tx_mac_aclk(tx_mac_aclk_unused), .tx_reset(tx_reset_unused),
    .tx_ifg_delay(8'h00), .tx_statistics_vector(tx_statistics_unused),
    .tx_statistics_valid(tx_statistics_valid_unused),
    .tx_fifo_clock(ctrl_clk), .tx_fifo_resetn(tx_client_resetn),
    .tx_axis_fifo_tdata(tx_axis_tdata),
    .tx_axis_fifo_tvalid(tx_axis_tvalid),
    .tx_axis_fifo_tready(tx_axis_tready),
    .tx_axis_fifo_tlast(tx_axis_tlast),
    .tx_fifo_status, .tx_fifo_overflow,
    .pause_req(1'b0), .pause_val(16'b0),
    .rgmii_txd, .rgmii_tx_ctl, .rgmii_txc,
    .rgmii_rxd, .rgmii_rx_ctl, .rgmii_rxc,
    .inband_link_status, .inband_clock_speed,
    .inband_duplex_status, .mdio, .mdc,
    .s_axi_aclk(ctrl_clk), .s_axi_resetn(hard_resetn),
    .s_axi_awaddr(mac_axi_awaddr), .s_axi_awvalid(mac_axi_awvalid),
    .s_axi_awready(mac_axi_awready), .s_axi_wdata(mac_axi_wdata),
    .s_axi_wvalid(mac_axi_wvalid), .s_axi_wready(mac_axi_wready),
    .s_axi_bresp(mac_axi_bresp), .s_axi_bvalid(mac_axi_bvalid),
    .s_axi_bready(mac_axi_bready), .s_axi_araddr(mac_axi_araddr),
    .s_axi_arvalid(mac_axi_arvalid), .s_axi_arready(mac_axi_arready),
    .s_axi_rdata(mac_axi_rdata), .s_axi_rresp(mac_axi_rresp),
    .s_axi_rvalid(mac_axi_rvalid), .s_axi_rready(mac_axi_rready),
    .mac_irq
  );

  // fifo_overflow is synchronous to rx_mac_aclk and may be only one RX clock
  // wide.  A toggle CDC prevents the 100 MHz error monitor from missing it.
  event_toggle_cdc rx_fifo_overflow_cdc_i (
    .src_clk(rx_mac_aclk), .dst_clk(ctrl_clk),
    .resetn(hard_resetn), .src_event(rx_fifo_overflow_raw),
    .dst_pulse(rx_fifo_overflow)
  );

  // PG051 defines bit 2 of a valid receive statistics vector as FCS_ERROR.
  // The TEMAC drops that frame before the client FIFO, so retain the sideband
  // event and diagnostic count explicitly across the RX/control clock boundary.
  mac_rx_statistics_cdc rx_statistics_cdc_i (
    .rx_clk(rx_mac_aclk), .ctrl_clk, .resetn(hard_resetn),
    .statistics_vector(rx_statistics_vector),
    .statistics_valid(rx_statistics_valid),
    .fcs_error_pulse(rx_fcs_error_pulse),
    .fcs_error_count(rx_fcs_error_count)
  );

  // Count frames at the MAC transmitter completion boundary, not when their
  // final AXI byte merely enters the client FIFO.  END uses this count to keep
  // global reset from truncating EH2_DONE or EXE_END on the RGMII pins.
  always_ff @(posedge tx_mac_aclk_unused or negedge hard_resetn) begin
    if (!hard_resetn)
      tx_complete_count_tx <= 32'b0;
    else if (tx_statistics_valid_unused)
      tx_complete_count_tx <= tx_complete_count_tx + 32'd1;
  end
  assign tx_complete_count_gray_tx =
      (tx_complete_count_tx >> 1) ^ tx_complete_count_tx;
  sync_bits #(.WIDTH(32)) tx_complete_count_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in(tx_complete_count_gray_tx),
    .sync_out(tx_complete_count_gray_ctrl)
  );
  always_comb begin
    tx_frame_complete_count[31] = tx_complete_count_gray_ctrl[31];
    for (integer bit_index = 30; bit_index >= 0; bit_index = bit_index - 1)
      tx_frame_complete_count[bit_index] =
          tx_frame_complete_count[bit_index+1] ^
          tx_complete_count_gray_ctrl[bit_index];
  end
endmodule
