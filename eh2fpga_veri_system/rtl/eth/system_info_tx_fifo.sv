`timescale 1ns/1ps

module system_info_tx_fifo #(
  parameter int DEPTH = 16
) (
  input  logic        clk,
  input  logic        resetn,
  input  logic        wr_en,
  input  logic [31:0] wr_code,
  output logic        full,
  output logic        overflow,
  input  logic        rd_en,
  output logic [31:0] rd_code,
  output logic        empty
);
  logic [$clog2(DEPTH):0] unused_count;
  logic unused_underflow;
  sync_fifo #(.WIDTH(32), .DEPTH(DEPTH)) fifo_i (
    .clk, .resetn, .clear(1'b0),
    .wr_en, .wr_data(wr_code), .full, .overflow,
    .rd_en, .rd_data(rd_code), .empty,
    .underflow(unused_underflow), .count(unused_count)
  );
endmodule
