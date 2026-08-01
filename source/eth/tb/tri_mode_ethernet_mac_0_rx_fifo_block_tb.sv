`timescale 1ps / 1ps

// Pure stimulus for tri_mode_ethernet_mac_0_rx_fifo_block.
//
// The testbench configures the MAC in the same 1G receive mode used by the
// generated example design, then injects two consecutive external RGMII frames.
// Each frame contains:
//   6-byte destination address + 6-byte source address + 2-byte length field
//   + 1024-byte payload + externally generated FCS.
//
// No loopback and no automatic FIFO data comparison are implemented.  Observe
// rx_axis_fifo_tdata/tvalid/tlast directly in the simulation waveform.
module tri_mode_ethernet_mac_0_rx_fifo_block_tb;

  localparam integer PAYLOAD_BYTES = 1024;
  localparam integer HEADER_BYTES  = 14;
  localparam integer FRAME_BYTES   = HEADER_BYTES + PAYLOAD_BYTES;

  reg gtx_clk    = 1'b0;
  reg s_axi_aclk = 1'b0;
  reg refclk     = 1'b0;
  reg rgmii_rxc  = 1'b0;

  reg glbl_rstn      = 1'b0;
  reg rx_axi_rstn    = 1'b0;
  reg tx_axi_rstn    = 1'b0;
  reg s_axi_resetn   = 1'b0;
  reg rx_fifo_resetn = 1'b0;

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

  // Signals to inspect in the waveform.
  wire [15:0] rx_axis_fifo_tdata;
  wire        rx_axis_fifo_tvalid;
  wire        rx_axis_fifo_tlast;
  reg         rx_axis_fifo_tready = 1'b0;
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

  // Same clocks as the generated example design:
  // GTX/RX FIFO 125 MHz, AXI-Lite 100 MHz, IDELAY reference 333.333 MHz.
  always #4000 gtx_clk    = ~gtx_clk;
  always #5000 s_axi_aclk = ~s_axi_aclk;
  always #1500 refclk     = ~refclk;
  always #4000 rgmii_rxc  = ~rgmii_rxc;

  // External RGMII input delay used by the generated demo testbench.
  assign #2000 rgmii_rxc_delayed = rgmii_rxc;

  tri_mode_ethernet_mac_0_rx_fifo_block dut (
    .gtx_clk               (gtx_clk),
    .glbl_rstn             (glbl_rstn),
    .rx_axi_rstn           (rx_axi_rstn),
    .tx_axi_rstn           (tx_axi_rstn),
    .refclk                (refclk),

    .rx_mac_aclk           (rx_mac_aclk),
    .rx_reset              (rx_reset),
    .rx_statistics_vector  (rx_statistics_vector),
    .rx_statistics_valid   (rx_statistics_valid),
    .rx_fifo_clock         (gtx_clk),
    .rx_fifo_resetn        (rx_fifo_resetn),
    .rx_axis_fifo_tdata    (rx_axis_fifo_tdata),
    .rx_axis_fifo_tvalid   (rx_axis_fifo_tvalid),
    .rx_axis_fifo_tready   (rx_axis_fifo_tready),
    .rx_axis_fifo_tlast    (rx_axis_fifo_tlast),
    .rx_fifo_status        (rx_fifo_status),
    .rx_fifo_overflow      (rx_fifo_overflow),

    .tx_mac_aclk           (tx_mac_aclk),
    .tx_reset              (tx_reset),
    .tx_ifg_delay          (8'h00),
    .tx_statistics_vector  (tx_statistics_vector),
    .tx_statistics_valid   (tx_statistics_valid),
    .pause_req             (1'b0),
    .pause_val             (16'h0000),

    .rgmii_txd             (rgmii_txd),
    .rgmii_tx_ctl          (rgmii_tx_ctl),
    .rgmii_txc             (rgmii_txc),
    .rgmii_rxd             (rgmii_rxd),
    .rgmii_rx_ctl          (rgmii_rx_ctl),
    .rgmii_rxc             (rgmii_rxc_delayed),
    .inband_link_status    (inband_link_status),
    .inband_clock_speed    (inband_clock_speed),
    .inband_duplex_status  (inband_duplex_status),
    .mdio                  (mdio),
    .mdc                   (mdc),

    .s_axi_aclk            (s_axi_aclk),
    .s_axi_resetn          (s_axi_resetn),
    .s_axi_awaddr          (s_axi_awaddr),
    .s_axi_awvalid         (s_axi_awvalid),
    .s_axi_awready         (s_axi_awready),
    .s_axi_wdata           (s_axi_wdata),
    .s_axi_wvalid          (s_axi_wvalid),
    .s_axi_wready          (s_axi_wready),
    .s_axi_bresp           (s_axi_bresp),
    .s_axi_bvalid          (s_axi_bvalid),
    .s_axi_bready          (s_axi_bready),
    .s_axi_araddr          (s_axi_araddr),
    .s_axi_arvalid         (s_axi_arvalid),
    .s_axi_arready         (s_axi_arready),
    .s_axi_rdata           (s_axi_rdata),
    .s_axi_rresp           (s_axi_rresp),
    .s_axi_rvalid          (s_axi_rvalid),
    .s_axi_rready          (s_axi_rready),
    .mac_irq               (mac_irq)
  );

  // Frame 0 payload is 00,01,...,FF repeated four times.
  // Frame 1 payload is the same counter XORed with A5, making the two frames
  // easy to distinguish in the FIFO waveform.
  function automatic [7:0] frame_byte;
    input integer frame_number;
    input integer byte_number;
    integer payload_number;
    begin
      case (byte_number)
        0:  frame_byte = 8'hDA;
        1:  frame_byte = 8'h02;
        2:  frame_byte = 8'h03;
        3:  frame_byte = 8'h04;
        4:  frame_byte = 8'h05;
        5:  frame_byte = 8'h06;
        6:  frame_byte = (frame_number == 0) ? 8'h5A : 8'h6A;
        7:  frame_byte = 8'h02;
        8:  frame_byte = 8'h03;
        9:  frame_byte = 8'h04;
        10: frame_byte = 8'h05;
        11: frame_byte = 8'h06;
        12: frame_byte = 8'h04;
        13: frame_byte = 8'h00;
        default: begin
          payload_number = byte_number - HEADER_BYTES;
          if (frame_number == 0)
            frame_byte = payload_number[7:0];
          else
            frame_byte = payload_number[7:0] ^ 8'hA5;
        end
      endcase
    end
  endfunction

  // CRC/FCS calculation from tri_mode_ethernet_mac_0_ex/imports/demo_tb.v.
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

  task automatic axi_write;
    input [11:0] address;
    input [31:0] data;
    reg aw_done;
    reg w_done;
    begin
      aw_done = 1'b0;
      w_done  = 1'b0;
      @(posedge s_axi_aclk);
      s_axi_awaddr  <= address;
      s_axi_awvalid <= 1'b1;
      s_axi_wdata   <= data;
      s_axi_wvalid  <= 1'b1;

      while (!aw_done || !w_done) begin
        @(posedge s_axi_aclk);
        if (!aw_done && s_axi_awready) begin
          aw_done = 1'b1;
          s_axi_awvalid <= 1'b0;
        end
        if (!w_done && s_axi_wready) begin
          w_done = 1'b1;
          s_axi_wvalid <= 1'b0;
        end
      end

      s_axi_bready <= 1'b1;
      while (!s_axi_bvalid)
        @(posedge s_axi_aclk);
      @(posedge s_axi_aclk);
      s_axi_bready <= 1'b0;
    end
  endtask

  task automatic send_frame_1g;
    input integer frame_number;
    integer nibble_index;
    integer byte_index;
    reg [7:0] data_byte;
    reg [31:0] fcs;
    begin
      fcs = 32'h0000_0000;
      @(posedge rgmii_rxc);

      // Seven-byte preamble and SFD 0xD5.
      for (nibble_index = 0; nibble_index < 14; nibble_index = nibble_index + 1) begin
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

      for (byte_index = 0; byte_index < FRAME_BYTES; byte_index = byte_index + 1) begin
        data_byte = frame_byte(frame_number, byte_index);
        rgmii_rxd    <= data_byte[3:0];
        rgmii_rx_ctl <= 1'b1;
        @(rgmii_rxc);
        rgmii_rxd    <= data_byte[7:4];
        rgmii_rx_ctl <= 1'b1;
        calc_crc(data_byte, fcs);
        @(rgmii_rxc);
      end

      // FCS, least-significant byte first.
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

      // Minimum 96-bit Ethernet inter-frame gap.
      repeat (24) @(rgmii_rxc);
    end
  endtask

  // Start reading only after both external frames have been received.  Keep
  // ready asserted until two complete frames (two accepted tlast beats) have
  // been drained from the FIFO.  No payload comparison is performed here.
  task automatic drain_rx_fifo;
    integer completed_frames;
    integer accepted_beats;
    begin
      completed_frames = 0;
      accepted_beats   = 0;
      @(posedge gtx_clk);
      rx_axis_fifo_tready <= 1'b1;

      while (completed_frames < 2) begin
        @(posedge gtx_clk);
        if (rx_axis_fifo_tvalid && rx_axis_fifo_tready) begin
          accepted_beats = accepted_beats + 1;
          if (rx_axis_fifo_tlast) begin
            completed_frames = completed_frames + 1;
            $display("RX FIFO frame %0d read complete at %0t ps",
                     completed_frames, $time);
          end
        end
      end

      @(posedge gtx_clk);
      rx_axis_fifo_tready <= 1'b0;
      $display("RX FIFO drain complete: %0d accepted 16-bit beats", accepted_beats);
    end
  endtask

  initial begin : stimulus
    // Same 400 ns reset pulse used by the generated demo testbench.
    #400_000;
    glbl_rstn   <= 1'b1;
    rx_axi_rstn <= 1'b1;
    tx_axi_rstn <= 1'b1;
    repeat (20) @(posedge s_axi_aclk);
    s_axi_resetn   <= 1'b1;
    rx_fifo_resetn <= 1'b1;

    // Same 1G MAC register values used by the example AXI-Lite state machine.
    axi_write(12'h410, 32'h8000_0000); // 1 Gb/s
    axi_write(12'h404, 32'h9000_0000); // reset/enable receiver
    axi_write(12'h408, 32'h9000_0000); // reset/enable transmitter
    axi_write(12'h500, 32'h0000_0068); // management clock configuration
    axi_write(12'h40C, 32'h0000_0000); // disable flow control
    axi_write(12'h700, 32'h0403_02DA); // unicast address low
    axi_write(12'h704, 32'h0000_0605); // unicast address high
    axi_write(12'h708, 32'h8000_0000); // promiscuous receive mode

    repeat (100) @(posedge gtx_clk);
    $display("Injecting RGMII frame 0: 1024-byte counter payload");
    send_frame_1g(0);
    $display("Injecting RGMII frame 1: 1024-byte counter-XOR-A5 payload");
    send_frame_1g(1);

    // Allow the MAC/FIFO write pipeline to settle, then read until both frames
    // have produced an accepted tlast beat.
    repeat (32) @(posedge gtx_clk);
    $display("RGMII receive stimulus complete; starting RX FIFO read stimulus");
    drain_rx_fifo();
    repeat (20) @(posedge gtx_clk);
    $display("Stimulus complete; all RX FIFO frame data has been read");
    $finish;
  end

endmodule
