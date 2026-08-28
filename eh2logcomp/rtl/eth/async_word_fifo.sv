// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module async_word_fifo #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 16
) (
    input logic wr_clk,
    input logic rd_clk,
    input logic resetn,
    input logic wr_en,
    input logic [WIDTH-1:0] wr_data,
    output logic wr_full,
    output logic wr_overflow,
    input logic rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic rd_empty
);
    xpm_fifo_async #(
      .CDC_SYNC_STAGES(3), .DOUT_RESET_VALUE("0"),
      .ECC_MODE("no_ecc"), .FIFO_MEMORY_TYPE("distributed"),
      .FIFO_READ_LATENCY(0), .FIFO_WRITE_DEPTH(DEPTH),
      .FULL_RESET_VALUE(0), .PROG_EMPTY_THRESH(5),
      .PROG_FULL_THRESH(DEPTH-6),
      .RD_DATA_COUNT_WIDTH($clog2(DEPTH)+1), .READ_DATA_WIDTH(WIDTH),
      .READ_MODE("fwft"), .RELATED_CLOCKS(0), .SIM_ASSERT_CHK(1),
      .USE_ADV_FEATURES("0707"), .WAKEUP_TIME(0),
      .WRITE_DATA_WIDTH(WIDTH), .WR_DATA_COUNT_WIDTH($clog2(DEPTH)+1)
    ) fifo_i (
      .rst(~resetn),
      .wr_clk, .wr_en, .din(wr_data), .full(wr_full),
      .overflow(wr_overflow), .wr_data_count(), .wr_rst_busy(),
      .wr_ack(), .almost_full(), .prog_full(),
      .rd_clk, .rd_en, .dout(rd_data), .empty(rd_empty),
      .underflow(), .rd_data_count(), .rd_rst_busy(),
      .almost_empty(), .prog_empty(), .data_valid(),
      .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
      .sbiterr(), .dbiterr()
    );
endmodule
