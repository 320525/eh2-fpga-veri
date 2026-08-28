`timescale 1ns/1ps

module tb_log_frame_packetizer;
  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5 clk = ~clk;

  logic [3:0] event_valid, event_hart;
  logic [3:0][15:0] event_package, event_sequence;
  logic waw_read_hart, waw_read_bank;
  logic [8:0] waw_read_index;
  logic [15:0] waw_read_package, waw_read_sequence;
  logic [8:0] waw_read_count;
  logic waw_read_match;
  logic [1:0][1:0] waw_clear_bank;
  logic [1:0] waw_overflow, waw_bank_conflict;

  logic [1:0][1:0] result_valid;
  logic [1:0][1:0][15:0] result_package;
  logic [1:0][1:0][63:0] result_xor0, result_xor1;
  logic [1:0][1:0][63:0] result_sum0, result_sum1, result_sum2, result_sum3;
  logic [1:0][1:0][31:0] result_count;
  logic [1:0] stopped;
  logic [1:0][15:0] final_package;
  logic [7:0] tx_data;
  logic tx_valid, tx_last, tx_ready;
  logic frame_done, all_done, pending_overflow;

  waw_sequence_store store_i (
    .clk, .resetn, .clear_all(1'b0),
    .event_valid, .event_hart, .event_package, .event_sequence,
    .read_hart(waw_read_hart), .read_bank(waw_read_bank),
    .read_index(waw_read_index), .read_package(waw_read_package),
    .read_sequence(waw_read_sequence), .read_count(waw_read_count),
    .read_package_match(waw_read_match), .clear_bank(waw_clear_bank),
    .overflow_hart(waw_overflow), .bank_conflict_hart(waw_bank_conflict)
  );

  log_frame_packetizer dut (
    .clk, .resetn, .result_valid,
    .result_package_number(result_package),
    .result_xor0, .result_xor1, .result_sum0, .result_sum1,
    .result_sum2, .result_sum3, .result_item_count(result_count),
    .stopped, .final_package_number(final_package),
    .waw_read_hart, .waw_read_bank, .waw_read_index,
    .waw_read_package, .waw_read_sequence, .waw_read_count,
    .waw_read_package_match(waw_read_match), .waw_clear_bank,
    .m_axis_tdata(tx_data), .m_axis_tvalid(tx_valid),
    .m_axis_tlast(tx_last), .m_axis_tready(tx_ready),
    .frame_done, .all_done, .pending_overflow
  );

  integer byte_index;
  integer frame_count;
  always_ff @(posedge clk) begin
    if (!resetn) begin
      byte_index <= 0;
      frame_count <= 0;
    end else if (tx_valid && tx_ready) begin
      if (byte_index < 6 && tx_data != 8'hff)
        $fatal(1, "log destination MAC mismatch");
      case (byte_index)
        6:  if (tx_data != 8'h02) $fatal(1, "source mac 0");
        7:  if (tx_data != 8'h12) $fatal(1, "source mac 1");
        8:  if (tx_data != 8'h34) $fatal(1, "source mac 2");
        9:  if (tx_data != 8'h56) $fatal(1, "source mac 3");
        10: if (tx_data != 8'h78) $fatal(1, "source mac 4");
        11: if (tx_data != 8'hff) $fatal(1, "source mac 5");
        12: if (tx_data != 8'h88) $fatal(1, "ethertype msb");
        13: if (tx_data != 8'hb5) $fatal(1, "ethertype lsb");
      endcase

      if (frame_count == 0) begin
        case (byte_index)
          14: if (tx_data != 8'h00) $fatal(1, "package hi");
          15: if (tx_data != 8'h00) $fatal(1, "package lo");
          16: if (tx_data != 8'h00) $fatal(1, "hart");
          18: if (tx_data != 8'h00) $fatal(1, "count 3");
          19: if (tx_data != 8'h00) $fatal(1, "count 2");
          20: if (tx_data != 8'h12) $fatal(1, "count 1");
          21: if (tx_data != 8'h34) $fatal(1, "count 0");
          22: if (tx_data != 8'h01) $fatal(1, "xor0 first");
          29: if (tx_data != 8'h08) $fatal(1, "xor0 last");
          70: if (tx_data != 8'h00) $fatal(1, "waw count hi");
          71: if (tx_data != 8'h04) $fatal(1, "waw count lo");
          72: if (tx_data != 8'h11) $fatal(1, "waw seq0 hi");
          73: if (tx_data != 8'h22) $fatal(1, "waw seq0 lo");
          74: if (tx_data != 8'h33) $fatal(1, "waw seq1 hi");
          75: if (tx_data != 8'h44) $fatal(1, "waw seq1 lo");
          76: if (tx_data != 8'h55) $fatal(1, "waw seq2 hi");
          77: if (tx_data != 8'h66) $fatal(1, "waw seq2 lo");
          78: if (tx_data != 8'h77) $fatal(1, "waw seq3 hi");
          79: if (tx_data != 8'h88) $fatal(1, "waw seq3 lo");
          80: if (tx_data != 8'h00) $fatal(1, "padding after WAW");
        endcase
      end else if ((frame_count == 1) && (byte_index == 16) &&
                   (tx_data != 8'h01)) begin
        $fatal(1, "second frame hart field mismatch");
      end

      if (tx_last) begin
        if (byte_index != 1037)
          $fatal(1, "log frame length %0d", byte_index + 1);
        byte_index <= 0;
        frame_count <= frame_count + 1;
      end else begin
        byte_index <= byte_index + 1;
      end
    end
  end

  task automatic send_waw(
    input logic hart,
    input logic [15:0] package_number,
    input logic [15:0] sequence_number
  );
    begin
      @(posedge clk);
      event_valid[0] <= 1'b1;
      event_hart[0] <= hart;
      event_package[0] <= package_number;
      event_sequence[0] <= sequence_number;
      @(posedge clk);
      event_valid <= 4'b0;
    end
  endtask

  initial begin
    event_valid = 4'b0;
    event_hart = 2'b0;
    event_package = '0;
    event_sequence = '0;
    result_valid = '0;
    result_package = '0;
    result_xor0 = '0;
    result_xor1 = '0;
    result_sum0 = '0;
    result_sum1 = '0;
    result_sum2 = '0;
    result_sum3 = '0;
    result_count = '0;
    stopped = 2'b0;
    final_package = '0;
    tx_ready = 1'b1;

    repeat (5) @(posedge clk);
    resetn <= 1'b1;
    repeat (3) @(posedge clk);
    // All four WAW classes may be valid together.  Prove that the store
    // retains all four events in slot order rather than collapsing them.
    @(posedge clk);
    event_valid <= 4'b1111;
    event_hart <= 4'b0000;
    event_package <= '{default:16'h0000};
    event_sequence[0] <= 16'h1122;
    event_sequence[1] <= 16'h3344;
    event_sequence[2] <= 16'h5566;
    event_sequence[3] <= 16'h7788;
    @(posedge clk);
    event_valid <= 4'b0000;

    @(posedge clk);
    result_package[0][0] <= 16'h0000;
    result_xor0[0][0] <= 64'h0102_0304_0506_0708;
    result_xor1[0][0] <= 64'h1112_1314_1516_1718;
    result_sum0[0][0] <= 64'h2122_2324_2526_2728;
    result_sum1[0][0] <= 64'h3132_3334_3536_3738;
    result_sum2[0][0] <= 64'h4142_4344_4546_4748;
    result_sum3[0][0] <= 64'h5152_5354_5556_5758;
    result_count[0][0] <= 32'h0000_1234;
    result_package[1][0] <= 16'h0000;
    result_count[1][0] <= 32'h0000_0001;
    result_valid[0][0] <= 1'b1;
    result_valid[1][0] <= 1'b1;
    stopped <= 2'b11;
    @(posedge clk);
    result_valid <= '0;

    wait (frame_count == 2);
    wait (all_done);
    if (pending_overflow || |waw_overflow || |waw_bank_conflict)
      $fatal(1, "unexpected log/WAW error");

    // Reset and prove the non-fragmenting 483-entry limit.
    resetn <= 1'b0;
    repeat (3) @(posedge clk);
    resetn <= 1'b1;
    repeat (3) @(posedge clk);
    for (integer i = 0; i < 484; i = i + 1)
      send_waw(1'b0, 16'h0000, i[15:0]);
    repeat (3) @(posedge clk);
    if (!waw_overflow[0])
      $fatal(1, "484th WAW did not raise overflow");

    $display("TB_PASS log packetizer frames=%0d WAW_limit=483", frame_count);
    $finish;
  end

  initial begin
    #5ms;
    $fatal(1, "global simulation timeout");
  end
endmodule
