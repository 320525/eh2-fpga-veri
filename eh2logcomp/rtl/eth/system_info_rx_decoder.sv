`timescale 1ns/1ps

module system_info_rx_decoder (
  input  logic        clk,
  input  logic        resetn,
  input  logic [15:0] fifo_data,
  input  logic        fifo_last,
  input  logic        fifo_empty,
  output logic        fifo_rd_en,
  output logic        program_end_pulse,
  output logic [31:0] program_end_total_count,
  output logic        host_send_stopped_pulse,
  output logic        host_global_reset_pulse,
  output logic        host_info_retransmit_all_pulse,
  output logic        malformed_frame
);
  logic [4:0] word_index;
  logic marker_word0;
  logic marker_word1;
  logic stop_word0;
  logic stop_word1;
  logic end_reserved_nonzero;
  logic stop_reserved_nonzero;
  logic reset_word0;
  logic reset_word1;
  logic reset_reserved_nonzero;
  logic retransmit_word0;
  logic retransmit_word1;
  logic retransmit_reserved_nonzero;

  assign fifo_rd_en = !fifo_empty;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      word_index        <= 5'd0;
      marker_word0      <= 1'b0;
      marker_word1      <= 1'b0;
      stop_word0        <= 1'b0;
      stop_word1        <= 1'b0;
      end_reserved_nonzero <= 1'b0;
      stop_reserved_nonzero <= 1'b0;
      reset_word0       <= 1'b0;
      reset_word1       <= 1'b0;
      reset_reserved_nonzero <= 1'b0;
      retransmit_word0  <= 1'b0;
      retransmit_word1  <= 1'b0;
      retransmit_reserved_nonzero <= 1'b0;
      program_end_pulse <= 1'b0;
      program_end_total_count <= 32'b0;
      host_send_stopped_pulse <= 1'b0;
      host_global_reset_pulse <= 1'b0;
      host_info_retransmit_all_pulse <= 1'b0;
      malformed_frame   <= 1'b0;
    end else begin
      program_end_pulse <= 1'b0;
      host_send_stopped_pulse <= 1'b0;
      host_global_reset_pulse <= 1'b0;
      malformed_frame   <= 1'b0;

      if (fifo_rd_en) begin
        if (word_index == 0) begin
          marker_word0 <= (fifo_data == 16'hFFFF);
          // FIFO lane zero is the first byte on the wire: 44 12 -> 16'h1244.
          stop_word0 <= (fifo_data == 16'h1244);
          // HOST_GLOBAL_RESET 44 13 44 45 -> FIFO words 1344, 4544.
          reset_word0 <= (fifo_data == 16'h1344);
          // HOST_INFO_RETRANSMIT_ALL 44 14 44 45 -> 1444, 4544.
          retransmit_word0 <= (fifo_data == 16'h1444);
        end
        if (word_index == 1) begin
          marker_word1 <= (fifo_data == 16'hFFFF);
          // Remaining code bytes are 44 45 -> 16'h4544.
          stop_word1 <= (fifo_data == 16'h4544);
          reset_word1 <= (fifo_data == 16'h4544);
          retransmit_word1 <= (fifo_data == 16'h4544);
        end
        if (word_index == 2)
          program_end_total_count[31:16] <= {fifo_data[7:0], fifo_data[15:8]};
        if (word_index == 3)
          program_end_total_count[15:0] <= {fifo_data[7:0], fifo_data[15:8]};
        if ((word_index >= 4) && (fifo_data != 16'h0000))
          end_reserved_nonzero <= 1'b1;
        if ((word_index >= 2) && (fifo_data != 16'h0000))
          stop_reserved_nonzero <= 1'b1;
        if ((word_index >= 2) && (fifo_data != 16'h0000))
          reset_reserved_nonzero <= 1'b1;
        if ((word_index >= 2) && (fifo_data != 16'h0000))
          retransmit_reserved_nonzero <= 1'b1;

        if (fifo_last) begin
          if (word_index != 5'd22) begin
            malformed_frame <= 1'b1;
          end else if (marker_word0 && marker_word1 &&
                       !end_reserved_nonzero &&
                       !((word_index >= 4) && (fifo_data != 16'h0000))) begin
            program_end_pulse <= 1'b1;
          end else if (marker_word0 && marker_word1) begin
            malformed_frame <= 1'b1;
          end else if (stop_word0 && stop_word1 &&
                       !stop_reserved_nonzero &&
                       !((word_index >= 2) && (fifo_data != 16'h0000))) begin
            host_send_stopped_pulse <= 1'b1;
          end else if (stop_word0 && stop_word1) begin
            malformed_frame <= 1'b1;
          end else if (reset_word0 && reset_word1 &&
                       !reset_reserved_nonzero &&
                       !((word_index >= 2) && (fifo_data != 16'h0000))) begin
            host_global_reset_pulse <= 1'b1;
          end else if (reset_word0 && reset_word1) begin
            malformed_frame <= 1'b1;
          end else if (retransmit_word0 && retransmit_word1 &&
                       !retransmit_reserved_nonzero &&
                       !((word_index >= 2) && (fifo_data != 16'h0000))) begin
            host_info_retransmit_all_pulse <= 1'b1;
          end else if (retransmit_word0 && retransmit_word1) begin
            malformed_frame <= 1'b1;
          end
          word_index   <= 5'd0;
          marker_word0 <= 1'b0;
          marker_word1 <= 1'b0;
          stop_word0   <= 1'b0;
          stop_word1   <= 1'b0;
          reset_word0  <= 1'b0;
          reset_word1  <= 1'b0;
          retransmit_word0 <= 1'b0;
          retransmit_word1 <= 1'b0;
          end_reserved_nonzero <= 1'b0;
          stop_reserved_nonzero <= 1'b0;
          reset_reserved_nonzero <= 1'b0;
          retransmit_reserved_nonzero <= 1'b0;
        end else begin
          word_index <= word_index + 1'b1;
        end
      end
    end
  end
endmodule
