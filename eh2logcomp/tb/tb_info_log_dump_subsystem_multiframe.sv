`timescale 1ns/1ps

// Integration regression for the UI-domain frame scheduler, fixed-30-beat
// DDR reader and the two complete-frame TX slots.  The individual DMA/slot
// tests cannot detect duplicate registered start pulses at their boundary.
module tb_info_log_dump_subsystem_multiframe;
  logic ui_clk = 1'b0;
  logic tx_clk = 1'b0;
  logic resetn = 1'b0;
  always #1.876 ui_clk = ~ui_clk;
  always #4.000 tx_clk = ~tx_clk;

  axi4_if axi();
  logic start;
  logic [7:0] tx_tdata;
  logic tx_tvalid, tx_tlast, tx_tready;
  logic frame_done_tx, all_done_ui, busy_ui, error_ui;
  logic memory_protocol_error;
  logic [31:0] write_beats, read_beats;

  // Board logs exposed the first long-run failure after hart0 frame 205.
  // Keep this regression above that lifetime and exercise both hart regions,
  // including a partial final hart1 frame.
  localparam int H0_RECORDS = 12360; // exactly 206 data frames
  localparam int H1_RECORDS = 12601; // 211 data frames, partial final frame
  localparam int DATA_FRAMES = 417;
  localparam int TOTAL_FRAMES = DATA_FRAMES + 2;
  localparam int EXPECTED_DDR_READ_BEATS =
      ((H0_RECORDS + 1) / 2) + ((H1_RECORDS + 1) / 2);

  info_log_dump_subsystem dut (
    .ui_clk, .tx_clk, .ui_resetn(resetn), .tx_resetn(resetn),
    .cdc_resetn(resetn), .start,
    .h0_total_records(H0_RECORDS), .h1_total_records(H1_RECORDS),
    .axi, .tx_tdata, .tx_tvalid, .tx_tlast, .tx_tready,
    .frame_done_tx, .all_done_ui, .busy_ui, .error_ui,
    .error_cause_ui()
  );

  axi512_memory_model #(.LINE_COUNT(2048), .SPLIT_AT_ADDR32(1)) memory_i (
    .clk(ui_clk), .resetn,
    .awid(axi.awid), .awaddr(axi.awaddr), .awlen(axi.awlen),
    .awsize(axi.awsize), .awburst(axi.awburst),
    .awvalid(axi.awvalid), .awready(axi.awready),
    .wdata(axi.wdata), .wstrb(axi.wstrb), .wlast(axi.wlast),
    .wvalid(axi.wvalid), .wready(axi.wready),
    .bid(axi.bid), .bresp(axi.bresp), .bvalid(axi.bvalid),
    .bready(axi.bready), .arid(axi.arid), .araddr(axi.araddr),
    .arlen(axi.arlen), .arsize(axi.arsize), .arburst(axi.arburst),
    .arvalid(axi.arvalid), .arready(axi.arready),
    .rid(axi.rid), .rdata(axi.rdata), .rresp(axi.rresp),
    .rlast(axi.rlast), .rvalid(axi.rvalid), .rready(axi.rready),
    .protocol_error(memory_protocol_error),
    .write_beat_count(write_beats), .read_beat_count(read_beats)
  );

  int tx_cycle = 0;
  int frame_bytes = 0;
  int frames_seen = 0;
  int data_frames_seen = 0;
  int done_frames_seen = 0;
  logic [15:0] ethertype;
  logic [31:0] data_frame_number;
  logic [47:0] source_mac;

  // Repeated downstream stalls force both slots to fill and exercise release
  // CDC/backpressure while later frames are being planned.
  always @(negedge tx_clk) begin
    if (!resetn) begin
      tx_cycle = 0;
      tx_tready = 1'b0;
    end else begin
      tx_cycle = tx_cycle + 1;
      tx_tready = !((tx_cycle % 211) >= 150 && (tx_cycle % 211) < 205);
    end
  end

  always @(posedge tx_clk) begin
    if (!resetn) begin
      frame_bytes = 0;
      frames_seen = 0;
      data_frames_seen = 0;
      done_frames_seen = 0;
      ethertype = '0;
      data_frame_number = '0;
      source_mac = '0;
    end else if (tx_tvalid && tx_tready) begin
      if (frame_bytes == 12)
        ethertype[15:8] = tx_tdata;
      if (frame_bytes == 13)
        ethertype[7:0] = tx_tdata;
      if ((frame_bytes >= 6) && (frame_bytes <= 11))
        source_mac = {source_mac[39:0], tx_tdata};
      if ((frame_bytes >= 14) && (frame_bytes <= 17))
        data_frame_number = {data_frame_number[23:0], tx_tdata};
      frame_bytes = frame_bytes + 1;
      if (tx_tlast) begin
        if (ethertype == 16'h88b7) begin
          if (frame_bytes != 1458)
            $fatal(1, "data frame length %0d", frame_bytes);
          // The first H0 data frame of every dump generation must restart at
          // frame zero and carry H0's dedicated source MAC.  This is the
          // essential replay boundary: retained DDR1 content is reread, not
          // appended to the previous generation.
          if ((data_frames_seen % DATA_FRAMES) == 0) begin
            if (data_frame_number != 0)
              $fatal(1, "replay did not restart hart0 frame number at zero");
            if (source_mac != 48'h02_32_05_25_10_00)
              $fatal(1, "replay first data frame source MAC is not hart0");
          end
          data_frames_seen = data_frames_seen + 1;
        end else if (ethertype == 16'h88b8) begin
          if (frame_bytes != 60)
            $fatal(1, "done frame length %0d", frame_bytes);
          done_frames_seen = done_frames_seen + 1;
        end else begin
          $fatal(1, "unexpected EtherType %04h", ethertype);
        end
        frames_seen = frames_seen + 1;
        frame_bytes = 0;
        ethertype = '0;
        data_frame_number = '0;
        source_mac = '0;
      end
    end
  end

  initial begin
    start = 1'b0;
    tx_tready = 1'b0;
    repeat (12) @(posedge ui_clk);
    resetn = 1'b1;
    repeat (6) @(posedge ui_clk);
    @(negedge ui_clk); start = 1'b1;
    @(negedge ui_clk); start = 1'b0;

    wait (all_done_ui);
    repeat (20) @(posedge ui_clk);
    if (error_ui || memory_protocol_error)
      $fatal(1, "dump error=%b memory protocol=%b frame protocol=%b read protocol=%b",
             error_ui, memory_protocol_error,
             dut.frame_protocol_error_ui, dut.read_protocol_error);
    if (frames_seen != TOTAL_FRAMES || data_frames_seen != DATA_FRAMES ||
        done_frames_seen != 2)
      $fatal(1, "frames total/data/done=%0d/%0d/%0d expected %0d/%0d/2",
             frames_seen, data_frames_seen, done_frames_seen,
             TOTAL_FRAMES, DATA_FRAMES);
    if (read_beats != EXPECTED_DDR_READ_BEATS)
      $fatal(1, "DDR read beats=%0d expected=%0d", read_beats,
             EXPECTED_DDR_READ_BEATS);
    // Request a second read session without resetting the UI, TX or DDR1
    // domains.  all_done is intentionally level-held in ST_DONE, therefore
    // wait for the deassertion that proves the new session was accepted.
    @(negedge ui_clk); start = 1'b1;
    @(negedge ui_clk); start = 1'b0;
    wait (!all_done_ui);
    wait (all_done_ui);
    repeat (20) @(posedge ui_clk);
    if (error_ui || memory_protocol_error)
      $fatal(1, "replay dump reported error");
    if (frames_seen != (2 * TOTAL_FRAMES) ||
        data_frames_seen != (2 * DATA_FRAMES) || done_frames_seen != 4)
      $fatal(1, "replay frame count mismatch total/data/done=%0d/%0d/%0d",
             frames_seen, data_frames_seen, done_frames_seen);
    if (read_beats != (2 * EXPECTED_DDR_READ_BEATS))
      $fatal(1, "replay DDR read beats=%0d expected=%0d", read_beats,
             2 * EXPECTED_DDR_READ_BEATS);
    $display("TB_PASS: multiframe scheduler/DMA/two-slot replay frames=%0d reads=%0d",
             frames_seen, read_beats);
    $finish;
  end

  initial begin
    #20ms;
    $fatal(1, "timeout state=%0d busy=%b error=%b frames=%0d reads=%0d",
           dut.state, busy_ui, error_ui, frames_seen, read_beats);
  end
endmodule
