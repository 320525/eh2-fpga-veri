// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module axis_frame_fifo_async #(
    parameter integer DEPTH = 2048
) (
    input  logic       s_clk,
    input  logic       m_clk,
    input  logic       resetn,
    input  logic [7:0] s_tdata,
    input  logic       s_tvalid,
    input  logic       s_tlast,
    output logic       s_tready,
    output logic       s_overflow,
    output logic [7:0] m_tdata,
    output logic       m_tvalid,
    output logic       m_tlast,
    input  logic       m_tready,
    output logic       m_empty
);
    logic [8:0] fifo_din, fifo_dout;
    logic full, empty, overflow, underflow;
    logic wr_rst_busy, rd_rst_busy;
    assign fifo_din = {s_tlast, s_tdata};
    assign s_tready = !full && !wr_rst_busy;
    assign m_tvalid = !empty && !rd_rst_busy;
    assign {m_tlast,m_tdata} = fifo_dout;
    assign m_empty = empty;

    always_ff @(posedge s_clk or negedge resetn) begin
      if (!resetn)
        s_overflow <= 1'b0;
      else if (overflow)
        s_overflow <= 1'b1;
    end

    xpm_fifo_async #(
      .CDC_SYNC_STAGES(3), .DOUT_RESET_VALUE("0"),
      .ECC_MODE("no_ecc"), .FIFO_MEMORY_TYPE("block"),
      .FIFO_READ_LATENCY(0), .FIFO_WRITE_DEPTH(DEPTH),
      .FULL_RESET_VALUE(0), .PROG_EMPTY_THRESH(8),
      .PROG_FULL_THRESH(DEPTH-16),
      .RD_DATA_COUNT_WIDTH($clog2(DEPTH)+1), .READ_DATA_WIDTH(9),
      .READ_MODE("fwft"), .RELATED_CLOCKS(0), .SIM_ASSERT_CHK(1),
      .USE_ADV_FEATURES("0707"), .WAKEUP_TIME(0),
      .WRITE_DATA_WIDTH(9), .WR_DATA_COUNT_WIDTH($clog2(DEPTH)+1)
    ) fifo_i (
      .rst(~resetn),
      .wr_clk(s_clk), .wr_en(s_tvalid && s_tready), .din(fifo_din),
      .full, .overflow, .wr_data_count(), .wr_rst_busy,
      .wr_ack(), .almost_full(), .prog_full(),
      .rd_clk(m_clk), .rd_en(m_tvalid && m_tready), .dout(fifo_dout),
      .empty, .underflow, .rd_data_count(), .rd_rst_busy,
      .almost_empty(), .prog_empty(), .data_valid(),
      .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
      .sbiterr(), .dbiterr()
    );
endmodule
