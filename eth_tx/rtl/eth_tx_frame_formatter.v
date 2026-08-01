`timescale 1ns / 1ps

// Converts each 64-byte AXI-Stream transaction produced by the Xilinx ATG
// into one complete MAC client frame.  The ATG remains the transaction and
// backpressure owner; this block only prepends the Ethernet header and makes
// the payload deterministic for board and simulation checking.
module eth_tx_frame_formatter #(
  // 0x88B5 is reserved for local experimental use and is interpreted as an
  // EtherType by host NICs.  Values below 0x0600 (such as 0x0400) are IEEE
  // 802.3 length fields and can be discarded as malformed when the declared
  // length does not match the actual payload.
  parameter [15:0] ETHERTYPE = 16'h88B5
) (
  input  wire        clk,
  input  wire        resetn,

  input  wire [7:0]  s_axis_tdata,
  input  wire        s_axis_tvalid,
  input  wire        s_axis_tlast,
  output wire        s_axis_tready,

  output reg  [7:0]  m_axis_tdata,
  output wire        m_axis_tvalid,
  output wire        m_axis_tlast,
  input  wire        m_axis_tready,

  output reg  [3:0]  frame_count,
  output reg         length_error
);

  localparam HEADER = 1'b0;
  localparam PAYLOAD = 1'b1;

  reg       state;
  reg [3:0] header_index;
  reg [6:0] payload_index;

  // The ATG source byte is intentionally consumed for every payload beat.
  // Its deterministic seed sequence is replaced with an easier-to-observe
  // 00..3F count while preserving ATG ownership of TVALID/TLAST/backpressure.
  wire unused_s_axis_tdata = ^s_axis_tdata;

  assign m_axis_tvalid = s_axis_tvalid;
  assign m_axis_tlast  = (state == PAYLOAD) && s_axis_tlast;
  assign s_axis_tready = (state == PAYLOAD) && m_axis_tready;

  always @* begin
    if (state == PAYLOAD) begin
      m_axis_tdata = {1'b0, payload_index};
    end
    else begin
      case (header_index)
        4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5:
          m_axis_tdata = 8'hFF;
        4'd6:  m_axis_tdata = 8'h02;
        4'd7:  m_axis_tdata = 8'h12;
        4'd8:  m_axis_tdata = 8'h34;
        4'd9:  m_axis_tdata = 8'h56;
        4'd10: m_axis_tdata = 8'h78;
        4'd11: m_axis_tdata = 8'hFF;
        4'd12: m_axis_tdata = ETHERTYPE[15:8];
        4'd13: m_axis_tdata = ETHERTYPE[7:0];
        default: m_axis_tdata = 8'h00;
      endcase
    end
  end

  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state         <= HEADER;
      header_index  <= 4'd0;
      payload_index <= 7'd0;
      frame_count   <= 4'd0;
      length_error  <= 1'b0;
    end
    else if (m_axis_tvalid && m_axis_tready) begin
      if (state == HEADER) begin
        if (header_index == 4'd13) begin
          state         <= PAYLOAD;
          header_index  <= 4'd0;
          payload_index <= 7'd0;
        end
        else begin
          header_index <= header_index + 1'b1;
        end
      end
      else if (s_axis_tlast) begin
        if (payload_index != 7'd63)
          length_error <= 1'b1;
        state         <= HEADER;
        payload_index <= 7'd0;
        frame_count   <= frame_count + 1'b1;
      end
      else begin
        if (payload_index == 7'd63)
          length_error <= 1'b1;
        payload_index <= payload_index + 1'b1;
      end
    end
  end

endmodule
