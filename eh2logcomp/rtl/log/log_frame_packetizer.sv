`timescale 1ns/1ps

module log_frame_packetizer (
  input  logic clk,
  input  logic resetn,

  input  logic [1:0][1:0]       result_valid,
  input  logic [1:0][1:0][15:0] result_package_number,
  input  logic [1:0][1:0][63:0] result_xor0,
  input  logic [1:0][1:0][63:0] result_xor1,
  input  logic [1:0][1:0][63:0] result_sum0,
  input  logic [1:0][1:0][63:0] result_sum1,
  input  logic [1:0][1:0][63:0] result_sum2,
  input  logic [1:0][1:0][63:0] result_sum3,
  input  logic [1:0][1:0][31:0] result_item_count,

  input  logic [1:0]             stopped,
  input  logic [1:0][15:0]       final_package_number,

  output logic                   waw_read_hart,
  output logic                   waw_read_bank,
  output logic [8:0]             waw_read_index,
  output logic [15:0]            waw_read_package,
  input  logic [15:0]            waw_read_sequence,
  input  logic [8:0]             waw_read_count,
  input  logic                   waw_read_package_match,
  output logic [1:0][1:0]        waw_clear_bank,

  output logic [7:0]             m_axis_tdata,
  output logic                   m_axis_tvalid,
  output logic                   m_axis_tlast,
  input  logic                   m_axis_tready,

  output logic                   frame_done,
  output logic                   all_done,
  output logic                   pending_overflow
);
  typedef enum logic [1:0] {IDLE, SNAPSHOT_WAW, SEND_FRAME} state_t;
  state_t state;

  logic [1:0][1:0] pending;
  logic [1:0][1:0][15:0] pending_package;
  logic [1:0][1:0][63:0] pending_xor0, pending_xor1;
  logic [1:0][1:0][63:0] pending_sum0, pending_sum1;
  logic [1:0][1:0][63:0] pending_sum2, pending_sum3;
  logic [1:0][1:0][31:0] pending_count;
  logic [1:0][16:0] result_seen_count;
  logic [1:0][16:0] frame_sent_count;

  logic active_hart;
  logic active_bank;
  logic [15:0] active_package;
  logic [63:0] active_xor0, active_xor1;
  logic [63:0] active_sum0, active_sum1, active_sum2, active_sum3;
  logic [31:0] active_count;
  logic [8:0] active_waw_count;
  logic [10:0] byte_index;
  logic select_valid;
  logic select_hart;
  logic select_bank;

  always_comb begin
    select_valid = 1'b0;
    select_hart  = 1'b0;
    select_bank  = 1'b0;
    if (pending[0][0]) begin
      select_valid = 1'b1; select_hart = 1'b0; select_bank = 1'b0;
    end else if (pending[0][1]) begin
      select_valid = 1'b1; select_hart = 1'b0; select_bank = 1'b1;
    end else if (pending[1][0]) begin
      select_valid = 1'b1; select_hart = 1'b1; select_bank = 1'b0;
    end else if (pending[1][1]) begin
      select_valid = 1'b1; select_hart = 1'b1; select_bank = 1'b1;
    end
  end

  assign waw_read_hart    = active_hart;
  assign waw_read_bank    = active_bank;
  assign waw_read_package = active_package;

  always_comb begin
    logic [10:0] payload_index;
    logic [10:0] sequence_byte_index;
    logic [63:0] selected_u64;

    payload_index = (byte_index >= 11'd14) ? byte_index - 11'd14 : 11'd0;
    sequence_byte_index = (payload_index >= 11'd58) ?
                          payload_index - 11'd58 : 11'd0;
    waw_read_index = sequence_byte_index[9:1];
    selected_u64 = 64'b0;

    m_axis_tvalid = (state == SEND_FRAME);
    m_axis_tlast  = (state == SEND_FRAME) && (byte_index == 11'd1037);
    m_axis_tdata  = 8'b0;

    if (byte_index <= 11'd5)
      m_axis_tdata = 8'hff;
    else begin
      case (byte_index)
        11'd6:  m_axis_tdata = 8'h02;
        11'd7:  m_axis_tdata = 8'h12;
        11'd8:  m_axis_tdata = 8'h34;
        11'd9:  m_axis_tdata = 8'h56;
        11'd10: m_axis_tdata = 8'h78;
        11'd11: m_axis_tdata = 8'hff;
        11'd12: m_axis_tdata = 8'h88;
        11'd13: m_axis_tdata = 8'hb5;
        default: begin
          if (payload_index == 0)
            m_axis_tdata = active_package[15:8];
          else if (payload_index == 1)
            m_axis_tdata = active_package[7:0];
          else if (payload_index == 2)
            m_axis_tdata = {7'b0, active_hart};
          else if (payload_index == 3)
            m_axis_tdata = 8'h00;
          else if ((payload_index >= 4) && (payload_index <= 7))
            m_axis_tdata = active_count[31 - ((payload_index-4)*8) -: 8];
          else if ((payload_index >= 8) && (payload_index <= 55)) begin
            case ((payload_index - 8) >> 3)
              0: selected_u64 = active_xor0;
              1: selected_u64 = active_xor1;
              2: selected_u64 = active_sum0;
              3: selected_u64 = active_sum1;
              4: selected_u64 = active_sum2;
              default: selected_u64 = active_sum3;
            endcase
            m_axis_tdata =
              selected_u64[63 - (((payload_index - 8) & 7)*8) -: 8];
          end else if (payload_index == 56)
            m_axis_tdata = {7'b0, active_waw_count[8]};
          else if (payload_index == 57)
            m_axis_tdata = active_waw_count[7:0];
          else if ((payload_index >= 58) &&
                   (sequence_byte_index < ({2'b0,active_waw_count} << 1)))
            m_axis_tdata = sequence_byte_index[0] ?
                           waw_read_sequence[7:0] :
                           waw_read_sequence[15:8];
          else
            m_axis_tdata = 8'h00;
        end
      endcase
    end
  end

  always_comb begin
    all_done = (stopped == 2'b11) && (pending == 4'b0) &&
               (state == IDLE) &&
               (frame_sent_count[0] >= ({1'b0,final_package_number[0]} + 17'd1)) &&
               (frame_sent_count[1] >= ({1'b0,final_package_number[1]} + 17'd1)) &&
               (result_seen_count[0] >= ({1'b0,final_package_number[0]} + 17'd1)) &&
               (result_seen_count[1] >= ({1'b0,final_package_number[1]} + 17'd1));
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state              <= IDLE;
      pending            <= 4'b0;
      pending_package    <= '0;
      pending_xor0       <= '0;
      pending_xor1       <= '0;
      pending_sum0       <= '0;
      pending_sum1       <= '0;
      pending_sum2       <= '0;
      pending_sum3       <= '0;
      pending_count      <= '0;
      result_seen_count  <= '0;
      frame_sent_count   <= '0;
      active_hart        <= 1'b0;
      active_bank        <= 1'b0;
      active_package     <= 16'b0;
      active_xor0        <= 64'b0;
      active_xor1        <= 64'b0;
      active_sum0        <= 64'b0;
      active_sum1        <= 64'b0;
      active_sum2        <= 64'b0;
      active_sum3        <= 64'b0;
      active_count       <= 32'b0;
      active_waw_count   <= 9'b0;
      byte_index         <= 11'b0;
      waw_clear_bank     <= 4'b0;
      frame_done         <= 1'b0;
      pending_overflow   <= 1'b0;
    end else begin
      waw_clear_bank <= 4'b0;
      frame_done     <= 1'b0;

      for (integer h = 0; h < 2; h = h + 1)
        begin
        if (|result_valid[h])
          result_seen_count[h] <= result_seen_count[h] +
                                  {16'b0,result_valid[h][0]} +
                                  {16'b0,result_valid[h][1]};
        for (integer b = 0; b < 2; b = b + 1)
          if (result_valid[h][b]) begin
            if (pending[h][b])
              pending_overflow <= 1'b1;
            else begin
              pending[h][b]         <= 1'b1;
              pending_package[h][b] <= result_package_number[h][b];
              pending_xor0[h][b]    <= result_xor0[h][b];
              pending_xor1[h][b]    <= result_xor1[h][b];
              pending_sum0[h][b]    <= result_sum0[h][b];
              pending_sum1[h][b]    <= result_sum1[h][b];
              pending_sum2[h][b]    <= result_sum2[h][b];
              pending_sum3[h][b]    <= result_sum3[h][b];
              pending_count[h][b]   <= result_item_count[h][b];
            end
          end
        end

      case (state)
        IDLE: begin
          byte_index <= 11'd0;
          if (select_valid) begin
            active_hart    <= select_hart;
            active_bank    <= select_bank;
            active_package <= pending_package[select_hart][select_bank];
            active_xor0    <= pending_xor0[select_hart][select_bank];
            active_xor1    <= pending_xor1[select_hart][select_bank];
            active_sum0    <= pending_sum0[select_hart][select_bank];
            active_sum1    <= pending_sum1[select_hart][select_bank];
            active_sum2    <= pending_sum2[select_hart][select_bank];
            active_sum3    <= pending_sum3[select_hart][select_bank];
            active_count   <= pending_count[select_hart][select_bank];
            state          <= SNAPSHOT_WAW;
          end
        end

        SNAPSHOT_WAW: begin
          active_waw_count <= waw_read_package_match ? waw_read_count : 9'd0;
          byte_index <= 11'd0;
          state <= SEND_FRAME;
        end

        SEND_FRAME: begin
          if (m_axis_tvalid && m_axis_tready) begin
            if (m_axis_tlast) begin
              pending[active_hart][active_bank] <= 1'b0;
              waw_clear_bank[active_hart][active_bank] <= 1'b1;
              frame_sent_count[active_hart] <=
                frame_sent_count[active_hart] + 17'd1;
              frame_done <= 1'b1;
              byte_index <= 11'd0;
              state <= IDLE;
            end else begin
              byte_index <= byte_index + 11'd1;
            end
          end
        end

        default: state <= IDLE;
      endcase
    end
  end
endmodule
