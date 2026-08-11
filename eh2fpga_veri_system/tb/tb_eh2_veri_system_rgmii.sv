`timescale 1ns/1ps
`include "stress_200k_program_params.svh"

module tb_eh2_veri_system_rgmii;
  import eh2_system_pkg::*;

  localparam integer PROGRAM_RX_FRAME_BYTES = 1042;
  localparam integer LOG_FRAME_BYTES = 1038;
  localparam integer INFO_FRAME_BYTES = 60;
  localparam integer PROGRAM_IMAGE_FRAMES =
      `STRESS_PROGRAM_FRAME_COUNT;
  localparam integer PROGRAM_IMAGE_WORDS =
      `STRESS_PROGRAM_WORD_COUNT;

  logic core_clk = 1'b0;
  logic ctrl_clk = 1'b0;
  logic refclk = 1'b0;
  logic rgmii_rx_clock = 1'b0;
  logic ddr_ref_clk = 1'b0;
  wire rgmii_rxc_delayed;

  logic sw3_1 = 1'b0;
  logic sw4_1 = 1'b0;
  logic [3:0] rgmii_rxd = 4'b0;
  logic rgmii_rx_ctl = 1'b0;
  wire [3:0] rgmii_txd;
  wire rgmii_tx_ctl, rgmii_txc;
  tri mdio;
  wire mdc, phy_resetn;
  wire [7:0] led;

  wire c0_ddr4_act_n;
  wire [16:0] c0_ddr4_adr;
  wire [1:0] c0_ddr4_ba, c0_ddr4_bg;
  wire [0:0] c0_ddr4_cke, c0_ddr4_odt, c0_ddr4_cs_n;
  wire [0:0] c0_ddr4_ck_t, c0_ddr4_ck_c;
  wire c0_ddr4_reset_n;
  tri [8:0] c0_ddr4_dm_dbi_n;
  tri [71:0] c0_ddr4_dq;
  tri [8:0] c0_ddr4_dqs_c, c0_ddr4_dqs_t;

  wire c1_ddr4_act_n;
  wire [16:0] c1_ddr4_adr;
  wire [1:0] c1_ddr4_ba, c1_ddr4_bg;
  wire [0:0] c1_ddr4_cke, c1_ddr4_odt, c1_ddr4_cs_n;
  wire [0:0] c1_ddr4_ck_t, c1_ddr4_ck_c;
  wire c1_ddr4_reset_n;
  tri [8:0] c1_ddr4_dm_dbi_n;
  tri [71:0] c1_ddr4_dq;
  tri [8:0] c1_ddr4_dqs_c, c1_ddr4_dqs_t;

  logic [15:0] program_words [0:PROGRAM_IMAGE_WORDS-1];
  logic [7:0] tx_bytes [0:1100];
  integer tx_byte_count = 0;
  integer tx_frame_count = 0;
  integer tx_log_frame_count = 0;
  integer tx_info_frame_count = 0;
  integer ready_frame_count = 0;
  integer tx_file;
  integer rgmii_tx_active_cycles = 0;
  integer execute_progress_cycles = 0;
  integer preconfig_dma_diag_cycles = 0;
  integer min_ifg_gap_count = 0;
  integer burst_raw_mac_bytes = 0;
  integer burst_raw_good_frames = 0;
  integer burst_raw_bad_frames = 0;
  integer burst_fifo_words = 0;
  time last_rgmii_frame_edge = 0;
  logic saw_rx_fifo_overflow = 1'b0;
  logic saw_rx_classifier_overflow = 1'b0;
  logic saw_rx_length_error = 1'b0;
  logic saw_preinit = 1'b0;
  logic saw_check_pass = 1'b0;
  logic saw_ready = 1'b0;
  logic saw_program_done = 1'b0;
  logic [3:0] saw_hart_status = 4'b0;
  integer program_start_count = 0;
  integer receive_done_count = 0;
  logic saw_eh2_done = 1'b0;
  logic saw_exe_end = 1'b0;
  logic saw_hartstart_csr = 1'b0;
  logic saw_hart1_first_commit = 1'b0;
  logic saw_preconfig_end_marker = 1'b0;
  logic saw_program_end_marker = 1'b0;
  logic state_trace_started = 1'b0;
  logic [5:0] state_visit = 6'b0;
  system_state_t previous_state = ST_PRECONFIG;

  always #10 core_clk = ~core_clk;
  always #5 ctrl_clk = ~ctrl_clk;
  always #1.5 refclk = ~refclk;
  always #4 rgmii_rx_clock = ~rgmii_rx_clock;
  always #6.566 ddr_ref_clk = ~ddr_ref_clk;
  assign #2 rgmii_rxc_delayed = rgmii_rx_clock;

  eh2_veri_system_top #(
    .PHY_INIT_BYPASS(1),
    .DATA_CLEAR_BYTES(33'h0_0010_0000)
  ) dut (
    .sw3_1, .sw4_1,
    .core_clk_p(core_clk), .core_clk_n(~core_clk),
    .atg_clk_p(ctrl_clk), .atg_clk_n(~ctrl_clk),
    .refclk_p(refclk), .refclk_n(~refclk),
    .led,
    .rgmii_txd, .rgmii_tx_ctl, .rgmii_txc,
    .rgmii_rxd, .rgmii_rx_ctl, .rgmii_rxc(rgmii_rxc_delayed),
    .mdio, .mdc, .phy_resetn,
    .c0_sys_clk_p(ddr_ref_clk), .c0_sys_clk_n(~ddr_ref_clk),
    .c0_ddr4_act_n, .c0_ddr4_adr, .c0_ddr4_ba, .c0_ddr4_bg,
    .c0_ddr4_cke, .c0_ddr4_odt, .c0_ddr4_cs_n,
    .c0_ddr4_ck_t, .c0_ddr4_ck_c, .c0_ddr4_reset_n,
    .c0_ddr4_dm_dbi_n, .c0_ddr4_dq, .c0_ddr4_dqs_c, .c0_ddr4_dqs_t,
    .c1_sys_clk_p(ddr_ref_clk), .c1_sys_clk_n(~ddr_ref_clk),
    .c1_ddr4_act_n, .c1_ddr4_adr, .c1_ddr4_ba, .c1_ddr4_bg,
    .c1_ddr4_cke, .c1_ddr4_odt, .c1_ddr4_cs_n,
    .c1_ddr4_ck_t, .c1_ddr4_ck_c, .c1_ddr4_reset_n,
    .c1_ddr4_dm_dbi_n, .c1_ddr4_dq, .c1_ddr4_dqs_c, .c1_ddr4_dqs_t
  );

  task automatic calc_crc(input [7:0] data_byte, inout [31:0] fcs);
    integer bit_index;
    reg [31:0] crc;
    begin
      // Ethernet CRC-32 is reflected on the wire.  This is equivalent to
      // the bit-by-bit task in mac_fifo_dma_proj's verified RGMII testbench.
      crc = ~fcs;
      for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
        if (crc[0] ^ data_byte[bit_index])
          crc = (crc >> 1) ^ 32'hEDB8_8320;
        else
          crc = crc >> 1;
      end
      fcs = ~crc;
    end
  endtask

  function automatic [7:0] program_byte(input integer byte_index);
    program_byte = program_words[byte_index >> 1][
      ((byte_index & 1) * 8) +: 8
    ];
  endfunction

  function automatic [7:0] preconfig_program_byte(input integer byte_index);
    begin
      case (byte_index)
        0: preconfig_program_byte = 8'h02;
        1: preconfig_program_byte = 8'h12;
        2: preconfig_program_byte = 8'h34;
        3: preconfig_program_byte = 8'h56;
        4: preconfig_program_byte = 8'h78;
        5: preconfig_program_byte = 8'hff;
        6: preconfig_program_byte = 8'h02;
        7: preconfig_program_byte = 8'h32;
        8: preconfig_program_byte = 8'h05;
        9: preconfig_program_byte = 8'h25;
        10: preconfig_program_byte = 8'h00;
        11: preconfig_program_byte = 8'hfe;
        12: preconfig_program_byte = 8'h88;
        13: preconfig_program_byte = 8'hb6;
        14, 15, 16, 17: preconfig_program_byte = 8'h00;
        default: preconfig_program_byte = 8'hff;
      endcase
    end
  endfunction

  function automatic [7:0] info_end_byte(
    input integer byte_index,
    input integer total_frames
  );
    begin
      case (byte_index)
        0: info_end_byte = 8'h02;
        1: info_end_byte = 8'h32;
        2: info_end_byte = 8'h05;
        3: info_end_byte = 8'h25;
        4: info_end_byte = 8'h00;
        5: info_end_byte = 8'hff;
        6: info_end_byte = 8'h02;
        7: info_end_byte = 8'h32;
        8: info_end_byte = 8'h05;
        9: info_end_byte = 8'h25;
        10: info_end_byte = 8'h00;
        11: info_end_byte = 8'hfe;
        12: info_end_byte = 8'h88;
        13: info_end_byte = 8'hb5;
        14, 15, 16, 17: info_end_byte = 8'hff;
        18: info_end_byte = total_frames[31:24];
        19: info_end_byte = total_frames[23:16];
        20: info_end_byte = total_frames[15:8];
        21: info_end_byte = total_frames[7:0];
        default: info_end_byte = 8'h00;
      endcase
    end
  endfunction

  task automatic send_rgmii_frame(
    input integer frame_bytes,
    input integer frame_kind,
    input integer program_frame_index
  );
    integer nibble_index;
    integer byte_index;
    reg [7:0] data_byte;
    reg [31:0] fcs;
    begin
      fcs = 32'h0000_0000;
      // The board TEMAC wrapper's IDDRE1 SAME_EDGE_PIPELINED mapping, together
      // with the delayed receive clock used here, reconstructs the low nibble
      // from the external falling edge and the high nibble from the rising
      // edge. Align every burst to that verified phase; subsequent calls
      // already return on the same phase.
      if (last_rgmii_frame_edge == 0)
        @(posedge rgmii_rx_clock);
      for (nibble_index = 0; nibble_index < 15;
           nibble_index = nibble_index + 1) begin
        rgmii_rxd <= 4'h5;
        rgmii_rx_ctl <= 1'b1;
        if ((nibble_index & 1) == 0)
          @(negedge rgmii_rx_clock);
        else
          @(posedge rgmii_rx_clock);
        if (nibble_index == 0) begin
          if (last_rgmii_frame_edge != 0) begin
            // The valid-edge centers are 100 ns apart: after excluding the
            // two half-nibble symbol halves, RX_CTL is low for exactly the
            // IEEE 802.3 minimum 96 ns (24 DDR nibble slots / 12 bytes).
            if (($time - last_rgmii_frame_edge) != 100ns)
              $fatal(1, "RGMII valid-edge spacing is %0t, expected 100 ns",
                     $time - last_rgmii_frame_edge);
            min_ifg_gap_count = min_ifg_gap_count + 1;
          end
        end
      end
      rgmii_rxd <= 4'hd;
      rgmii_rx_ctl <= 1'b1;
      @(posedge rgmii_rx_clock);

      for (byte_index = 0; byte_index < frame_bytes;
           byte_index = byte_index + 1) begin
        case (frame_kind)
          0: data_byte = preconfig_program_byte(byte_index);
          1: data_byte = program_byte(
               program_frame_index * PROGRAM_RX_FRAME_BYTES + byte_index
             );
           default: data_byte = info_end_byte(byte_index,
                                                program_frame_index);
        endcase
        rgmii_rxd <= data_byte[3:0];
        rgmii_rx_ctl <= 1'b1;
        @(negedge rgmii_rx_clock);
        rgmii_rxd <= data_byte[7:4];
        rgmii_rx_ctl <= 1'b1;
        calc_crc(data_byte, fcs);
        @(posedge rgmii_rx_clock);
      end
      for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1) begin
        rgmii_rxd <= fcs[(byte_index*8) +: 4];
        rgmii_rx_ctl <= 1'b1;
        @(negedge rgmii_rx_clock);
        rgmii_rxd <= fcs[(byte_index*8+4) +: 4];
        rgmii_rx_ctl <= 1'b1;
        @(posedge rgmii_rx_clock);
      end
      last_rgmii_frame_edge = $time;
      rgmii_rxd <= 4'h0;
      rgmii_rx_ctl <= 1'b0;
      // Twelve complete RGMII byte cycles make RX_CTL low for exactly 96 ns.
      // The next call drives its low nibble after the final rising edge and
      // that nibble is sampled on the following falling edge.
      repeat (12) begin
        @(negedge rgmii_rx_clock);
        @(posedge rgmii_rx_clock);
      end
    end
  endtask

  task automatic verify_program_ddr_image;
    integer byte_offset;
    integer frame_index;
    integer payload_offset;
    integer source_byte_index;
    reg [7:0] expected_byte;
    reg [7:0] actual_byte;
    begin
      if (dut.program_frame_count != PROGRAM_IMAGE_FRAMES)
        $fatal(1, "program frame count %0d != %0d",
               dut.program_frame_count, PROGRAM_IMAGE_FRAMES);
      if (dut.program_dma_done_count != PROGRAM_IMAGE_FRAMES)
        $fatal(1, "program DMA done count %0d != %0d",
               dut.program_dma_done_count, PROGRAM_IMAGE_FRAMES);
      if (dut.program_dma_write_addr !=
          (32'h8000_0000 + PROGRAM_IMAGE_FRAMES * 32'h400))
        $fatal(1, "program DMA final address %08h",
               dut.program_dma_write_addr);

      for (byte_offset = 0;
           byte_offset < PROGRAM_IMAGE_FRAMES * 1024;
           byte_offset = byte_offset + 1) begin
        frame_index = byte_offset / 1024;
        payload_offset = byte_offset % 1024;
        source_byte_index =
            frame_index * PROGRAM_RX_FRAME_BYTES + 18 + payload_offset;
        expected_byte = program_byte(source_byte_index);
        actual_byte =
            dut.mig_i.ddr0_memory_i.mem[byte_offset >> 6]
              [((byte_offset & 63) * 8) +: 8];
        if (actual_byte !== expected_byte)
          $fatal(1,
                 "program DDR mismatch offset=%08h expected=%02h actual=%02h",
                 byte_offset, expected_byte, actual_byte);
      end
      $display("PROGRAM_DDR_IMAGE_PASS frames=%0d bytes=%0d final_addr=%08h",
               PROGRAM_IMAGE_FRAMES, PROGRAM_IMAGE_FRAMES * 1024,
               dut.program_dma_write_addr);
    end
  endtask

  always @(posedge ctrl_clk) begin : capture_tx
    integer index;
    logic [31:0] code;
    if (dut.mac_tx_valid && dut.mac_tx_ready) begin
      tx_bytes[tx_byte_count] = dut.mac_tx_data;
      if (dut.mac_tx_last) begin
        $fwrite(tx_file, "FRAME %0d %0d ", tx_frame_count,
                tx_byte_count + 1);
        for (index = 0; index <= tx_byte_count; index = index + 1)
          $fwrite(tx_file, "%02x", tx_bytes[index]);
        $fwrite(tx_file, "\n");

        if (tx_byte_count + 1 == INFO_FRAME_BYTES) begin
          code = {tx_bytes[14],tx_bytes[15],tx_bytes[16],tx_bytes[17]};
          tx_info_frame_count = tx_info_frame_count + 1;
          case (code)
            MSG_PREINIT_DONE: saw_preinit = 1'b1;
            MSG_CHECK_PASS:   saw_check_pass = 1'b1;
            MSG_READY: begin
              saw_ready = 1'b1;
              ready_frame_count = ready_frame_count + 1;
            end
            MSG_PROGRAM_START: program_start_count = program_start_count + 1;
            MSG_RECEIVE_DONE:  receive_done_count = receive_done_count + 1;
            MSG_PROGRAM_DONE: saw_program_done = 1'b1;
            MSG_HART0_START: begin
              if (dut.system_state != ST_EXECUTE)
                $fatal(1, "hart0 start frame outside EXECUTE");
              saw_hart_status[0] = 1'b1;
            end
            MSG_HART1_START: begin
              if (dut.system_state != ST_EXECUTE)
                $fatal(1, "hart1 start frame outside EXECUTE");
              saw_hart_status[1] = 1'b1;
            end
            MSG_HART0_DONE: begin
              if (dut.system_state != ST_EXECUTE)
                $fatal(1, "hart0 done frame outside EXECUTE");
              saw_hart_status[2] = 1'b1;
            end
            MSG_HART1_DONE: begin
              if (dut.system_state != ST_EXECUTE)
                $fatal(1, "hart1 done frame outside EXECUTE");
              saw_hart_status[3] = 1'b1;
            end
            MSG_EH2_DONE:     saw_eh2_done = 1'b1;
            MSG_EXE_END:      saw_exe_end = 1'b1;
            default: $fatal(1, "unexpected system information code %08h", code);
          endcase
          $display("SYSTEM_TX code=%08h state=%0d time=%0t",
                   code, dut.system_state, $time);
        end else if (tx_byte_count + 1 == LOG_FRAME_BYTES) begin
          tx_log_frame_count = tx_log_frame_count + 1;
          if ({tx_bytes[0],tx_bytes[1],tx_bytes[2],tx_bytes[3],
               tx_bytes[4],tx_bytes[5]} != 48'hffff_ffff_ffff)
            $fatal(1, "log frame destination is not broadcast");
          $display("LOG_TX frame=%0d package=%0d hart=%0d count=%0d time=%0t",
                   tx_log_frame_count,
                   {tx_bytes[14],tx_bytes[15]},
                   tx_bytes[16][0],
                   {tx_bytes[18],tx_bytes[19],tx_bytes[20],tx_bytes[21]},
                   $time);
        end else begin
          $fatal(1, "unexpected TX frame length %0d", tx_byte_count + 1);
        end
        tx_frame_count = tx_frame_count + 1;
        tx_byte_count = 0;
      end else begin
        tx_byte_count = tx_byte_count + 1;
      end
    end
  end

  always @(posedge rgmii_txc)
    if (rgmii_tx_ctl)
      rgmii_tx_active_cycles <= rgmii_tx_active_cycles + 1;

  always @(posedge dut.eth_i.rx_mac_aclk) begin
    if (dut.system_state == ST_PROGRAM_WRITE &&
        dut.eth_i.mac_fifo_i.rx_axis_mac_tvalid) begin
      burst_raw_mac_bytes = burst_raw_mac_bytes + 1;
      if (dut.eth_i.mac_fifo_i.rx_axis_mac_tlast) begin
        if (dut.eth_i.mac_fifo_i.rx_axis_mac_tuser)
          burst_raw_bad_frames = burst_raw_bad_frames + 1;
        else
          burst_raw_good_frames = burst_raw_good_frames + 1;
      end
    end
  end

  always @(posedge ctrl_clk) begin
    if ((dut.system_state == ST_PROGRAM_WRITE) && dut.mac_rx_valid &&
        dut.mac_rx_ready)
      burst_fifo_words = burst_fifo_words + 1;
    if (dut.rx_fifo_overflow)
      saw_rx_fifo_overflow <= 1'b1;
    if (dut.rx_frame_buffer_overflow)
      saw_rx_classifier_overflow <= 1'b1;
    if (dut.rx_frame_length_error)
      saw_rx_length_error <= 1'b1;

    if (dut.program_frame_accepted)
      $display("PROGRAM_RX_ACCEPT state=%0d time=%0t",
               dut.system_state, $time);
    if (dut.info_frame_accepted)
      $display("INFO_RX_ACCEPT state=%0d time=%0t",
               dut.system_state, $time);
    if (dut.program_frame_done)
      $display("PROGRAM_STREAM_DONE frames=%0d time=%0t",
               dut.program_frame_count, $time);
    if (dut.program_dma_done)
      $display("PROGRAM_DMA_DONE status=%08h time=%0t",
               dut.last_dma_status, $time);
    if (dut.system_program_end_pulse) begin
      $display("PROGRAM_END_MARKER state=%0d time=%0t",
               dut.system_state, $time);
      if (dut.system_state == ST_PRECONFIG) begin
        if (dut.program_frame_count != 32'd1)
          $fatal(1, "PRECONFIG end target is %0d frames, expected 1",
                 dut.program_frame_count);
        if (dut.system_program_end_total_count != 32'd1)
          $fatal(1, "PRECONFIG end declared %0d frames, expected 1",
                 dut.system_program_end_total_count);
        saw_preconfig_end_marker = 1'b1;
      end else if (dut.system_state == ST_PROGRAM_WRITE) begin
        if (dut.program_frame_count != PROGRAM_IMAGE_FRAMES)
          $fatal(1, "PROGRAM_WRITE end target is %0d frames, expected %0d",
                 dut.program_frame_count, PROGRAM_IMAGE_FRAMES);
        if (dut.system_program_end_total_count != PROGRAM_IMAGE_FRAMES)
          $fatal(1, "PROGRAM_WRITE end declared %0d frames, expected %0d",
                 dut.system_program_end_total_count,
                 PROGRAM_IMAGE_FRAMES);
        saw_program_end_marker = 1'b1;
      end else begin
        $fatal(1, "program end marker in unexpected state %0d",
               dut.system_state);
      end
    end
    if (dut.instr_check_start_ctrl &&
        ((dut.program_frame_count != 32'd1) ||
         (dut.program_dma_done_count != 32'd1) ||
         dut.program_dma_busy))
      $fatal(1,
             "PRECONFIG checker started before frame/DMA pairing %0d/%0d busy=%b",
             dut.program_frame_count, dut.program_dma_done_count,
             dut.program_dma_busy);

    if (saw_preconfig_end_marker && !dut.program_dma_done &&
        (dut.system_state == ST_PRECONFIG)) begin
      preconfig_dma_diag_cycles <= preconfig_dma_diag_cycles + 1;
      if ((preconfig_dma_diag_cycles < 500) &&
          ((preconfig_dma_diag_cycles % 50) == 0))
        $display(
          "PRECONFIG_DMA_DIAG n=%0d t=%0t ctrl_state=%0d busy=%b frame=%0d done=%0d fc_state=%0d cmd=%b/%b payload=%b/%b/%b sts=%b/%b axi32_aw=%b/%b w=%b/%b/%b b=%b/%b ui_aw=%b/%b ui_w=%b/%b/%b ui_b=%b/%b ddr_aw=%b/%b ddr_w=%b/%b/%b ddr_b=%b/%b",
          preconfig_dma_diag_cycles, $time,
          dut.controller_i.phase, dut.program_dma_busy,
          dut.program_frame_count, dut.program_dma_done_count,
          dut.program_dma_i.frame_ctrl_i.state,
          dut.program_dma_i.cmd_tvalid, dut.program_dma_i.cmd_tready,
          dut.program_dma_i.payload_tvalid,
          dut.program_dma_i.payload_tready,
          dut.program_dma_i.payload_tlast,
          dut.program_dma_i.sts_tvalid, dut.program_dma_i.sts_tready,
          dut.program_axi32.awvalid, dut.program_axi32.awready,
          dut.program_axi32.wvalid, dut.program_axi32.wready,
          dut.program_axi32.wlast,
          dut.program_axi32.bvalid, dut.program_axi32.bready,
          dut.program_ui_axi.awvalid, dut.program_ui_axi.awready,
          dut.program_ui_axi.wvalid, dut.program_ui_axi.wready,
          dut.program_ui_axi.wlast,
          dut.program_ui_axi.bvalid, dut.program_ui_axi.bready,
          dut.ddr0_axi.awvalid, dut.ddr0_axi.awready,
          dut.ddr0_axi.wvalid, dut.ddr0_axi.wready,
          dut.ddr0_axi.wlast,
          dut.ddr0_axi.bvalid, dut.ddr0_axi.bready
        );
    end
  end

  always @(posedge ctrl_clk) begin : check_state_sequence
    if (!(sw3_1 && sw4_1)) begin
      state_trace_started <= 1'b0;
      previous_state <= ST_PRECONFIG;
      state_visit <= 6'b0;
    end else if (!dut.hard_resetn) begin
      // A completed/error session intentionally performs a full internal hard
      // reset. Preserve cumulative coverage, but restart transition tracking
      // so END -> reset -> PRECONFIG is not mistaken for a direct FSM edge.
      state_trace_started <= 1'b0;
      previous_state <= ST_PRECONFIG;
    end else begin
      state_visit[dut.system_state] <= 1'b1;
      if (!state_trace_started) begin
        state_trace_started <= 1'b1;
        previous_state <= dut.system_state;
      end else if (dut.system_state != previous_state) begin
        case (previous_state)
          ST_PRECONFIG:
            if (dut.system_state != ST_READY)
              $fatal(1, "state sequence PRECONFIG -> %0d",
                     dut.system_state);
          ST_READY:
            if (dut.system_state != ST_PROGRAM_WRITE)
              $fatal(1, "state sequence READY -> %0d", dut.system_state);
          ST_PROGRAM_WRITE:
            if (dut.system_state != ST_EXECUTE)
              $fatal(1,
                "state sequence PROGRAM_WRITE -> %0d fatal=%b code=%08h captured=%08h rx_fifo=%b frame_buf=%b frame_len=%b dma=%b/%b info=%b/%b",
                dut.system_state, dut.fatal_error_pending,
                dut.fatal_error_code, dut.controller_i.captured_error_code,
                dut.rx_fifo_overflow, dut.rx_frame_buffer_overflow,
                dut.rx_frame_length_error, dut.program_dma_error,
                dut.datamover_error, dut.info_rx_overflow,
                dut.info_tx_overflow);
          ST_EXECUTE:
            if (dut.system_state != ST_END)
              $fatal(1, "state sequence EXECUTE -> %0d", dut.system_state);
          ST_END:
            $fatal(1, "END changed state without the required hard reset");
          default:
            $fatal(1, "unexpected previous state %0d", previous_state);
        endcase
        $display("STATE_TRANSITION %0d -> %0d time=%0t",
                 previous_state, dut.system_state, $time);
        previous_state <= dut.system_state;
      end
    end
  end

  // Diagnostic only: keep long full-system runs observable without changing
  // DUT behavior.  The message is intentionally sparse (every 500k core
  // clocks, or 10 ms at 50 MHz).
  always @(posedge core_clk) begin
    for (integer lane = 0; lane < 2; lane = lane + 1) begin
      if (dut.eh2_i.rv_commit_valid[lane] &&
          !dut.eh2_i.rv_commit_hart_id[lane] &&
          dut.eh2_i.rv_commit_csr_wen[lane] &&
          (dut.eh2_i.rv_commit_csr_addr[lane] == 12'h7fc)) begin
        saw_hartstart_csr = 1'b1;
        $display(
          "HARTSTART_CSR_COMMIT hart=0 lane=%0d pc=%08h data=%08h time=%0t",
          lane, dut.eh2_i.rv_commit_pc[lane],
          dut.eh2_i.rv_commit_csr_wdata[lane], $time
        );
        if (!dut.eh2_i.rv_commit_csr_wdata[lane][1])
          $fatal(1, "hart0 CSR 0x7FC write did not set hart1 start bit");
      end
      if (dut.eh2_i.rv_commit_valid[lane] &&
          dut.eh2_i.rv_commit_hart_id[lane] &&
          !saw_hart1_first_commit) begin
        saw_hart1_first_commit = 1'b1;
        $display(
          "HART1_FIRST_COMMIT lane=%0d pc=%08h insn=%08h time=%0t",
          lane, dut.eh2_i.rv_commit_pc[lane],
          dut.eh2_i.rv_commit_insn[lane], $time
        );
      end
    end

    if (dut.system_state != ST_EXECUTE) begin
      execute_progress_cycles = 0;
    end else begin
      execute_progress_cycles = execute_progress_cycles + 1;
      if ((execute_progress_cycles % 500_000) == 0)
        $display(
          "EXECUTE_PROGRESS cycles=%0d mhartstart=%b stopped=%b commit=%0d/%0d generated=%0d/%0d time=%0t",
          execute_progress_cycles,
          dut.eh2_i.core_i.dec_tlu_mhartstart,
          dut.eh2_stopped_core,
          dut.eh2_i.commit_count_unused[0],
          dut.eh2_i.commit_count_unused[1],
          dut.eh2_i.generated_count_unused[0],
          dut.eh2_i.generated_count_unused[1],
          $time
        );
    end
  end

  initial begin : run_system
    tx_file = $fopen(
      "D:/eh2_fpga/eh2fpga_veri_system/artifacts/sim/full_system_tx_frames.log",
      "w"
    );
    $readmemh(
      "D:/eh2_fpga/eh2fpga_veri_system/programs/stress_200k_dualhart_system/build/stress_200k_program_frames.mem16",
      program_words
    );

    repeat (20) @(posedge ctrl_clk);
    sw3_1 = 1'b1;
    sw4_1 = 1'b1;

    fork
      begin : scenario
        wait (saw_preinit);
        if (dut.system_state != ST_PRECONFIG)
          $fatal(1, "PREINIT frame sent outside PRECONFIG");

        send_rgmii_frame(PROGRAM_RX_FRAME_BYTES, 0, 0);
        // The host sends the system end marker immediately after the final
        // program frame. It does not wait for the FPGA-side DataMover status.
        // The controller must latch both events and join them internally.
        send_rgmii_frame(INFO_FRAME_BYTES, 2, 1);

        wait (saw_check_pass);
        wait (saw_ready);
        wait (dut.system_state == ST_PROGRAM_WRITE);

        // Start a new continuous line-rate burst. The PRECONFIG/end pair was
        // already checked separately; state processing intentionally creates
        // a long idle interval before this formal program-write burst.
        last_rgmii_frame_edge = 0;
        $display("LINE_RATE_BURST_START frames=%0d ifg_ns=96 time=%0t",
                 PROGRAM_IMAGE_FRAMES, $time);
        $fflush();
        for (integer program_frame_index = 0;
             program_frame_index < PROGRAM_IMAGE_FRAMES;
             program_frame_index = program_frame_index + 1) begin
          send_rgmii_frame(PROGRAM_RX_FRAME_BYTES, 1,
                           program_frame_index);
          if (program_frame_index == 0) begin
            $display(
              "LINE_RATE_FIRST_FRAME raw_bytes=%0d good=%0d bad=%0d fifo_words=%0d fifo_status=%h classifier=%0d dropped=%0d dma_ready=%b dma_state=%0d reset=%b client_reset=%b wr_state=%0d rd_frames=%0d time=%0t",
              burst_raw_mac_bytes, burst_raw_good_frames,
              burst_raw_bad_frames, burst_fifo_words, dut.rx_fifo_status,
              dut.rx_classifier_i.state, dut.dropped_frame_count,
              dut.program_dma_input_ready,
              dut.program_dma_i.frame_ctrl_i.state, dut.hard_resetn,
              dut.eth_i.rx_client_resetn,
              dut.eth_i.mac_fifo_i.rx_client_fifo_i.wr_state,
              dut.eth_i.mac_fifo_i.rx_client_fifo_i.rd_frames, $time);
            $fflush();
          end
          if (((program_frame_index + 1) % 64) == 0) begin
            $display(
              "LINE_RATE_BURST_PROGRESS sent=%0d raw_bytes=%0d good=%0d bad=%0d fifo_words=%0d accepted=%0d dma_done=%0d overflow=%b/%b time=%0t",
              program_frame_index + 1, burst_raw_mac_bytes,
              burst_raw_good_frames,
              burst_raw_bad_frames, burst_fifo_words,
              dut.program_frame_count, dut.program_dma_done_count,
              dut.rx_fifo_overflow,
              dut.rx_frame_buffer_overflow, $time);
            $fflush();
          end
        end
        // Same host behavior for the real image: no DMA-done knowledge or
        // delay exists on the PC side between these two Ethernet frames.
        send_rgmii_frame(INFO_FRAME_BYTES, 2, PROGRAM_IMAGE_FRAMES);

        wait (saw_program_done);
        verify_program_ddr_image();
        wait (dut.system_state == ST_EXECUTE);
        wait (saw_exe_end);
        wait (!dut.hard_resetn);
        wait (dut.hard_resetn);
        if (dut.system_state != ST_PRECONFIG)
          $fatal(1, "global reset did not restart at PRECONFIG");
      end
      begin : watchdog
        repeat (40_000_000) @(posedge core_clk);
        $fatal(1,
          "full-system timeout state=%0d phase=%0d stopped=%b logs=%0d infos=%0d",
          dut.system_state, dut.controller_i.phase, dut.stopped_ctrl,
          tx_log_frame_count, tx_info_frame_count);
      end
    join_any
    disable fork;

    repeat (100) @(posedge ctrl_clk);
    $fclose(tx_file);
    if (led[0])
      $fatal(1, "ERROR state LED asserted");
    if (dut.mig_i.protocol_error0 || dut.mig_i.protocol_error1)
      $fatal(1, "AXI memory-model protocol error");
    if (!(saw_preinit && saw_check_pass && saw_ready &&
          saw_program_done && (&saw_hart_status) &&
          saw_eh2_done && saw_exe_end))
      $fatal(1, "missing system-information frame");
    if (ready_frame_count != 1)
      $fatal(1, "expected one READY frame before global reset, got %0d",
             ready_frame_count);
    if (tx_info_frame_count != 14)
      $fatal(1, "expected fourteen system-information frames, got %0d",
             tx_info_frame_count);
    if ((program_start_count != 2) || (receive_done_count != 2))
      $fatal(1, "start/receive-done messages %0d/%0d, expected 2/2",
             program_start_count, receive_done_count);
    if (tx_log_frame_count != 4)
      $fatal(1, "expected four hash frames, got %0d", tx_log_frame_count);
    if (rgmii_tx_active_cycles == 0)
      $fatal(1, "TEMAC did not produce RGMII TX activity");
    if (!saw_hartstart_csr)
      $fatal(1, "hart0 did not commit CSR 0x7FC hart-start write");
    if (!saw_hart1_first_commit)
      $fatal(1, "hart1 never committed an instruction");
    if (!saw_preconfig_end_marker || !saw_program_end_marker)
      $fatal(1, "required end markers were not received pre=%b program=%b",
             saw_preconfig_end_marker, saw_program_end_marker);
    if (saw_rx_fifo_overflow || saw_rx_classifier_overflow ||
        saw_rx_length_error || (dut.rx_fcs_error_count != 0))
      $fatal(1, "line-rate RX error fifo=%b classifier=%b length=%b",
             saw_rx_fifo_overflow, saw_rx_classifier_overflow,
             saw_rx_length_error);
    if (min_ifg_gap_count != (PROGRAM_IMAGE_FRAMES + 1))
      $fatal(1, "minimum-IFG gap count %0d, expected %0d",
             min_ifg_gap_count, PROGRAM_IMAGE_FRAMES + 1);
    if (!(state_visit[ST_PRECONFIG] && state_visit[ST_READY] &&
          state_visit[ST_PROGRAM_WRITE] && state_visit[ST_EXECUTE] &&
          state_visit[ST_END]))
      $fatal(1, "not all normal states were visited: %b", state_visit);

    $display(
      "FULL_SYSTEM_RGMII_PASS frames=%0d info=%0d log=%0d rgmii_cycles=%0d min_ifg=%0d rx_overflow=0 ddr_writes=%0d/%0d",
      tx_frame_count, tx_info_frame_count, tx_log_frame_count,
      rgmii_tx_active_cycles, min_ifg_gap_count,
      dut.mig_i.write_beat_count0, dut.mig_i.write_beat_count1
    );
    $finish;
  end
endmodule
