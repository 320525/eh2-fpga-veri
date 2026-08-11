`timescale 1ns/1ps

module tb_eth_rx_separation;
  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5 clk = ~clk;

  logic [15:0] s_data;
  logic s_valid, s_last, s_ready;
  logic [15:0] program_data;
  logic program_valid, program_last, program_ready;
  logic [15:0] info_wr_data;
  logic info_wr_last, info_wr_en, info_full;
  logic program_accepted, info_accepted, buffer_overflow, length_error;
  logic [31:0] drop_count;

  logic info_fifo_overflow;
  logic info_fifo_rd_en;
  logic [15:0] info_fifo_data;
  logic info_fifo_last, info_fifo_empty;
  logic program_end_pulse, host_send_stopped_pulse, malformed_frame;
  logic [31:0] program_end_total_count;

  eth_rx_frame_classifier dut (
    .clk, .resetn, .s_axis_tdata(s_data), .s_axis_tvalid(s_valid),
    .s_axis_tlast(s_last), .s_axis_tready(s_ready),
    .program_tdata(program_data), .program_tvalid(program_valid),
    .program_tlast(program_last), .program_tready(program_ready),
    .info_wr_data, .info_wr_last, .info_wr_en,
    .info_fifo_full(info_full), .program_frame_accepted(program_accepted),
    .info_frame_accepted(info_accepted),
    .frame_buffer_overflow(buffer_overflow),
    .recognized_length_error(length_error),
    .dropped_frame_count(drop_count)
  );

  system_info_rx_fifo #(.DEPTH(64)) info_fifo_i (
    .clk, .resetn, .wr_en(info_wr_en), .wr_data(info_wr_data),
    .wr_last(info_wr_last), .full(info_full),
    .overflow(info_fifo_overflow), .rd_en(info_fifo_rd_en),
    .rd_data(info_fifo_data), .rd_last(info_fifo_last),
    .empty(info_fifo_empty)
  );

  system_info_rx_decoder decoder_i (
    .clk, .resetn, .fifo_data(info_fifo_data), .fifo_last(info_fifo_last),
    .fifo_empty(info_fifo_empty), .fifo_rd_en(info_fifo_rd_en),
    .program_end_pulse, .program_end_total_count,
    .host_send_stopped_pulse, .malformed_frame
  );

  integer program_words;
  integer program_last_count;
  integer end_pulse_count;
  integer stopped_pulse_count;
  integer accepted_program_count;
  integer accepted_info_count;
  always_ff @(posedge clk) begin
    if (!resetn) begin
      program_words <= 0;
      program_last_count <= 0;
      end_pulse_count <= 0;
      stopped_pulse_count <= 0;
      accepted_program_count <= 0;
      accepted_info_count <= 0;
    end else begin
      if (program_valid && program_ready) begin
        program_words <= program_words + 1;
        if (program_last)
          program_last_count <= program_last_count + 1;
      end
      if (program_end_pulse)
        end_pulse_count <= end_pulse_count + 1;
      if (host_send_stopped_pulse)
        stopped_pulse_count <= stopped_pulse_count + 1;
      if (program_accepted)
        accepted_program_count <= accepted_program_count + 1;
      if (info_accepted)
        accepted_info_count <= accepted_info_count + 1;
      if (buffer_overflow || length_error || info_fifo_overflow ||
          malformed_frame)
        $fatal(1, "unexpected receive-path error");
    end
  end

  task automatic send_word(input logic [15:0] value, input logic last);
    begin
      s_data  <= value;
      s_valid <= 1'b1;
      s_last  <= last;
      do @(posedge clk); while (!s_ready);
      s_valid <= 1'b0;
      s_last  <= 1'b0;
    end
  endtask

  task automatic send_host_stopped_frame;
    begin
      send_word(16'h3202, 1'b0);
      send_word(16'h2505, 1'b0);
      send_word(16'hff00, 1'b0);
      send_word(16'h2211, 1'b0);
      send_word(16'h4433, 1'b0);
      send_word(16'h6655, 1'b0);
      send_word(16'hb588, 1'b0);
      // HOST_SEND_STOPPED 0x44_12_44_45 followed by 42 zero bytes.
      send_word(16'h1244, 1'b0);
      send_word(16'h4544, 1'b0);
      for (integer i = 9; i < 30; i = i + 1)
        send_word(16'h0000, i == 29);
    end
  endtask

  task automatic send_program_frame;
    begin
      send_word(16'h1202, 1'b0);
      send_word(16'h5634, 1'b0);
      send_word(16'hff78, 1'b0);
      send_word(16'hbbaa, 1'b0);
      send_word(16'hddcc, 1'b0);
      send_word(16'hffee, 1'b0);
      send_word(16'h0008, 1'b0);
      // Sequence number zero, transmitted in network byte order.
      send_word(16'h0000, 1'b0);
      send_word(16'h0000, 1'b0);
      for (integer i = 0; i < 512; i = i + 1)
        send_word(i[15:0], i == 511);
    end
  endtask

  task automatic send_system_end_frame;
    begin
      send_word(16'h3202, 1'b0);
      send_word(16'h2505, 1'b0);
      send_word(16'hff00, 1'b0);
      send_word(16'h2211, 1'b0);
      send_word(16'h4433, 1'b0);
      send_word(16'h6655, 1'b0);
      send_word(16'hb588, 1'b0);
      send_word(16'hffff, 1'b0);
      send_word(16'hffff, 1'b0);
      // Declared packet count one, transmitted big-endian.
      send_word(16'h0000, 1'b0);
      send_word(16'h0100, 1'b0);
      for (integer i = 11; i < 30; i = i + 1)
        send_word(16'h0000, i == 29);
    end
  endtask

  task automatic send_unrelated_frame;
    begin
      send_word(16'h0001, 1'b0);
      send_word(16'h0002, 1'b0);
      send_word(16'h0003, 1'b0);
      for (integer i = 3; i < 30; i = i + 1)
        send_word(16'h1234, i == 29);
    end
  endtask

  initial begin
    s_data = 16'b0;
    s_valid = 1'b0;
    s_last = 1'b0;
    program_ready = 1'b1;
    repeat (5) @(posedge clk);
    resetn <= 1'b1;
    repeat (3) @(posedge clk);

    send_program_frame();
    wait (program_last_count == 1);
    if ((program_words != 521) || (end_pulse_count != 0))
      $fatal(1, "program frame leaked into system path");

    send_system_end_frame();
    wait (end_pulse_count == 1);
    if ((program_words != 521) || (program_last_count != 1) ||
        (program_end_total_count != 32'd1))
      $fatal(1, "system frame leaked into program path");

    send_host_stopped_frame();
    wait (stopped_pulse_count == 1);
    if (end_pulse_count != 1)
      $fatal(1, "host stop acknowledgement aliased to end marker");

    send_unrelated_frame();
    repeat (20) @(posedge clk);
    if ((accepted_program_count != 1) || (accepted_info_count != 2) ||
        (drop_count != 1) || (end_pulse_count != 1))
      $fatal(1, "classification counters mismatch p=%0d i=%0d d=%0d e=%0d",
             accepted_program_count, accepted_info_count, drop_count,
             end_pulse_count);

    $display("TB_PASS rx separation program_words=%0d drops=%0d",
             program_words, drop_count);
    $finish;
  end

  initial begin
    #2ms;
    $fatal(1, "global simulation timeout");
  end
endmodule
