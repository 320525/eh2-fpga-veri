`timescale 1ns/1ps

module tb_program_rx_dma_sequence;
  logic clk = 1'b0;
  logic resetn = 1'b0;
  logic session_clear = 1'b0;
  always #5 clk = ~clk;

  logic [15:0] rx_data;
  logic rx_valid, rx_last, rx_ready;
  logic [15:0] payload_data;
  logic payload_valid, payload_last;
  logic [71:0] command_data;
  logic command_valid;
  logic [31:0] status_data;
  logic status_valid, status_ready;
  logic [31:0] frame_count, dma_write_addr, last_dma_status;
  logic frame_done, dma_done, dma_error, sequence_error;
  logic frame_length_error, dma_busy;

  integer command_count = 0;
  integer payload_count = 0;
  integer payload_last_count = 0;
  integer dma_done_count = 0;

  program_rx_dma_ctrl dut (
    .clk, .resetn, .session_clear,
    .rx_fifo_tdata(rx_data), .rx_fifo_tvalid(rx_valid),
    .rx_fifo_tlast(rx_last), .rx_fifo_tready(rx_ready),
    .payload_tdata(payload_data), .payload_tvalid(payload_valid),
    .payload_tlast(payload_last), .payload_tready(1'b1),
    .s_axis_s2mm_cmd_tdata(command_data),
    .s_axis_s2mm_cmd_tvalid(command_valid),
    .s_axis_s2mm_cmd_tready(1'b1),
    .m_axis_s2mm_sts_tdata(status_data),
    .m_axis_s2mm_sts_tvalid(status_valid),
    .m_axis_s2mm_sts_tready(status_ready),
    .frame_count, .dma_write_addr, .frame_done, .dma_done,
    .dma_error, .sequence_error, .frame_length_error,
    .last_dma_status, .dma_busy
  );

  always_ff @(posedge clk) begin
    if (resetn) begin
      if (command_valid)
        command_count <= command_count + 1;
      if (payload_valid) begin
        if ((payload_count == 0) && (payload_data != 16'hA000))
          $fatal(1, "sequence prefix leaked into DataMover payload: %04h",
                 payload_data);
        payload_count <= payload_count + 1;
        if (payload_last)
          payload_last_count <= payload_last_count + 1;
      end
      if (dma_done)
        dma_done_count <= dma_done_count + 1;
    end
  end

  task automatic send_word(input logic [15:0] value, input logic last);
    begin
      rx_data <= value;
      rx_valid <= 1'b1;
      rx_last <= last;
      do @(posedge clk); while (!rx_ready);
      rx_valid <= 1'b0;
      rx_last <= 1'b0;
    end
  endtask

  task automatic send_header;
    begin
      send_word(16'h1202, 1'b0);
      send_word(16'h5634, 1'b0);
      send_word(16'hff78, 1'b0);
      send_word(16'hbbaa, 1'b0);
      send_word(16'hddcc, 1'b0);
      send_word(16'hffee, 1'b0);
      send_word(16'h0008, 1'b0);
    end
  endtask

  task automatic send_sequence(input logic [31:0] seq_value);
    begin
      // Two lane-swapped 16-bit beats represent the big-endian field.
      send_word({seq_value[23:16], seq_value[31:24]}, 1'b0);
      send_word({seq_value[7:0], seq_value[15:8]}, 1'b0);
    end
  endtask

  initial begin
    rx_data = 16'b0;
    rx_valid = 1'b0;
    rx_last = 1'b0;
    status_data = 32'b0;
    status_valid = 1'b0;

    repeat (5) @(posedge clk);
    resetn <= 1'b1;

    // Sequence zero is accepted. Exactly 1024 data bytes, excluding the
    // 32-bit sequence field, reach the DataMover.
    send_header();
    send_sequence(32'd0);
    for (integer i = 0; i < 512; i = i + 1)
      send_word(16'hA000 + i[15:0], i == 511);
    wait (frame_count == 1 && dma_busy);
    status_data <= 32'h8004_0080;
    status_valid <= 1'b1;
    do @(posedge clk); while (!status_ready);
    status_valid <= 1'b0;
    wait (!dma_busy);

    // The next legal value is one. Skipping to two must be rejected before
    // any second command or any payload beat can be issued.
    send_header();
    send_sequence(32'd2);
    send_word(16'hDEAD, 1'b0);
    send_word(16'hBEEF, 1'b1);
    repeat (5) @(posedge clk);

    if (!sequence_error)
      $fatal(1, "sequence discontinuity was not reported");
    if (frame_count != 1 || dma_write_addr != 32'h8000_0400)
      $fatal(1, "rejected gap frame changed DDR accounting");
    if (command_count != 1 || payload_count != 512 ||
        payload_last_count != 1 || dma_done_count != 1)
      $fatal(1, "rejected gap frame reached DMA cmd=%0d payload=%0d last=%0d done=%0d",
             command_count, payload_count, payload_last_count, dma_done_count);
    if (dma_error || frame_length_error)
      $fatal(1, "unexpected secondary DMA/length error");

    @(posedge clk);
    session_clear <= 1'b1;
    @(posedge clk);
    session_clear <= 1'b0;
    #1;
    if (frame_count != 0 || dma_write_addr != 32'h8000_0000 ||
        sequence_error || dma_busy)
      $fatal(1, "idle session reload did not restore protocol baseline");

    $display("TB_PASS program sequence immediate-reject/reload cmd=%0d payload=%0d",
             command_count, payload_count);
    $finish;
  end

  initial begin
    #1ms;
    $fatal(1, "global simulation timeout");
  end
endmodule
