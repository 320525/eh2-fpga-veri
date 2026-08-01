`timescale 1ps / 1ps

// Hardware integration top:
//   AXI Traffic Generator startup configuration -> TEMAC AXI4-Lite
//   125 MHz MAC transmit clock; the receive FIFO/DataMover clock is the
//   buffered RGMII RX clock (125 MHz for a 1 Gb/s link)
//       -> 32-bit asynchronous AXI clock converter (RX clock to 266.5 MHz)
//       -> AXI data-width converter (32 bit to 512 bit at 266.5 MHz)
//       -> 8 GB x72 ECC DDR4 MIG.
//
// The original mac_fifo_dma_top remains unchanged and is still used by its
// behavioral testbench.  This wrapper adds the DDR4 memory path needed for
// hardware.  The receive/DMA path is held in reset until MIG calibration has
// completed and that status has been synchronized into the 125 MHz domain.
module mac_fifo_dma_ddr4_top #(
  // Hardware defaults to deterministic DP83867 initialization.  The bypass
  // exists only so the legacy frame/DMA testbench can run without a detailed
  // behavioral MDIO PHY model.
  parameter integer PHY_INIT_BYPASS = 0
) (
  // Board-wide reset release, matching led_test.  Both switches must be high
  // before any MAC, FIFO, DMA, AXI or MIG logic is released from reset.
  input  wire        sw3_1,
  input  wire        sw4_1,

  // SI5338 programmable differential clocks.  Each input is converted to a
  // global single-ended clock below; the existing MIG clock is independent.
  input  wire        gtx_clk_p,
  input  wire        gtx_clk_n,
  input  wire        refclk_p,
  input  wire        refclk_n,

  output wire        rx_mac_aclk,
  output wire        rx_reset,
  output wire [27:0] rx_statistics_vector,
  output wire        rx_statistics_valid,

  // Receive/DataMover domain uses rx_mac_aclk, which TEMAC derives from the
  // PHY RGMII RX clock through its dedicated input buffer and BUFG.
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
  output wire        phy_resetn,
  output wire        phy_init_busy,
  output wire        phy_init_done,
  output wire        phy_init_success,
  output wire [3:0]  phy_init_error,
  output wire [4:0]  phy_addr,
  output wire [15:0] phy_id1,
  output wire [15:0] phy_id2,
  output wire        phy_link_up,
  output wire        phy_autoneg_complete,

  // MAC AXI4-Lite configuration interface and its SI5338 differential clock.
  input  wire        s_axi_aclk_p,
  input  wire        s_axi_aclk_n,
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

  // DDR4-1 reference clock.
  input  wire        c0_sys_clk_p,
  input  wire        c0_sys_clk_n,

  // DDR4-1 physical interface for the x72 ECC SODIMM.
  output wire        c0_ddr4_act_n,
  output wire [16:0] c0_ddr4_adr,
  output wire [1:0]  c0_ddr4_ba,
  output wire [1:0]  c0_ddr4_bg,
  output wire [0:0]  c0_ddr4_cke,
  output wire [0:0]  c0_ddr4_odt,
  output wire [0:0]  c0_ddr4_cs_n,
  output wire [0:0]  c0_ddr4_ck_t,
  output wire [0:0]  c0_ddr4_ck_c,
  output wire        c0_ddr4_reset_n,
  inout  wire [8:0]  c0_ddr4_dm_dbi_n,
  inout  wire [71:0] c0_ddr4_dq,
  inout  wire [8:0]  c0_ddr4_dqs_c,
  inout  wire [8:0]  c0_ddr4_dqs_t,

  // DDR4 status and generated 266.5 MHz user clock.
  output wire        c0_init_calib_complete,
  output wire        c0_ddr4_ui_clk,
  output wire        c0_ddr4_ui_clk_sync_rst,
  output wire        c0_ddr4_interrupt,
  output wire        dma_memory_ready,

  // Receive/DMA monitoring.
  output wire [31:0] frame_count,
  output wire [31:0] dma_write_addr,
  output wire        frame_done,
  output wire        dma_done,
  output wire        dma_error,
  output wire        frame_length_error,
  output wire [31:0] last_dma_status,
  output wire        dma_busy,
  output wire        s2mm_err,

  // Active-high board LEDs: T1=accepted destination seen, T2=DMA data match,
  // T3=DDR address-zero readback match, T4=PHY and DDR4 ready.
  output wire [3:0]  led_t
);

  // The board's SI5338 outputs are AC-coupled and externally terminated.
  // DIFF_TERM therefore remains disabled, as required by the board manual.
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
    .I(gtx_clk_p),
    .IB(gtx_clk_n),
    .O(gtx_clk_ibuf)
  );

  BUFG gtx_clk_bufg_i (
    .I(gtx_clk_ibuf),
    .O(gtx_clk)
  );

  IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("FALSE")
  ) refclk_ibufds_i (
    .I(refclk_p),
    .IB(refclk_n),
    .O(refclk_ibuf)
  );

  BUFG refclk_bufg_i (
    .I(refclk_ibuf),
    .O(refclk)
  );

  IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("FALSE")
  ) s_axi_aclk_ibufds_i (
    .I(s_axi_aclk_p),
    .IB(s_axi_aclk_n),
    .O(s_axi_aclk_ibuf)
  );

  BUFG s_axi_aclk_bufg_i (
    .I(s_axi_aclk_ibuf),
    .O(s_axi_aclk)
  );

  // TEMAC's rx_mac_aclk is the already-buffered RGMII receive clock.  Reuse
  // this clock for the FIFO read side, frame controller, DataMover and the
  // source side of the asynchronous AXI clock converter.
  wire rx_fifo_clock = rx_mac_aclk;

  // led_test board reset convention: both switches high releases the whole
  // design.  All non-MIG blocks use the active-low form; MIG expects the
  // complementary active-high system reset.
  wire system_resetn = sw3_1 & sw4_1;
  wire mig_sys_rst   = ~system_resetn;

  // AXI Traffic Generator System Init first owns the TEMAC AXI4-Lite write
  // interface.  The DP83867 sequencer then owns both reads and writes until
  // PHY initialization completes; only then is the external port restored.
  wire        atg_resetn = system_resetn;
  wire [31:0] atg_awaddr;
  wire [2:0]  atg_awprot_unused;
  wire        atg_awvalid;
  wire        atg_awready;
  wire [31:0] atg_wdata;
  wire [3:0]  atg_wstrb;
  wire        atg_wvalid;
  wire        atg_wready;
  wire [1:0]  atg_bresp;
  wire        atg_bvalid;
  wire        atg_bready;
  wire        atg_done;
  wire [31:0] atg_status;
  reg         mac_config_done_reg;
  reg         mac_config_error_reg;
  wire        mac_config_done  = mac_config_done_reg;
  wire        mac_config_error = mac_config_error_reg;
  wire        atg_active = !mac_config_done;
  wire [31:0] mac_config_status;

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

  wire phy_init_active = !PHY_INIT_BYPASS && mac_config_done &&
                         !mac_config_error && !phy_init_done_int;
  wire external_axi_active = mac_config_done && !phy_init_active;

  wire [11:0] mac_axi_awaddr = atg_active ? atg_awaddr[11:0] :
                                     phy_init_active ? phy_axi_awaddr :
                                                       s_axi_awaddr;
  wire        mac_axi_awvalid = atg_active ? atg_awvalid :
                                      phy_init_active ? phy_axi_awvalid :
                                                        s_axi_awvalid;
  wire        mac_axi_awready;
  wire [31:0] mac_axi_wdata = atg_active ? atg_wdata :
                                  phy_init_active ? phy_axi_wdata : s_axi_wdata;
  wire        mac_axi_wvalid = atg_active ? atg_wvalid :
                                  phy_init_active ? phy_axi_wvalid : s_axi_wvalid;
  wire        mac_axi_wready;
  wire [1:0]  mac_axi_bresp;
  wire        mac_axi_bvalid;
  wire        mac_axi_bready = atg_active ? atg_bready :
                                  phy_init_active ? phy_axi_bready : s_axi_bready;
  wire [11:0] mac_axi_araddr = phy_init_active ? phy_axi_araddr :
                                                 s_axi_araddr;
  wire        mac_axi_arvalid = phy_init_active ? phy_axi_arvalid :
                                                  s_axi_arvalid;
  wire        mac_axi_arready;
  wire [31:0] mac_axi_rdata;
  wire [1:0]  mac_axi_rresp;
  wire        mac_axi_rvalid;
  wire        mac_axi_rready = phy_init_active ? phy_axi_rready :
                                                 s_axi_rready;

  assign atg_awready = atg_active ? mac_axi_awready : 1'b0;
  assign atg_wready  = atg_active ? mac_axi_wready  : 1'b0;
  assign atg_bresp   = mac_axi_bresp;
  assign atg_bvalid  = atg_active ? mac_axi_bvalid : 1'b0;

  assign phy_axi_awready = phy_init_active ? mac_axi_awready : 1'b0;
  assign phy_axi_wready  = phy_init_active ? mac_axi_wready  : 1'b0;
  assign phy_axi_bresp   = mac_axi_bresp;
  assign phy_axi_bvalid  = phy_init_active ? mac_axi_bvalid  : 1'b0;
  assign phy_axi_arready = phy_init_active ? mac_axi_arready : 1'b0;
  assign phy_axi_rdata   = mac_axi_rdata;
  assign phy_axi_rresp   = mac_axi_rresp;
  assign phy_axi_rvalid  = phy_init_active ? mac_axi_rvalid  : 1'b0;

  assign s_axi_awready = external_axi_active ? mac_axi_awready : 1'b0;
  assign s_axi_wready  = external_axi_active ? mac_axi_wready  : 1'b0;
  assign s_axi_bresp   = mac_axi_bresp;
  assign s_axi_bvalid  = external_axi_active ? mac_axi_bvalid : 1'b0;

  assign s_axi_arready = external_axi_active ? mac_axi_arready : 1'b0;
  assign s_axi_rdata   = mac_axi_rdata;
  assign s_axi_rresp   = mac_axi_rresp;
  assign s_axi_rvalid  = external_axi_active ? mac_axi_rvalid : 1'b0;

  assign mac_config_status = atg_status;

  // Capture the ATG completion result in its native management-clock domain
  // before it crosses into the RGMII RX/DataMover domain.  Registering both
  // values avoids placing status decode logic ahead of the CDC synchronizer
  // and also guarantees that PHY initialization cannot start until the final
  // ATG status has been sampled.
  always @(posedge s_axi_aclk or negedge system_resetn) begin
    if (!system_resetn) begin
      mac_config_done_reg  <= 1'b0;
      mac_config_error_reg <= 1'b0;
    end
    else if (!mac_config_done_reg && atg_done) begin
      mac_config_done_reg  <= 1'b1;
      mac_config_error_reg <= (atg_status[1:0] != 2'b01);
    end
  end

  assign phy_resetn             = phy_resetn_int;
  assign phy_init_busy          = phy_init_busy_int;
  assign phy_init_done          = phy_init_done_int;
  assign phy_init_success       = phy_init_success_int;
  assign phy_init_error         = phy_init_error_int;
  assign phy_addr               = phy_addr_int;
  assign phy_id1                = phy_id1_int;
  assign phy_id2                = phy_id2_int;
  assign phy_link_up            = phy_link_up_int;
  assign phy_autoneg_complete   = phy_autoneg_complete_int;

  axi_traffic_gen_0 mac_config_atg_i (
    .s_axi_aclk(s_axi_aclk),
    .s_axi_aresetn(atg_resetn),
    .m_axi_lite_ch1_awaddr(atg_awaddr),
    .m_axi_lite_ch1_awprot(atg_awprot_unused),
    .m_axi_lite_ch1_awvalid(atg_awvalid),
    .m_axi_lite_ch1_awready(atg_awready),
    .m_axi_lite_ch1_wdata(atg_wdata),
    .m_axi_lite_ch1_wstrb(atg_wstrb),
    .m_axi_lite_ch1_wvalid(atg_wvalid),
    .m_axi_lite_ch1_wready(atg_wready),
    .m_axi_lite_ch1_bresp(atg_bresp),
    .m_axi_lite_ch1_bvalid(atg_bvalid),
    .m_axi_lite_ch1_bready(atg_bready),
    .done(atg_done),
    .status(atg_status)
  );

  generate
    if (PHY_INIT_BYPASS == 0) begin : gen_dp83867_init
      dp83867_phy_init phy_init_i (
        .clk(s_axi_aclk),
        .resetn(system_resetn),
        .start(mac_config_done && !mac_config_error),
        .phy_resetn(phy_resetn_int),
        .init_busy(phy_init_busy_int),
        .init_done(phy_init_done_int),
        .init_success(phy_init_success_int),
        .init_error(phy_init_error_int),
        .detected_phy_addr(phy_addr_int),
        .phy_id1(phy_id1_int),
        .phy_id2(phy_id2_int),
        .phy_link_up(phy_link_up_int),
        .phy_autoneg_complete(phy_autoneg_complete_int),
        .m_axi_awaddr(phy_axi_awaddr),
        .m_axi_awvalid(phy_axi_awvalid),
        .m_axi_awready(phy_axi_awready),
        .m_axi_wdata(phy_axi_wdata),
        .m_axi_wvalid(phy_axi_wvalid),
        .m_axi_wready(phy_axi_wready),
        .m_axi_bresp(phy_axi_bresp),
        .m_axi_bvalid(phy_axi_bvalid),
        .m_axi_bready(phy_axi_bready),
        .m_axi_araddr(phy_axi_araddr),
        .m_axi_arvalid(phy_axi_arvalid),
        .m_axi_arready(phy_axi_arready),
        .m_axi_rdata(phy_axi_rdata),
        .m_axi_rresp(phy_axi_rresp),
        .m_axi_rvalid(phy_axi_rvalid),
        .m_axi_rready(phy_axi_rready)
      );
    end
    else begin : gen_phy_init_bypass
      assign phy_resetn_int            = system_resetn;
      assign phy_init_busy_int         = 1'b0;
      assign phy_init_done_int         = mac_config_done;
      assign phy_init_success_int      = mac_config_done && !mac_config_error;
      assign phy_init_error_int        = mac_config_error ? 4'h1 : 4'h0;
      assign phy_addr_int              = 5'd0;
      assign phy_id1_int               = 16'h2000;
      assign phy_id2_int               = 16'hA230;
      assign phy_link_up_int           = inband_link_status;
      assign phy_autoneg_complete_int  = 1'b0;
      assign phy_axi_awaddr            = 12'd0;
      assign phy_axi_awvalid           = 1'b0;
      assign phy_axi_wdata             = 32'd0;
      assign phy_axi_wvalid            = 1'b0;
      assign phy_axi_bready            = 1'b0;
      assign phy_axi_araddr            = 12'd0;
      assign phy_axi_arvalid           = 1'b0;
      assign phy_axi_rready            = 1'b0;
    end
  endgenerate

  // Synchronize the stable MIG calibration result and MAC configuration
  // completion into the RGMII receive/DataMover clock domain.
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  reg [1:0] calib_complete_sync = 2'b00;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  reg [1:0] mac_config_done_sync = 2'b00;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  reg [1:0] mac_config_error_sync = 2'b00;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  reg [1:0] phy_init_success_sync = 2'b00;
  always @(posedge rx_fifo_clock) begin
    if (!system_resetn) begin
      calib_complete_sync <= 2'b00;
      mac_config_done_sync <= 2'b00;
      mac_config_error_sync <= 2'b00;
      phy_init_success_sync <= 2'b00;
    end
    else begin
      calib_complete_sync <= {calib_complete_sync[0],
                              c0_init_calib_complete};
      mac_config_done_sync <= {mac_config_done_sync[0], mac_config_done};
      mac_config_error_sync <= {mac_config_error_sync[0],
                                mac_config_error};
      phy_init_success_sync <= {phy_init_success_sync[0],
                                phy_init_success_int};
    end
  end

  assign dma_memory_ready = calib_complete_sync[1];

  // Reception and DMA start only after DDR4 is ready and TEMAC startup
  // configuration plus DP83867 initialization have completed successfully.
  wire dma_path_resetn = system_resetn && dma_memory_ready &&
                         mac_config_done_sync[1] &&
                         !mac_config_error_sync[1] &&
                         phy_init_success_sync[1];

  // The MIG AXI interface and both 266.5 MHz converter sides use the MIG UI
  // clock domain.  Holding reset until calibration prevents early writes.
  wire mig_axi_resetn = c0_init_calib_complete &&
                        !c0_ddr4_ui_clk_sync_rst;

  // DataMover 32-bit AXI master signals in the RGMII RX clock domain.
  wire [3:0]  dm_awid;
  wire [31:0] dm_awaddr;
  wire [7:0]  dm_awlen;
  wire [2:0]  dm_awsize;
  wire [1:0]  dm_awburst;
  wire [2:0]  dm_awprot;
  wire [3:0]  dm_awcache;
  wire [3:0]  dm_awuser_unused;
  wire        dm_awvalid;
  wire        dm_awready;
  wire [31:0] dm_wdata;
  wire [3:0]  dm_wstrb;
  wire        dm_wlast;
  wire        dm_wvalid;
  wire        dm_wready;
  wire [1:0]  dm_bresp;
  wire        dm_bvalid;
  wire        dm_bready;

  // Clock-converter output: 32-bit AXI at the 266.5 MHz MIG UI clock.
  wire [3:0]  cc_awid;
  wire [32:0] cc_awaddr;
  wire [7:0]  cc_awlen;
  wire [2:0]  cc_awsize;
  wire [1:0]  cc_awburst;
  wire [0:0]  cc_awlock;
  wire [3:0]  cc_awcache;
  wire [2:0]  cc_awprot;
  wire [3:0]  cc_awregion;
  wire [3:0]  cc_awqos;
  wire        cc_awvalid;
  wire        cc_awready;
  wire [31:0] cc_wdata;
  wire [3:0]  cc_wstrb;
  wire        cc_wlast;
  wire        cc_wvalid;
  wire        cc_wready;
  wire [3:0]  cc_bid;
  wire [1:0]  cc_bresp;
  wire        cc_bvalid;
  wire        cc_bready;

  // Data-width-converter output: 512-bit AXI at 266.5 MHz.
  wire [32:0] mig_awaddr;
  wire [7:0]  mig_awlen;
  wire [2:0]  mig_awsize;
  wire [1:0]  mig_awburst;
  wire [0:0]  mig_awlock;
  wire [3:0]  mig_awcache;
  wire [2:0]  mig_awprot;
  wire [3:0]  mig_awregion_unused;
  wire [3:0]  mig_awqos;
  wire        mig_awvalid;
  wire        mig_awready;
  wire [511:0] mig_wdata;
  wire [63:0]  mig_wstrb;
  wire         mig_wlast;
  wire         mig_wvalid;
  wire         mig_wready;
  wire [1:0]   mig_bresp;
  wire         mig_bvalid;
  wire         mig_bready;
  wire [3:0]   mig_bid_unused;
  wire [3:0]   mig_arid;
  wire [32:0]  mig_araddr;
  wire [7:0]   mig_arlen;
  wire [2:0]   mig_arsize;
  wire [1:0]   mig_arburst;
  wire         mig_arlock;
  wire [3:0]   mig_arcache;
  wire [2:0]   mig_arprot;
  wire [3:0]   mig_arqos;
  wire         mig_arvalid;
  wire         mig_arready;
  wire         mig_rready;
  wire [3:0]   mig_rid;
  wire [511:0] mig_rdata;
  wire [1:0]   mig_rresp;
  wire         mig_rlast;
  wire         mig_rvalid;
  wire         ddr_read_done;
  wire         ddr_read_error;
  wire         rx_fifo_readable;
  wire         rx_frame_accepted;

  dma_ddr_led_checker led_checker_i (
    .dma_clk(rx_fifo_clock),
    .dma_resetn(dma_path_resetn),
    .rx_frame_accepted(rx_frame_accepted),
    .dma_wdata(dm_wdata),
    .dma_wstrb(dm_wstrb),
    .dma_wvalid(dm_wvalid),
    .dma_wready(dm_wready),
    .mig_clk(c0_ddr4_ui_clk),
    .mig_resetn(mig_axi_resetn),
    .mig_bresp(mig_bresp),
    .mig_bvalid(mig_bvalid),
    .mig_bready(mig_bready),
    .mig_arid(mig_arid),
    .mig_araddr(mig_araddr),
    .mig_arlen(mig_arlen),
    .mig_arsize(mig_arsize),
    .mig_arburst(mig_arburst),
    .mig_arlock(mig_arlock),
    .mig_arcache(mig_arcache),
    .mig_arprot(mig_arprot),
    .mig_arqos(mig_arqos),
    .mig_arvalid(mig_arvalid),
    .mig_arready(mig_arready),
    .mig_rready(mig_rready),
    .mig_rid(mig_rid),
    .mig_rdata(mig_rdata),
    .mig_rresp(mig_rresp),
    .mig_rlast(mig_rlast),
    .mig_rvalid(mig_rvalid),
    .led_t(led_t),
    .ddr_read_done(ddr_read_done),
    .ddr_read_error(ddr_read_error)
  );

  // The original tested MAC/FIFO/controller/DataMover design uses the
  // buffered RGMII RX clock and presents its existing 32-bit AXI write master.
  mac_fifo_dma_top dma_core_i (
    .gtx_clk(gtx_clk),
    .glbl_rstn(system_resetn),
    .rx_axi_rstn(system_resetn),
    .tx_axi_rstn(system_resetn),
    .refclk(refclk),
    .rx_mac_aclk(rx_mac_aclk),
    .rx_reset(rx_reset),
    .rx_statistics_vector(rx_statistics_vector),
    .rx_statistics_valid(rx_statistics_valid),
    .rx_fifo_clock(rx_fifo_clock),
    .rx_fifo_resetn(dma_path_resetn),
    .rx_fifo_readable(rx_fifo_readable),
    .rx_frame_accepted(rx_frame_accepted),
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
    .s_axi_resetn(atg_resetn),
    .s_axi_awaddr(mac_axi_awaddr),
    .s_axi_awvalid(mac_axi_awvalid),
    .s_axi_awready(mac_axi_awready),
    .s_axi_wdata(mac_axi_wdata),
    .s_axi_wvalid(mac_axi_wvalid),
    .s_axi_wready(mac_axi_wready),
    .s_axi_bresp(mac_axi_bresp),
    .s_axi_bvalid(mac_axi_bvalid),
    .s_axi_bready(mac_axi_bready),
    .s_axi_araddr(mac_axi_araddr),
    .s_axi_arvalid(mac_axi_arvalid),
    .s_axi_arready(mac_axi_arready),
    .s_axi_rdata(mac_axi_rdata),
    .s_axi_rresp(mac_axi_rresp),
    .s_axi_rvalid(mac_axi_rvalid),
    .s_axi_rready(mac_axi_rready),
    .mac_irq(mac_irq),
    .m_axi_s2mm_awid(dm_awid),
    .m_axi_s2mm_awaddr(dm_awaddr),
    .m_axi_s2mm_awlen(dm_awlen),
    .m_axi_s2mm_awsize(dm_awsize),
    .m_axi_s2mm_awburst(dm_awburst),
    .m_axi_s2mm_awprot(dm_awprot),
    .m_axi_s2mm_awcache(dm_awcache),
    .m_axi_s2mm_awuser(dm_awuser_unused),
    .m_axi_s2mm_awvalid(dm_awvalid),
    .m_axi_s2mm_awready(dm_awready),
    .m_axi_s2mm_wdata(dm_wdata),
    .m_axi_s2mm_wstrb(dm_wstrb),
    .m_axi_s2mm_wlast(dm_wlast),
    .m_axi_s2mm_wvalid(dm_wvalid),
    .m_axi_s2mm_wready(dm_wready),
    .m_axi_s2mm_bresp(dm_bresp),
    .m_axi_s2mm_bvalid(dm_bvalid),
    .m_axi_s2mm_bready(dm_bready),
    .frame_count(frame_count),
    .dma_write_addr(dma_write_addr),
    .frame_done(frame_done),
    .dma_done(dma_done),
    .dma_error(dma_error),
    .frame_length_error(frame_length_error),
    .last_dma_status(last_dma_status),
    .dma_busy(dma_busy),
    .s2mm_err(s2mm_err)
  );

  // Asynchronous RGMII RX clock -> 266.5 MHz AXI write-channel crossing.  The
  // DMA's 32-bit address is zero-extended, selecting the MIG's low 4 GB.
  axi_clock_converter_0 axi_clock_converter_i (
    .s_axi_aclk(rx_fifo_clock),
    .s_axi_aresetn(dma_path_resetn),
    .s_axi_awid(dm_awid),
    .s_axi_awaddr({1'b0, dm_awaddr}),
    .s_axi_awlen(dm_awlen),
    .s_axi_awsize(dm_awsize),
    .s_axi_awburst(dm_awburst),
    .s_axi_awlock(1'b0),
    .s_axi_awcache(dm_awcache),
    .s_axi_awprot(dm_awprot),
    .s_axi_awregion(4'b0000),
    .s_axi_awqos(4'b0000),
    .s_axi_awvalid(dm_awvalid),
    .s_axi_awready(dm_awready),
    .s_axi_wdata(dm_wdata),
    .s_axi_wstrb(dm_wstrb),
    .s_axi_wlast(dm_wlast),
    .s_axi_wvalid(dm_wvalid),
    .s_axi_wready(dm_wready),
    .s_axi_bid(),
    .s_axi_bresp(dm_bresp),
    .s_axi_bvalid(dm_bvalid),
    .s_axi_bready(dm_bready),
    .m_axi_aclk(c0_ddr4_ui_clk),
    .m_axi_aresetn(mig_axi_resetn),
    .m_axi_awid(cc_awid),
    .m_axi_awaddr(cc_awaddr),
    .m_axi_awlen(cc_awlen),
    .m_axi_awsize(cc_awsize),
    .m_axi_awburst(cc_awburst),
    .m_axi_awlock(cc_awlock),
    .m_axi_awcache(cc_awcache),
    .m_axi_awprot(cc_awprot),
    .m_axi_awregion(cc_awregion),
    .m_axi_awqos(cc_awqos),
    .m_axi_awvalid(cc_awvalid),
    .m_axi_awready(cc_awready),
    .m_axi_wdata(cc_wdata),
    .m_axi_wstrb(cc_wstrb),
    .m_axi_wlast(cc_wlast),
    .m_axi_wvalid(cc_wvalid),
    .m_axi_wready(cc_wready),
    .m_axi_bid(cc_bid),
    .m_axi_bresp(cc_bresp),
    .m_axi_bvalid(cc_bvalid),
    .m_axi_bready(cc_bready)
  );

  // Pack sixteen consecutive 32-bit DMA beats into each 512-bit MIG beat.
  axi_dwidth_converter_0 axi_dwidth_converter_i (
    .s_axi_aclk(c0_ddr4_ui_clk),
    .s_axi_aresetn(mig_axi_resetn),
    .s_axi_awid(cc_awid),
    .s_axi_awaddr(cc_awaddr),
    .s_axi_awlen(cc_awlen),
    .s_axi_awsize(cc_awsize),
    .s_axi_awburst(cc_awburst),
    .s_axi_awlock(cc_awlock),
    .s_axi_awcache(cc_awcache),
    .s_axi_awprot(cc_awprot),
    .s_axi_awregion(cc_awregion),
    .s_axi_awqos(cc_awqos),
    .s_axi_awvalid(cc_awvalid),
    .s_axi_awready(cc_awready),
    .s_axi_wdata(cc_wdata),
    .s_axi_wstrb(cc_wstrb),
    .s_axi_wlast(cc_wlast),
    .s_axi_wvalid(cc_wvalid),
    .s_axi_wready(cc_wready),
    .s_axi_bid(cc_bid),
    .s_axi_bresp(cc_bresp),
    .s_axi_bvalid(cc_bvalid),
    .s_axi_bready(cc_bready),
    .m_axi_awaddr(mig_awaddr),
    .m_axi_awlen(mig_awlen),
    .m_axi_awsize(mig_awsize),
    .m_axi_awburst(mig_awburst),
    .m_axi_awlock(mig_awlock),
    .m_axi_awcache(mig_awcache),
    .m_axi_awprot(mig_awprot),
    .m_axi_awregion(mig_awregion_unused),
    .m_axi_awqos(mig_awqos),
    .m_axi_awvalid(mig_awvalid),
    .m_axi_awready(mig_awready),
    .m_axi_wdata(mig_wdata),
    .m_axi_wstrb(mig_wstrb),
    .m_axi_wlast(mig_wlast),
    .m_axi_wvalid(mig_wvalid),
    .m_axi_wready(mig_wready),
    .m_axi_bresp(mig_bresp),
    .m_axi_bvalid(mig_bvalid),
    .m_axi_bready(mig_bready)
  );

  // 8 GB x72 ECC DDR4-2133 SODIMM controller.  Read and control interfaces
  // are tied inactive because the current datapath is S2MM write-only.
  ddr4_0 ddr4_i (
    .c0_init_calib_complete(c0_init_calib_complete),
    .dbg_clk(),
    .c0_sys_clk_p(c0_sys_clk_p),
    .c0_sys_clk_n(c0_sys_clk_n),
    .dbg_bus(),
    .c0_ddr4_adr(c0_ddr4_adr),
    .c0_ddr4_ba(c0_ddr4_ba),
    .c0_ddr4_cke(c0_ddr4_cke),
    .c0_ddr4_cs_n(c0_ddr4_cs_n),
    .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n),
    .c0_ddr4_dq(c0_ddr4_dq),
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
    .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
    .c0_ddr4_odt(c0_ddr4_odt),
    .c0_ddr4_bg(c0_ddr4_bg),
    .c0_ddr4_reset_n(c0_ddr4_reset_n),
    .c0_ddr4_act_n(c0_ddr4_act_n),
    .c0_ddr4_ck_c(c0_ddr4_ck_c),
    .c0_ddr4_ck_t(c0_ddr4_ck_t),
    .c0_ddr4_ui_clk(c0_ddr4_ui_clk),
    .c0_ddr4_ui_clk_sync_rst(c0_ddr4_ui_clk_sync_rst),
    .c0_ddr4_aresetn(mig_axi_resetn),
    .c0_ddr4_s_axi_ctrl_awvalid(1'b0),
    .c0_ddr4_s_axi_ctrl_awready(),
    .c0_ddr4_s_axi_ctrl_awaddr(32'd0),
    .c0_ddr4_s_axi_ctrl_wvalid(1'b0),
    .c0_ddr4_s_axi_ctrl_wready(),
    .c0_ddr4_s_axi_ctrl_wdata(32'd0),
    .c0_ddr4_s_axi_ctrl_bvalid(),
    .c0_ddr4_s_axi_ctrl_bready(1'b1),
    .c0_ddr4_s_axi_ctrl_bresp(),
    .c0_ddr4_s_axi_ctrl_arvalid(1'b0),
    .c0_ddr4_s_axi_ctrl_arready(),
    .c0_ddr4_s_axi_ctrl_araddr(32'd0),
    .c0_ddr4_s_axi_ctrl_rvalid(),
    .c0_ddr4_s_axi_ctrl_rready(1'b1),
    .c0_ddr4_s_axi_ctrl_rdata(),
    .c0_ddr4_s_axi_ctrl_rresp(),
    .c0_ddr4_interrupt(c0_ddr4_interrupt),
    .c0_ddr4_s_axi_awid(4'd0),
    .c0_ddr4_s_axi_awaddr(mig_awaddr),
    .c0_ddr4_s_axi_awlen(mig_awlen),
    .c0_ddr4_s_axi_awsize(mig_awsize),
    .c0_ddr4_s_axi_awburst(mig_awburst),
    .c0_ddr4_s_axi_awlock(mig_awlock),
    .c0_ddr4_s_axi_awcache(mig_awcache),
    .c0_ddr4_s_axi_awprot(mig_awprot),
    .c0_ddr4_s_axi_awqos(mig_awqos),
    .c0_ddr4_s_axi_awvalid(mig_awvalid),
    .c0_ddr4_s_axi_awready(mig_awready),
    .c0_ddr4_s_axi_wdata(mig_wdata),
    .c0_ddr4_s_axi_wstrb(mig_wstrb),
    .c0_ddr4_s_axi_wlast(mig_wlast),
    .c0_ddr4_s_axi_wvalid(mig_wvalid),
    .c0_ddr4_s_axi_wready(mig_wready),
    .c0_ddr4_s_axi_bready(mig_bready),
    .c0_ddr4_s_axi_bid(mig_bid_unused),
    .c0_ddr4_s_axi_bresp(mig_bresp),
    .c0_ddr4_s_axi_bvalid(mig_bvalid),
    .c0_ddr4_s_axi_arid(mig_arid),
    .c0_ddr4_s_axi_araddr(mig_araddr),
    .c0_ddr4_s_axi_arlen(mig_arlen),
    .c0_ddr4_s_axi_arsize(mig_arsize),
    .c0_ddr4_s_axi_arburst(mig_arburst),
    .c0_ddr4_s_axi_arlock(mig_arlock),
    .c0_ddr4_s_axi_arcache(mig_arcache),
    .c0_ddr4_s_axi_arprot(mig_arprot),
    .c0_ddr4_s_axi_arqos(mig_arqos),
    .c0_ddr4_s_axi_arvalid(mig_arvalid),
    .c0_ddr4_s_axi_arready(mig_arready),
    .c0_ddr4_s_axi_rready(mig_rready),
    .c0_ddr4_s_axi_rlast(mig_rlast),
    .c0_ddr4_s_axi_rvalid(mig_rvalid),
    .c0_ddr4_s_axi_rresp(mig_rresp),
    .c0_ddr4_s_axi_rid(mig_rid),
    .c0_ddr4_s_axi_rdata(mig_rdata),
    .sys_rst(mig_sys_rst)
  );

endmodule
