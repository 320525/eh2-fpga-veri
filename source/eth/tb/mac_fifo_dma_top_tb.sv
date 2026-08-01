`timescale 1ps / 1ps

// Receive-to-MIG-AXI interface testbench.
//
// AXI Traffic Generator System Init first configures the TEMAC, including a
// second automatic configuration pass after a simulated global reset.  Ten
// accepted and three rejected 1 Gb/s RGMII frames are then injected into
// mac_fifo_dma_ddr4_top in an interleaved sequence.
// Each frame contains a 14-byte Ethernet header, a 1024-byte payload and a
// valid FCS.  The first 64 payload bits (8 bytes) are FF and all remaining
// payload bytes are 00.  To keep simulation fast, the DDR4 memory model and physical
// pin checks are intentionally omitted.  The testbench supplies the MIG-side
// AXI ready/response behavior and checks the 512-bit AXI stream immediately
// before it enters the MIG.
module mac_fifo_dma_top_tb;

  localparam integer PAYLOAD_BYTES       = 1024;
  localparam integer HEADER_BYTES        = 14;
  localparam integer FRAME_BYTES         = HEADER_BYTES + PAYLOAD_BYTES;
  localparam integer FRAME_COUNT         = 10;
  localparam integer MIG_BEATS_PER_FRAME = PAYLOAD_BYTES / 64;

  reg gtx_clk     = 1'b0;
  reg s_axi_aclk  = 1'b0;
  reg refclk      = 1'b0;
  reg rgmii_rxc   = 1'b0;
  reg c0_sys_clk  = 1'b0;
  reg mig_ui_clk  = 1'b0;

  wire c0_sys_clk_p  = c0_sys_clk;
  wire c0_sys_clk_n  = ~c0_sys_clk;

  reg  sw3_1 = 1'b0;
  reg  sw4_1 = 1'b0;
  wire system_resetn_tb = sw3_1 & sw4_1;
  wire rx_fifo_resetn   = system_resetn_tb;

  reg  [3:0] rgmii_rxd    = 4'h0;
  reg        rgmii_rx_ctl = 1'b0;
  wire       rgmii_rxc_delayed;

  wire [3:0] rgmii_txd;
  wire       rgmii_tx_ctl;
  wire       rgmii_txc;
  tri        mdio;
  wire       mdc;

  wire        rx_mac_aclk;
  wire        rx_reset;
  wire [27:0] rx_statistics_vector;
  wire        rx_statistics_valid;
  wire        tx_mac_aclk;
  wire        tx_reset;
  wire [31:0] tx_statistics_vector;
  wire        tx_statistics_valid;
  wire [3:0]  rx_fifo_status;
  wire        rx_fifo_overflow;

  reg  [11:0] s_axi_awaddr  = 12'h000;
  reg         s_axi_awvalid = 1'b0;
  wire        s_axi_awready;
  reg  [31:0] s_axi_wdata   = 32'h0000_0000;
  reg         s_axi_wvalid  = 1'b0;
  wire        s_axi_wready;
  wire [1:0]  s_axi_bresp;
  wire        s_axi_bvalid;
  reg         s_axi_bready  = 1'b0;
  reg  [11:0] s_axi_araddr  = 12'h000;
  reg         s_axi_arvalid = 1'b0;
  wire        s_axi_arready;
  wire [31:0] s_axi_rdata;
  wire [1:0]  s_axi_rresp;
  wire        s_axi_rvalid;
  reg         s_axi_rready  = 1'b0;

  wire       inband_link_status;
  wire [1:0] inband_clock_speed;
  wire       inband_duplex_status;
  wire       mac_irq;
  wire        mac_config_done   = dut.mac_config_done;
  wire        mac_config_error  = dut.mac_config_error;
  wire [31:0] mac_config_status = dut.mac_config_status;

  // DDR4 physical pins are left without a memory model in this AXI-level TB.
  wire        c0_ddr4_act_n;
  wire [16:0] c0_ddr4_adr;
  wire [1:0]  c0_ddr4_ba;
  wire [1:0]  c0_ddr4_bg;
  wire [0:0]  c0_ddr4_cke;
  wire [0:0]  c0_ddr4_odt;
  wire [0:0]  c0_ddr4_cs_n;
  wire [0:0]  c0_ddr4_ck_t;
  wire [0:0]  c0_ddr4_ck_c;
  wire        c0_ddr4_reset_n;
  tri  [8:0]  c0_ddr4_dm_dbi_n;
  tri  [71:0] c0_ddr4_dq;
  tri  [8:0]  c0_ddr4_dqs_c;
  tri  [8:0]  c0_ddr4_dqs_t;

  wire c0_init_calib_complete;
  wire c0_ddr4_ui_clk;
  wire c0_ddr4_ui_clk_sync_rst;
  wire c0_ddr4_interrupt;
  wire dma_memory_ready;

  wire [31:0] received_frame_count;
  wire [31:0] dma_write_addr;
  wire        frame_done;
  wire        dma_done;
  wire        dma_error;
  wire        frame_length_error;
  wire [31:0] last_dma_status;
  wire        dma_busy;
  wire        s2mm_err;
  wire [3:0]  led_t;

  // MIG-side AXI signals are monitored hierarchically.  They remain internal
  // hardware signals and are not added to the synthesizable top-level ports.
  wire [32:0]  mig_awaddr_mon  = dut.mig_awaddr;
  wire [7:0]   mig_awlen_mon   = dut.mig_awlen;
  wire [2:0]   mig_awsize_mon  = dut.mig_awsize;
  wire [1:0]   mig_awburst_mon = dut.mig_awburst;
  wire         mig_awvalid_mon = dut.mig_awvalid;
  wire         mig_awready_mon = dut.mig_awready;
  wire [511:0] mig_wdata_mon   = dut.mig_wdata;
  wire [63:0]  mig_wstrb_mon   = dut.mig_wstrb;
  wire         mig_wlast_mon   = dut.mig_wlast;
  wire         mig_wvalid_mon  = dut.mig_wvalid;
  wire         mig_wready_mon  = dut.mig_wready;
  wire [1:0]   mig_bresp_mon   = dut.mig_bresp;
  wire         mig_bvalid_mon  = dut.mig_bvalid;
  wire         mig_bready_mon  = dut.mig_bready;
  wire [32:0]  mig_araddr_mon  = dut.mig_araddr;
  wire [7:0]   mig_arlen_mon   = dut.mig_arlen;
  wire [2:0]   mig_arsize_mon  = dut.mig_arsize;
  wire [1:0]   mig_arburst_mon = dut.mig_arburst;
  wire         mig_arvalid_mon = dut.mig_arvalid;
  wire         mig_arready_mon = dut.mig_arready;
  wire         mig_rready_mon  = dut.mig_rready;
  wire         ddr_read_done_mon  = dut.ddr_read_done;
  wire         ddr_read_error_mon = dut.ddr_read_error;

  // Observe the write channel after the ATG/external-master selection and
  // immediately before the TEMAC AXI4-Lite slave.
  wire [11:0] mac_cfg_awaddr_mon  = dut.mac_axi_awaddr;
  wire        mac_cfg_awvalid_mon = dut.mac_axi_awvalid;
  wire        mac_cfg_awready_mon = dut.mac_axi_awready;
  wire [31:0] mac_cfg_wdata_mon   = dut.mac_axi_wdata;
  wire        mac_cfg_wvalid_mon  = dut.mac_axi_wvalid;
  wire        mac_cfg_wready_mon  = dut.mac_axi_wready;
  wire [1:0]  mac_cfg_bresp_mon   = dut.mac_axi_bresp;
  wire        mac_cfg_bvalid_mon  = dut.mac_axi_bvalid;
  wire        mac_cfg_bready_mon  = dut.mac_axi_bready;

  // Lightweight AXI write slave used in place of the MIG backend.  These
  // values override only MIG output nets during simulation; synthesizable RTL
  // and the hardware connection to the real MIG remain unchanged.
  reg mig_awready_tb = 1'b1;
  reg mig_wready_tb  = 1'b1;
  reg mig_bvalid_tb  = 1'b0;
  reg mig_arready_tb = 1'b1;
  reg [3:0]   mig_rid_tb   = 4'd0;
  reg [511:0] mig_rdata_tb = {512{1'b1}};
  reg [1:0]   mig_rresp_tb = 2'b00;
  reg         mig_rlast_tb = 1'b1;
  reg         mig_rvalid_tb = 1'b0;
  reg mig_calib_complete_tb = 1'b0;
  reg mig_ui_sync_rst_tb    = 1'b1;

  integer axi_aw_count          = 0;
  integer axi_wbeat_count       = 0;
  integer axi_ar_count          = 0;
  integer axi_error_count       = 0;
  integer backend_error_count   = 0;
  integer config_write_count    = 0;
  integer config_error_count    = 0;
  integer config_sequence_index = 0;
  reg     config_aw_seen        = 1'b0;
  reg     config_w_seen         = 1'b0;

  integer monitor_byte_index;
  integer monitor_frame_offset;
  integer monitor_frame_number;
  reg [7:0] monitor_expected_byte;

  // GTX 125 MHz, AXI-Lite 100 MHz, IDELAY reference 333.333 MHz, RGMII RX
  // 125 MHz, MIG differential reference 76.150 MHz and MIG UI 266.5 MHz.
  always #4000 gtx_clk    = ~gtx_clk;
  always #5000 s_axi_aclk = ~s_axi_aclk;
  always #1500 refclk     = ~refclk;
  always #4000 rgmii_rxc  = ~rgmii_rxc;
  always #6566 c0_sys_clk = ~c0_sys_clk;
  always #1876 mig_ui_clk = ~mig_ui_clk;

  assign #2000 rgmii_rxc_delayed = rgmii_rxc;

  // This legacy datapath testbench injects RGMII frames directly and does not
  // instantiate a serial MDIO PHY model.  Hardware keeps the top-level
  // default (PHY_INIT_BYPASS=0); only this simulation bypasses PHY startup.
  mac_fifo_dma_ddr4_top #(
    .PHY_INIT_BYPASS(1)
  ) dut (
    .sw3_1(sw3_1),
    .sw4_1(sw4_1),
    .gtx_clk_p(gtx_clk),
    .gtx_clk_n(~gtx_clk),
    .refclk_p(refclk),
    .refclk_n(~refclk),
    .rx_mac_aclk(rx_mac_aclk),
    .rx_reset(rx_reset),
    .rx_statistics_vector(rx_statistics_vector),
    .rx_statistics_valid(rx_statistics_valid),
    .rx_fifo_status(rx_fifo_status),
    .rx_fifo_overflow(rx_fifo_overflow),
    .tx_mac_aclk(tx_mac_aclk),
    .tx_reset(tx_reset),
    .tx_ifg_delay(8'h00),
    .tx_statistics_vector(tx_statistics_vector),
    .tx_statistics_valid(tx_statistics_valid),
    .pause_req(1'b0),
    .pause_val(16'h0000),
    .rgmii_txd(rgmii_txd),
    .rgmii_tx_ctl(rgmii_tx_ctl),
    .rgmii_txc(rgmii_txc),
    .rgmii_rxd(rgmii_rxd),
    .rgmii_rx_ctl(rgmii_rx_ctl),
    .rgmii_rxc(rgmii_rxc_delayed),
    .inband_link_status(inband_link_status),
    .inband_clock_speed(inband_clock_speed),
    .inband_duplex_status(inband_duplex_status),
    .mdio(mdio),
    .mdc(mdc),
    .s_axi_aclk_p(s_axi_aclk),
    .s_axi_aclk_n(~s_axi_aclk),
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
    .mac_irq(mac_irq),
    .c0_sys_clk_p(c0_sys_clk_p),
    .c0_sys_clk_n(c0_sys_clk_n),
    .c0_ddr4_act_n(c0_ddr4_act_n),
    .c0_ddr4_adr(c0_ddr4_adr),
    .c0_ddr4_ba(c0_ddr4_ba),
    .c0_ddr4_bg(c0_ddr4_bg),
    .c0_ddr4_cke(c0_ddr4_cke),
    .c0_ddr4_odt(c0_ddr4_odt),
    .c0_ddr4_cs_n(c0_ddr4_cs_n),
    .c0_ddr4_ck_t(c0_ddr4_ck_t),
    .c0_ddr4_ck_c(c0_ddr4_ck_c),
    .c0_ddr4_reset_n(c0_ddr4_reset_n),
    .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n),
    .c0_ddr4_dq(c0_ddr4_dq),
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
    .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
    .c0_init_calib_complete(c0_init_calib_complete),
    .c0_ddr4_ui_clk(c0_ddr4_ui_clk),
    .c0_ddr4_ui_clk_sync_rst(c0_ddr4_ui_clk_sync_rst),
    .c0_ddr4_interrupt(c0_ddr4_interrupt),
    .dma_memory_ready(dma_memory_ready),
    .frame_count(received_frame_count),
    .dma_write_addr(dma_write_addr),
    .frame_done(frame_done),
    .dma_done(dma_done),
    .dma_error(dma_error),
    .frame_length_error(frame_length_error),
    .last_dma_status(last_dma_status),
    .dma_busy(dma_busy),
    .s2mm_err(s2mm_err),
    .led_t(led_t)
  );

  // Accepted frames use destination 02:12:34:56:78:FF.  Rejected frames use
  // 02:12:34:56:78:FE and an A5 payload so an accidental DMA is conspicuous.
  function automatic [7:0] frame_byte;
    input integer frame_number;
    input integer byte_number;
    input integer destination_match;
    integer payload_number;
    begin
      case (byte_number)
        0:  frame_byte = 8'h02;
        1:  frame_byte = 8'h12;
        2:  frame_byte = 8'h34;
        3:  frame_byte = 8'h56;
        4:  frame_byte = 8'h78;
        5:  frame_byte = destination_match ? 8'hFF : 8'hFE;
        6:  frame_byte = 8'h50 + frame_number[7:0];
        7:  frame_byte = 8'h02;
        8:  frame_byte = 8'h03;
        9:  frame_byte = 8'h04;
        10: frame_byte = 8'h05;
        11: frame_byte = 8'h06;
        12: frame_byte = 8'h04;
        13: frame_byte = 8'h00;
        default: begin
          payload_number = byte_number - HEADER_BYTES;
          if (!destination_match)
            frame_byte = 8'hA5;
          else if (payload_number < 8)
            frame_byte = 8'hFF;
          else
            frame_byte = frame_number[7:0];
        end
      endcase
    end
  endfunction

  task automatic calc_crc;
    input [7:0] data;
    inout [31:0] fcs;
    reg [31:0] crc;
    reg crc_feedback;
    integer i;
    begin
      crc = ~fcs;
      for (i = 0; i < 8; i = i + 1) begin
        crc_feedback = crc[0] ^ data[i];
        crc[0]  = crc[1];
        crc[1]  = crc[2];
        crc[2]  = crc[3];
        crc[3]  = crc[4];
        crc[4]  = crc[5];
        crc[5]  = crc[6]  ^ crc_feedback;
        crc[6]  = crc[7];
        crc[7]  = crc[8];
        crc[8]  = crc[9]  ^ crc_feedback;
        crc[9]  = crc[10] ^ crc_feedback;
        crc[10] = crc[11];
        crc[11] = crc[12];
        crc[12] = crc[13];
        crc[13] = crc[14];
        crc[14] = crc[15];
        crc[15] = crc[16] ^ crc_feedback;
        crc[16] = crc[17];
        crc[17] = crc[18];
        crc[18] = crc[19];
        crc[19] = crc[20] ^ crc_feedback;
        crc[20] = crc[21] ^ crc_feedback;
        crc[21] = crc[22] ^ crc_feedback;
        crc[22] = crc[23];
        crc[23] = crc[24] ^ crc_feedback;
        crc[24] = crc[25] ^ crc_feedback;
        crc[25] = crc[26];
        crc[26] = crc[27] ^ crc_feedback;
        crc[27] = crc[28] ^ crc_feedback;
        crc[28] = crc[29];
        crc[29] = crc[30] ^ crc_feedback;
        crc[30] = crc[31] ^ crc_feedback;
        crc[31] = crc_feedback;
      end
      fcs = ~crc;
    end
  endtask

  function automatic [11:0] expected_config_address;
    input integer command_index;
    begin
      case (command_index)
        0: expected_config_address = 12'h410;
        1: expected_config_address = 12'h404;
        2: expected_config_address = 12'h408;
        3: expected_config_address = 12'h500;
        4: expected_config_address = 12'h40C;
        5: expected_config_address = 12'h700;
        6: expected_config_address = 12'h704;
        7: expected_config_address = 12'h708;
        default: expected_config_address = 12'hXXX;
      endcase
    end
  endfunction

  function automatic [31:0] expected_config_data;
    input integer command_index;
    begin
      case (command_index)
        0: expected_config_data = 32'h8000_0000;
        1: expected_config_data = 32'h9000_0000;
        2: expected_config_data = 32'h9000_0000;
        3: expected_config_data = 32'h0000_0068;
        4: expected_config_data = 32'h0000_0000;
        5: expected_config_data = 32'h0403_02DA;
        6: expected_config_data = 32'h0000_0605;
        7: expected_config_data = 32'h8000_0000;
        default: expected_config_data = 32'hXXXX_XXXX;
      endcase
    end
  endfunction

  // ATG sends one AXI4-Lite command at a time.  AW and W are checked
  // independently because AXI does not require the two handshakes to occur in
  // the same cycle.  The command index advances only after the TEMAC BRESP.
  always @(posedge s_axi_aclk) begin
    if (!dut.atg_resetn) begin
      config_sequence_index <= 0;
      config_aw_seen        <= 1'b0;
      config_w_seen         <= 1'b0;
    end
    else if (dut.atg_active) begin
      if (mac_cfg_awvalid_mon && mac_cfg_awready_mon) begin
        if (mac_cfg_awaddr_mon !==
            expected_config_address(config_sequence_index)) begin
          $error("ATG TEMAC AWADDR mismatch: command=%0d expected=%h actual=%h",
                 config_sequence_index,
                 expected_config_address(config_sequence_index),
                 mac_cfg_awaddr_mon);
          config_error_count <= config_error_count + 1;
        end
        config_aw_seen <= 1'b1;
      end

      if (mac_cfg_wvalid_mon && mac_cfg_wready_mon) begin
        if (mac_cfg_wdata_mon !==
            expected_config_data(config_sequence_index)) begin
          $error("ATG TEMAC WDATA mismatch: command=%0d expected=%h actual=%h",
                 config_sequence_index,
                 expected_config_data(config_sequence_index),
                 mac_cfg_wdata_mon);
          config_error_count <= config_error_count + 1;
        end
        if (dut.atg_wstrb !== 4'hF) begin
          $error("ATG TEMAC WSTRB is not full: command=%0d value=%h",
                 config_sequence_index, dut.atg_wstrb);
          config_error_count <= config_error_count + 1;
        end
        config_w_seen <= 1'b1;
      end

      if (mac_cfg_bvalid_mon && mac_cfg_bready_mon) begin
        if (!config_aw_seen || !config_w_seen) begin
          $error("ATG TEMAC BRESP arrived before AW/W were both accepted");
          config_error_count <= config_error_count + 1;
        end
        if (mac_cfg_bresp_mon !== 2'b00) begin
          $error("TEMAC returned non-OKAY BRESP during ATG configuration: %b",
                 mac_cfg_bresp_mon);
          config_error_count <= config_error_count + 1;
        end
        config_write_count <= config_write_count + 1;
        config_sequence_index <= config_sequence_index + 1;
        config_aw_seen <= 1'b0;
        config_w_seen  <= 1'b0;
      end
    end
  end

  task automatic send_frame_1g;
    input integer frame_number;
    input integer destination_match;
    integer nibble_index;
    integer byte_index;
    reg [7:0] data_byte;
    reg [31:0] fcs;
    begin
      fcs = 32'h0000_0000;
      @(posedge rgmii_rxc);

      // Seven-byte preamble followed by SFD 0xD5.
      for (nibble_index = 0;
           nibble_index < 14;
           nibble_index = nibble_index + 1) begin
        rgmii_rxd    <= 4'h5;
        rgmii_rx_ctl <= 1'b1;
        @(rgmii_rxc);
      end
      rgmii_rxd    <= 4'h5;
      rgmii_rx_ctl <= 1'b1;
      @(rgmii_rxc);
      rgmii_rxd    <= 4'hD;
      rgmii_rx_ctl <= 1'b1;
      @(rgmii_rxc);

      for (byte_index = 0;
           byte_index < FRAME_BYTES;
           byte_index = byte_index + 1) begin
        data_byte = frame_byte(frame_number, byte_index, destination_match);
        rgmii_rxd    <= data_byte[3:0];
        rgmii_rx_ctl <= 1'b1;
        @(rgmii_rxc);
        rgmii_rxd    <= data_byte[7:4];
        rgmii_rx_ctl <= 1'b1;
        calc_crc(data_byte, fcs);
        @(rgmii_rxc);
      end

      // Ethernet FCS, least-significant byte first.
      for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1) begin
        rgmii_rxd    <= fcs[(byte_index * 8) +: 4];
        rgmii_rx_ctl <= 1'b1;
        @(rgmii_rxc);
        rgmii_rxd    <= fcs[(byte_index * 8 + 4) +: 4];
        rgmii_rx_ctl <= 1'b1;
        @(rgmii_rxc);
      end

      rgmii_rxd    <= 4'h0;
      rgmii_rx_ctl <= 1'b0;
      repeat (24) @(rgmii_rxc);
    end
  endtask

  // Bypass DDR4 calibration and model only the AXI signals that a ready MIG
  // would return.  The 266.5 MHz clock still exercises the real clock converter
  // and width converter in the DUT.
  initial begin : mig_axi_backend_override
    integer calibration_cycle;

    force dut.c0_ddr4_ui_clk          = mig_ui_clk;
    force dut.c0_init_calib_complete  = mig_calib_complete_tb;
    force dut.c0_ddr4_ui_clk_sync_rst = mig_ui_sync_rst_tb;
    force dut.c0_ddr4_interrupt       = 1'b0;
    force dut.mig_awready             = mig_awready_tb;
    force dut.mig_wready              = mig_wready_tb;
    force dut.mig_bresp               = 2'b00;
    force dut.mig_bvalid              = mig_bvalid_tb;
    force dut.mig_arready             = mig_arready_tb;
    force dut.mig_rid                 = mig_rid_tb;
    force dut.mig_rdata               = mig_rdata_tb;
    force dut.mig_rresp               = mig_rresp_tb;
    force dut.mig_rlast               = mig_rlast_tb;
    force dut.mig_rvalid              = mig_rvalid_tb;

    // Model the essential MIG startup sequence after every board-wide reset.
    // Both 266.5 MHz converters observe reset before calibration is released.
    forever begin
      wait (system_resetn_tb === 1'b1);
      begin : calibration_attempt
        for (calibration_cycle = 0;
             calibration_cycle < 240;
             calibration_cycle = calibration_cycle + 1) begin
          @(posedge mig_ui_clk);
          if (!system_resetn_tb)
            disable calibration_attempt;
        end

        mig_ui_sync_rst_tb    <= 1'b0;
        mig_calib_complete_tb <= 1'b1;
        wait (!system_resetn_tb);
      end

      mig_ui_sync_rst_tb    <= 1'b1;
      mig_calib_complete_tb <= 1'b0;
    end
  end

  // Return the first 512-bit word at DDR byte address zero.  With an all-FF
  // payload this word must be all ones, so the LED checker should light T3.
  always @(posedge mig_ui_clk) begin
    if (!rx_fifo_resetn) begin
      mig_rvalid_tb <= 1'b0;
      axi_ar_count  <= 0;
    end
    else begin
      if (mig_rvalid_tb && mig_rready_mon)
        mig_rvalid_tb <= 1'b0;

      if (mig_arvalid_mon && mig_arready_mon) begin
        if ((mig_araddr_mon !== 33'd0) ||
            (mig_arlen_mon !== 8'd0) ||
            (mig_arsize_mon !== 3'd6) ||
            (mig_arburst_mon !== 2'b01)) begin
          $error("Unexpected MIG read command: addr=%h len=%0d size=%0d burst=%b",
                 mig_araddr_mon, mig_arlen_mon, mig_arsize_mon,
                 mig_arburst_mon);
          backend_error_count <= backend_error_count + 1;
        end
        if (mig_rvalid_tb) begin
          $error("MIG read model received a second AR while RVALID was pending");
          backend_error_count <= backend_error_count + 1;
        end
        axi_ar_count  <= axi_ar_count + 1;
        mig_rid_tb    <= 4'd0;
        mig_rdata_tb  <= {512{1'b1}};
        mig_rresp_tb  <= 2'b00;
        mig_rlast_tb  <= 1'b1;
        mig_rvalid_tb <= 1'b1;
      end
    end
  end

  // Return one OKAY response after the last accepted beat of each burst.
  always @(posedge mig_ui_clk) begin
    if (!rx_fifo_resetn) begin
      mig_bvalid_tb <= 1'b0;
    end
    else begin
      if (mig_bvalid_tb && mig_bready_mon)
        mig_bvalid_tb <= 1'b0;

      if (mig_wvalid_mon && mig_wready_mon && mig_wlast_mon) begin
        if (mig_bvalid_tb && !mig_bready_mon) begin
          $error("A new MIG write completed before the prior BRESP was accepted");
          backend_error_count <= backend_error_count + 1;
        end
        mig_bvalid_tb <= 1'b1;
      end
    end
  end

  // Verify the address conversion, burst fields and every byte entering MIG.
  always @(posedge c0_ddr4_ui_clk) begin
    if (!rx_fifo_resetn) begin
      axi_aw_count        <= 0;
      axi_wbeat_count     <= 0;
      axi_error_count     <= 0;
    end
    else begin
      if (mig_awvalid_mon && mig_awready_mon) begin
        if (mig_awaddr_mon !==
            {1'b0, (axi_aw_count * 32'h0000_0400)}) begin
          $error("Unexpected MIG AWADDR: burst=%0d actual=%h",
                 axi_aw_count, mig_awaddr_mon);
          axi_error_count <= axi_error_count + 1;
        end
        if ((mig_awlen_mon   !== 8'd15) ||
            (mig_awsize_mon  !== 3'd6)  ||
            (mig_awburst_mon !== 2'b01)) begin
          $error("Unexpected MIG burst fields: len=%0d size=%0d burst=%b",
                 mig_awlen_mon, mig_awsize_mon, mig_awburst_mon);
          axi_error_count <= axi_error_count + 1;
        end
        axi_aw_count <= axi_aw_count + 1;
      end

      if (mig_wvalid_mon && mig_wready_mon) begin
        monitor_frame_offset =
          (axi_wbeat_count % MIG_BEATS_PER_FRAME) * 64;
        monitor_frame_number = axi_wbeat_count / MIG_BEATS_PER_FRAME;

        if (mig_wstrb_mon !== 64'hFFFF_FFFF_FFFF_FFFF) begin
          $error("MIG WSTRB is not full at beat %0d: %h",
                 axi_wbeat_count, mig_wstrb_mon);
          axi_error_count <= axi_error_count + 1;
        end

        if (mig_wlast_mon !==
            ((axi_wbeat_count % MIG_BEATS_PER_FRAME) ==
             (MIG_BEATS_PER_FRAME - 1))) begin
          $error("Unexpected MIG WLAST at beat %0d", axi_wbeat_count);
          axi_error_count <= axi_error_count + 1;
        end

        for (monitor_byte_index = 0;
             monitor_byte_index < 64;
             monitor_byte_index = monitor_byte_index + 1) begin
          if ((monitor_frame_offset + monitor_byte_index) < 8)
            monitor_expected_byte = 8'hFF;
          else
            monitor_expected_byte = monitor_frame_number[7:0];

          if (mig_wdata_mon[(monitor_byte_index * 8) +: 8] !==
              monitor_expected_byte) begin
            $error("MIG data mismatch: beat=%0d byte=%0d expected=%02h actual=%02h",
                   axi_wbeat_count, monitor_byte_index,
                   monitor_expected_byte,
                   mig_wdata_mon[(monitor_byte_index * 8) +: 8]);
            axi_error_count <= axi_error_count + 1;
          end
        end

        axi_wbeat_count <= axi_wbeat_count + 1;
      end

      if (mig_bvalid_mon && (mig_bresp_mon !== 2'b00)) begin
        $error("MIG returned non-OKAY BRESP: %b", mig_bresp_mon);
        axi_error_count <= axi_error_count + 1;
      end
    end
  end

  initial begin : stimulus
    integer frame_index;

    // Match led_test: both board switches must be high to release every block.
    #400_000;
    sw3_1 <= 1'b1;
    sw4_1 <= 1'b1;

    // External AXI-Lite stimulus remains idle.  The ATG must autonomously
    // issue the same eight writes formerly made by axi_write tasks.
    wait (mac_config_done);
    repeat (2) @(posedge s_axi_aclk);
    if (mac_config_error || (config_write_count != 8))
      $fatal(1, "Initial ATG configuration failed: writes=%0d status=%h",
             config_write_count, mac_config_status);

    // Exercise automatic replay using the same board-wide reset source.
    $display("Initial ATG TEMAC configuration complete; testing reset replay");
    sw3_1 <= 1'b0;
    wait (!mac_config_done);
    repeat (20) @(posedge s_axi_aclk);
    sw3_1 <= 1'b1;
    wait (mac_config_done);
    repeat (2) @(posedge s_axi_aclk);
    if (mac_config_error || (config_write_count != 16))
      $fatal(1, "ATG reset replay failed: writes=%0d status=%h",
             config_write_count, mac_config_status);

    $display("Waiting for simulated MIG AXI backend...");
    wait (c0_init_calib_complete && dma_memory_ready);
    $display("MIG AXI backend ready at %0t ps", $time);

    repeat (100) @(posedge gtx_clk);
    $display("Injecting rejected RGMII frame before accepted traffic");
    send_frame_1g(100, 0);
    repeat (100) @(posedge gtx_clk);
    if ((received_frame_count != 0) || (axi_aw_count != 0) || led_t[0])
      $fatal(1, "Rejected frame started DMA or lit LED-T1");

    for (frame_index = 0;
         frame_index < FRAME_COUNT;
         frame_index = frame_index + 1) begin
      $display("Injecting RGMII frame %0d at %0t ps", frame_index, $time);
      send_frame_1g(frame_index, 1);
      if (frame_index == 3)
        send_frame_1g(101, 0);
      if (frame_index == 7)
        send_frame_1g(102, 0);
    end

    wait (received_frame_count == FRAME_COUNT);
    wait (!dma_busy);
    wait ((axi_aw_count == FRAME_COUNT) &&
          (axi_wbeat_count == (FRAME_COUNT * MIG_BEATS_PER_FRAME)));
    wait (ddr_read_done_mon);
    repeat (20) @(posedge c0_ddr4_ui_clk);

    if (axi_aw_count != FRAME_COUNT)
      $fatal(1, "Expected %0d MIG AW bursts, observed %0d",
             FRAME_COUNT, axi_aw_count);
    if (axi_wbeat_count != (FRAME_COUNT * MIG_BEATS_PER_FRAME))
      $fatal(1, "Expected %0d MIG W beats, observed %0d",
             FRAME_COUNT * MIG_BEATS_PER_FRAME, axi_wbeat_count);
    if (dma_write_addr != (FRAME_COUNT * 32'h0000_0400))
      $fatal(1, "Rejected frames created a DDR address gap: next=%h",
             dma_write_addr);
    if (axi_error_count != 0)
      $fatal(1, "MIG AXI comparison reported %0d errors", axi_error_count);
    if (backend_error_count != 0)
      $fatal(1, "MIG AXI response model reported %0d errors",
             backend_error_count);
    if (axi_ar_count != 1)
      $fatal(1, "Expected one DDR address-zero read, observed %0d",
             axi_ar_count);
    if (ddr_read_error_mon)
      $fatal(1, "DDR address-zero read checker reported an AXI error");
    if (led_t !== 4'hF)
      $fatal(1, "Expected LED-T1..T4 all on, observed led_t=%b", led_t);
    if (config_error_count != 0)
      $fatal(1, "ATG TEMAC configuration comparison reported %0d errors",
             config_error_count);
    if ((config_write_count != 16) || mac_config_error)
      $fatal(1, "Expected two successful ATG configuration passes");
    if (rx_fifo_overflow || dma_error || frame_length_error || s2mm_err)
      $fatal(1, "Receive/DMA error output asserted");

    $display("PASS: 2 ATG configuration passes (%0d writes), %0d accepted and 3 rejected frames, contiguous ordered DDR writes, %0d MIG AXI write bursts, %0d write beats, one DDR readback, LED=%b",
             config_write_count, received_frame_count, axi_aw_count,
             axi_wbeat_count, led_t);
    $finish;
  end

  initial begin : watchdog
    #2_000_000_000;
    $fatal(1, "Simulation timeout before receive-to-DDR4 test completed");
  end

endmodule
