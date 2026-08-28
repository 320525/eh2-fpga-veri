`timescale 1ns/1ps

module tb_info_tx_frame_fifo_2slot;
  localparam int FRAME_BYTES = 1458;

  logic ui_clk = 0;
  logic tx_clk = 0;
  logic resetn = 0;
  always #1.876 ui_clk = ~ui_clk; // 266.5 MHz DDR UI clock
  always #4.000 tx_clk = ~tx_clk; // 125 MHz MAC client clock

  logic build_start, build_hart, build_ready;
  logic [31:0] build_frame_number;
  logic [5:0] build_valid_records;
  logic dma_data_valid, dma_data_last, dma_data_ready;
  logic [511:0] dma_data;
  logic [4:0] dma_data_index;
  logic full_ui, frame_released_ui, protocol_error_ui;
  logic [1:0] dirty_ui, valid_ui;
  logic [7:0] tdata;
  logic tvalid, tlast, tready, frame_done, empty_tx;

  info_tx_frame_fifo_2slot dut (
    .ui_clk, .tx_clk, .ui_resetn(resetn), .tx_resetn(resetn),
    .build_start, .build_hart, .build_frame_number,
    .build_valid_records, .build_ready,
    .dma_data_valid, .dma_data, .dma_data_index, .dma_data_last,
    .dma_data_ready, .full_ui, .dirty_ui, .valid_ui,
    .frame_released_ui, .protocol_error_ui,
    .m_axis_tdata(tdata), .m_axis_tvalid(tvalid),
    .m_axis_tlast(tlast), .m_axis_tready(tready),
    .frame_done_tx(frame_done), .empty_tx
  );

  function automatic [191:0] make_record(input int frame, input int record_no);
    reg [191:0] value;
    begin
      for (int b = 0; b < 24; b++)
        value[191-b*8 -: 8] = (frame*8'h31 + record_no*8'h07 + b) & 8'hff;
      make_record = value;
    end
  endfunction

  task automatic build_frame(input int frame, input int valid_records,
                             input logic hart);
    reg [255:0] record_even, record_odd;
    begin
      wait (build_ready);
      $display("BUILD_START frame=%0d time=%0t slot=%b", frame, $time, dut.write_slot);
      @(negedge ui_clk);
      build_hart = hart;
      build_frame_number = frame;
      build_valid_records = valid_records;
      build_start = 1;
      @(negedge ui_clk);
      build_start = 0;
      for (int beat = 0; beat < 30; beat++) begin
        record_even = {make_record(frame, beat*2), 64'h1111_0000_0000_0000 + beat};
        record_odd  = {make_record(frame, beat*2+1), 64'h2222_0000_0000_0000 + beat};
        dma_data = {record_odd, record_even};
        dma_data_index = beat;
        dma_data_last = (beat == 29);
        dma_data_valid = 1;
        do @(posedge ui_clk); while (!dma_data_ready);
        @(negedge ui_clk);
      end
      dma_data_valid = 0;
      dma_data_last = 0;
      dma_data_index = 0;
      dma_data = 0;
      $display("BUILD_DONE frame=%0d time=%0t occupied=%b dirty=%b pub=%b", frame,
               $time, dut.occupied_ui, dirty_ui, dut.publish_toggle_ui);
    end
  endtask

  byte captured [0:FRAME_BYTES-1];
  int byte_index = 0;
  int frames_seen = 0;
  int frame_ids [0:2] = '{0, 1, 2};
  int frame_valid [0:2] = '{60, 7, 60};
  logic stalled_valid;
  logic [7:0] stalled_data;
  logic stalled_last;

  task automatic check_frame(input int ordinal);
    int frame;
    int valid_records;
    int offset;
    byte expected;
    reg [191:0] expected_record;
    begin
      frame = frame_ids[ordinal];
      valid_records = frame_valid[ordinal];
      // Called on the final-byte handshake before byte_index's nonblocking
      // increment takes effect.
      // tready is enabled on a positive edge for the first directed frame;
      // the negative-edge monitor therefore begins after its first accepted
      // 0xff byte.  Later frames are observed from their first byte.
      if (ordinal == 0) begin
        if (byte_index != FRAME_BYTES-2)
          $fatal(1, "frame %0d final index %0d expected %0d", ordinal,
                 byte_index, FRAME_BYTES-2);
        for (int i = FRAME_BYTES-1; i > 0; i--)
          captured[i] = captured[i-1];
        captured[0] = 8'hff;
      end else if (byte_index != FRAME_BYTES-1) begin
        $fatal(1, "frame %0d final index %0d expected %0d", ordinal,
               byte_index, FRAME_BYTES-1);
      end
      for (int b = 0; b < 6; b++)
        if (captured[b] !== 8'hff) $fatal(1, "destination MAC mismatch");
      // All directed frames use hart0 source MAC 02:32:05:25:10:00.
      if ({captured[6],captured[7],captured[8],captured[9],captured[10],captured[11]}
          !== 48'h0232_0525_1000)
        $fatal(1, "source MAC mismatch");
      if ({captured[12],captured[13]} !== 16'h88b7)
        $fatal(1, "EtherType mismatch");
      if ({captured[14],captured[15],captured[16],captured[17]} !== frame[31:0])
        $fatal(1, "frame number mismatch");
      offset = 18;
      for (int rec = 0; rec < 60; rec++) begin
        expected_record = make_record(frame, rec);
        for (int b = 0; b < 24; b++) begin
          expected = rec < valid_records ?
                     expected_record[191-b*8 -: 8] : 8'h00;
          if (captured[offset + rec*24 + b] !== expected)
            $fatal(1, "frame %0d record %0d byte %0d got %02x expected %02x",
                   frame, rec, b, captured[offset + rec*24 + b], expected);
        end
      end
    end
  endtask

  always @(negedge tx_clk) begin
    if (!resetn) begin
      byte_index <= 0;
      frames_seen <= 0;
      stalled_valid <= 0;
    end else begin
      // AXI-stream rule: a stalled source must hold valid/data/last stable.
      if (stalled_valid && !tready) begin
        if (!tvalid || tdata !== stalled_data || tlast !== stalled_last)
          $fatal(1, "TX changed while stalled time=%0t old=%02x/%b now=%02x/%b ready=%b state=%0d byte=%0d",
                 $time, stalled_data, stalled_last, tdata, tlast, tready,
                 dut.tx_state, dut.payload_word_byte);
      end
      stalled_valid <= tvalid && !tready;
      stalled_data <= tdata;
      stalled_last <= tlast;

      if (tvalid && tready) begin
        captured[byte_index] = tdata;
        if (tlast) begin
          check_frame(frames_seen);
          byte_index = 0;
          frames_seen <= frames_seen + 1;
        end else
          byte_index = byte_index + 1;
      end
    end
  end

  initial begin
    build_start = 0;
    build_hart = 0;
    build_frame_number = 0;
    build_valid_records = 0;
    dma_data_valid = 0;
    dma_data = 0;
    dma_data_index = 0;
    dma_data_last = 0;
    tready = 0;
    repeat (12) @(posedge ui_clk);
    resetn = 1;

    // Fill both complete-frame slots while the MAC side is stopped.
    build_frame(0, 60, 0);
    build_frame(1, 7, 0);
    wait (full_ui);
    repeat (2000) @(posedge tx_clk);
    if (!full_ui || build_ready || dirty_ui != 0 || valid_ui != 2'b11)
      $fatal(1, "two-slot full/backpressure state is incorrect");

    // Release the first frame at full client rate.  As soon as its slot has
    // crossed back to the UI domain, refill it while frame 1 is transmitting.
    tready = 1;
    wait (frames_seen == 1);
    build_frame(2, 60, 0);

    // Apply additional downstream backpressure to the third frame and verify
    // that the byte stream resumes without mutation or reordering.
    wait (frames_seen == 2);
    repeat (100) @(posedge tx_clk);
    @(negedge tx_clk);
    tready = 0;
    repeat (500) @(posedge tx_clk);
    @(negedge tx_clk);
    tready = 1;
    wait (frames_seen == 3);
    wait (empty_tx);
    repeat (12) @(posedge ui_clk);

    if (protocol_error_ui) $fatal(1, "unexpected frame protocol error");
    if (full_ui || dirty_ui != 0 || valid_ui != 0)
      $fatal(1, "slots did not return to empty state");
    $display("TB_PASS: two-slot full/backpressure/recovery/data-order test passed");
    $finish;
  end

  initial begin
    #2ms;
    $display("TIMEOUT full=%b ready=%b dirty=%b valid_ui=%b empty_tx=%b frames=%0d byte=%0d tvalid=%b tready=%b txstate=%0d readslot=%b pending=%b pub_ui=%b pub_tx=%b rel_tx=%b rel_ui=%b",
      full_ui, build_ready, dirty_ui, valid_ui, empty_tx, frames_seen,
      byte_index, tvalid, tready, dut.tx_state, dut.read_slot,
      dut.current_slot_pending, dut.publish_toggle_ui,
      dut.publish_toggle_tx, dut.release_toggle_tx, dut.release_toggle_ui);
    $fatal(1, "timeout");
  end
endmodule
