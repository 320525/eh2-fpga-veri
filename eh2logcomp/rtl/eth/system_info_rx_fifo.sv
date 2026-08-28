`timescale 1ns/1ps

module system_info_rx_fifo #(
  parameter int DEPTH = 128
) (
  input  logic        clk,
  input  logic        resetn,
  input  logic        wr_en,
  input  logic [15:0] wr_data,
  input  logic        wr_last,
  output logic        full,
  output logic        overflow,
  input  logic        rd_en,
  output logic [15:0] rd_data,
  output logic        rd_last,
  output logic        empty
);
  logic [16:0] fifo_rd_data;
  logic [$clog2(DEPTH):0] unused_count;
  logic unused_underflow;

  sync_fifo #(.WIDTH(17), .DEPTH(DEPTH)) fifo_i (
    .clk, .resetn, .clear(1'b0),
    .wr_en, .wr_data({wr_last, wr_data}), .full, .overflow,
    .rd_en, .rd_data(fifo_rd_data), .empty,
    .underflow(unused_underflow), .count(unused_count)
  );
  assign {rd_last, rd_data} = fifo_rd_data;
endmodule
