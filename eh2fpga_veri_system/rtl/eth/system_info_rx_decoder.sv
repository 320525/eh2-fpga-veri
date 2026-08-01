`timescale 1ns/1ps

module system_info_rx_decoder (
  input  logic        clk,
  input  logic        resetn,
  input  logic [15:0] fifo_data,
  input  logic        fifo_last,
  input  logic        fifo_empty,
  output logic        fifo_rd_en,
  output logic        program_end_pulse,
  output logic        malformed_frame
);
  logic [4:0] word_index;
  logic marker_word0;
  logic marker_word1;

  assign fifo_rd_en = !fifo_empty;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      word_index        <= 5'd0;
      marker_word0      <= 1'b0;
      marker_word1      <= 1'b0;
      program_end_pulse <= 1'b0;
      malformed_frame   <= 1'b0;
    end else begin
      program_end_pulse <= 1'b0;
      malformed_frame   <= 1'b0;

      if (fifo_rd_en) begin
        if (word_index == 0)
          marker_word0 <= (fifo_data == 16'hFFFF);
        if (word_index == 1)
          marker_word1 <= (fifo_data == 16'hFFFF);

        if (fifo_last) begin
          if (word_index != 5'd22) begin
            malformed_frame <= 1'b1;
          end else if (marker_word0 && marker_word1) begin
            program_end_pulse <= 1'b1;
          end
          word_index   <= 5'd0;
          marker_word0 <= 1'b0;
          marker_word1 <= 1'b0;
        end else begin
          word_index <= word_index + 1'b1;
        end
      end
    end
  end
endmodule
