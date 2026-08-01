`timescale 1ns/1ps

module system_info_tx_formatter (
  input  logic        clk,
  input  logic        resetn,
  input  logic [31:0] fifo_code,
  input  logic        fifo_empty,
  output logic        fifo_rd_en,

  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  output logic        m_axis_tlast,
  input  logic        m_axis_tready,

  output logic        frame_done,
  output logic [31:0] sent_code
);
  logic active;
  logic [5:0] byte_index;
  logic [31:0] code_latched;

  assign fifo_rd_en   = !active && !fifo_empty;
  assign m_axis_tvalid = active;
  assign m_axis_tlast  = active && (byte_index == 6'd59);

  always_comb begin
    unique case (byte_index)
      6'd0, 6'd1, 6'd2, 6'd3, 6'd4, 6'd5:
        m_axis_tdata = 8'hFF;
      6'd6:  m_axis_tdata = 8'h02;
      6'd7:  m_axis_tdata = 8'h32;
      6'd8:  m_axis_tdata = 8'h05;
      6'd9:  m_axis_tdata = 8'h25;
      6'd10: m_axis_tdata = 8'h00;
      6'd11: m_axis_tdata = 8'hFF;
      6'd12: m_axis_tdata = 8'h88;
      6'd13: m_axis_tdata = 8'hB5;
      6'd14: m_axis_tdata = code_latched[31:24];
      6'd15: m_axis_tdata = code_latched[23:16];
      6'd16: m_axis_tdata = code_latched[15:8];
      6'd17: m_axis_tdata = code_latched[7:0];
      6'd18: m_axis_tdata = 8'h03;
      6'd19: m_axis_tdata = 8'h20;
      default: m_axis_tdata = 8'h00;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      active       <= 1'b0;
      byte_index   <= 6'd0;
      code_latched <= 32'd0;
      frame_done   <= 1'b0;
      sent_code    <= 32'd0;
    end else begin
      frame_done <= 1'b0;
      if (fifo_rd_en) begin
        code_latched <= fifo_code;
        byte_index   <= 6'd0;
        active       <= 1'b1;
      end else if (m_axis_tvalid && m_axis_tready) begin
        if (m_axis_tlast) begin
          active     <= 1'b0;
          byte_index <= 6'd0;
          frame_done <= 1'b1;
          sent_code  <= code_latched;
        end else begin
          byte_index <= byte_index + 1'b1;
        end
      end
    end
  end
endmodule
