// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Moves formatted information frames from ctrl_clk to the 125 MHz TX domain.
// A sent-code acknowledgement returns only after the frame's final byte is
// accepted at the MAC-facing AXI-stream boundary.
module system_info_tx_cdc (
    input  logic        ctrl_clk,
    input  logic        tx_clk,
    input  logic        resetn,
    input  logic [7:0]  s_tdata,
    input  logic        s_tvalid,
    input  logic        s_tlast,
    output logic        s_tready,
    input  logic        s_frame_queued,
    input  logic [31:0] s_queued_code,
    output logic        ctrl_frame_done,
    output logic [31:0] ctrl_sent_code,
    output logic [7:0]  m_tdata,
    output logic        m_tvalid,
    output logic        m_tlast,
    input  logic        m_tready,
    output logic        overflow
);
    logic frame_overflow;
    logic code_full, code_overflow, code_empty, code_rd_en;
    logic [31:0] code_tx;
    logic ack_full, ack_overflow, ack_empty, ack_rd_en;
    logic [31:0] ack_code;
    logic ack_wr_en;
    logic ctrl_overflow_sticky, tx_overflow_sticky;
    logic [0:0] tx_overflow_ctrl;

    axis_frame_fifo_async #(.DEPTH(2048)) frame_fifo_i (
      .s_clk(ctrl_clk), .m_clk(tx_clk), .resetn,
      .s_tdata, .s_tvalid, .s_tlast, .s_tready,
      .s_overflow(frame_overflow),
      .m_tdata, .m_tvalid, .m_tlast, .m_tready, .m_empty()
    );

    async_word_fifo #(.WIDTH(32), .DEPTH(16)) code_fifo_i (
      .wr_clk(ctrl_clk), .rd_clk(tx_clk), .resetn,
      .wr_en(s_frame_queued), .wr_data(s_queued_code),
      .wr_full(code_full), .wr_overflow(code_overflow),
      .rd_en(code_rd_en), .rd_data(code_tx), .rd_empty(code_empty)
    );

    assign ack_wr_en = m_tvalid && m_tready && m_tlast && !code_empty;
    assign code_rd_en = ack_wr_en;
    async_word_fifo #(.WIDTH(32), .DEPTH(16)) ack_fifo_i (
      .wr_clk(tx_clk), .rd_clk(ctrl_clk), .resetn,
      .wr_en(ack_wr_en), .wr_data(code_tx),
      .wr_full(ack_full), .wr_overflow(ack_overflow),
      .rd_en(ack_rd_en), .rd_data(ack_code), .rd_empty(ack_empty)
    );

    assign ack_rd_en = !ack_empty;
    always_ff @(posedge ctrl_clk or negedge resetn) begin
      if (!resetn) begin
        ctrl_frame_done <= 1'b0;
        ctrl_sent_code <= 32'b0;
      end else begin
        ctrl_frame_done <= ack_rd_en;
        if (ack_rd_en)
          ctrl_sent_code <= ack_code;
      end
    end

    always_ff @(posedge ctrl_clk or negedge resetn) begin
      if (!resetn)
        ctrl_overflow_sticky <= 1'b0;
      else if (frame_overflow || code_overflow ||
               (s_frame_queued && code_full))
        ctrl_overflow_sticky <= 1'b1;
    end
    always_ff @(posedge tx_clk or negedge resetn) begin
      if (!resetn)
        tx_overflow_sticky <= 1'b0;
      else if (ack_overflow ||
               (m_tvalid && m_tready && m_tlast && code_empty) ||
               (ack_wr_en && ack_full))
        tx_overflow_sticky <= 1'b1;
    end
    sync_bits #(.WIDTH(1), .STAGES(3)) overflow_sync_i (
      .clk(ctrl_clk), .resetn,
      .async_in(tx_overflow_sticky), .sync_out(tx_overflow_ctrl)
    );
    assign overflow = ctrl_overflow_sticky || tx_overflow_ctrl[0];
endmodule
