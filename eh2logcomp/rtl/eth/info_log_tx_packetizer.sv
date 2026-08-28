// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Serializes DDR records into maximum standard Ethernet payloads.  Each data
// frame carries exactly 1472 payload bytes (46 records); the final payload is
// zero padded.  A 46-byte completion payload follows each hart's data frames.
module info_log_tx_packetizer #(
    parameter logic [47:0] DEST_MAC = 48'hFFFF_FFFF_FFFF,
    parameter logic [47:0] HART0_MAC = 48'h0232_0525_1000,
    parameter logic [47:0] HART1_MAC = 48'h0232_0525_1001,
    parameter logic [15:0] DATA_ETHERTYPE = 16'h88B7,
    parameter logic [15:0] DONE_ETHERTYPE = 16'h88B8
) (
    input  logic         clk,
    input  logic         resetn,
    input  logic         start,
    input  logic         hart,
    input  logic [31:0]  total_records,
    input  logic [511:0] beat_data,
    input  logic         beat_valid,
    output logic         beat_ready,
    output logic [7:0]   m_axis_tdata,
    output logic         m_axis_tvalid,
    output logic         m_axis_tlast,
    input  logic         m_axis_tready,
    output logic         busy,
    output logic         done
);
    localparam integer RECORDS_PER_FRAME = 46;
    localparam integer PAYLOAD_BYTES = 1472;
    typedef enum logic [2:0] {
      ST_IDLE, ST_DATA_HEADER, ST_DATA_PAYLOAD,
      ST_DONE_HEADER, ST_DONE_PAYLOAD
    } state_t;
    state_t state;
    logic active_hart;
    logic [31:0] active_total;
    logic [31:0] records_sent;
    logic [31:0] frame_index;
    logic [10:0] byte_index;
    logic [7:0] header_index;
    logic [5:0] done_index;
    logic [511:0] beat_hold;
    logic beat_hold_valid;
    logic [5:0] beat_byte_index;
    logic [31:0] frames_total;
    logic [47:0] source_mac;
    logic need_real_byte;
    logic [31:0] current_payload_record;

    assign source_mac = active_hart ? HART1_MAC : HART0_MAC;
    assign frames_total = (active_total + RECORDS_PER_FRAME-1) /
                          RECORDS_PER_FRAME;
    assign current_payload_record = frame_index * RECORDS_PER_FRAME +
                                    (byte_index >> 5);
    assign need_real_byte = current_payload_record < active_total;
    assign beat_ready = (state == ST_DATA_PAYLOAD) && need_real_byte &&
                        !beat_hold_valid;

    always_comb begin
      m_axis_tdata = 8'h00;
      m_axis_tvalid = 1'b0;
      m_axis_tlast = 1'b0;
      case (state)
        ST_DATA_HEADER, ST_DONE_HEADER: begin
          m_axis_tvalid = 1'b1;
          case (header_index)
            0: m_axis_tdata = DEST_MAC[47:40];
            1: m_axis_tdata = DEST_MAC[39:32];
            2: m_axis_tdata = DEST_MAC[31:24];
            3: m_axis_tdata = DEST_MAC[23:16];
            4: m_axis_tdata = DEST_MAC[15:8];
            5: m_axis_tdata = DEST_MAC[7:0];
            6: m_axis_tdata = source_mac[47:40];
            7: m_axis_tdata = source_mac[39:32];
            8: m_axis_tdata = source_mac[31:24];
            9: m_axis_tdata = source_mac[23:16];
            10: m_axis_tdata = source_mac[15:8];
            11: m_axis_tdata = source_mac[7:0];
            12: m_axis_tdata = (state == ST_DATA_HEADER) ?
                               DATA_ETHERTYPE[15:8] : DONE_ETHERTYPE[15:8];
            default: m_axis_tdata = (state == ST_DATA_HEADER) ?
                                    DATA_ETHERTYPE[7:0] : DONE_ETHERTYPE[7:0];
          endcase
        end
        ST_DATA_PAYLOAD: begin
          m_axis_tvalid = !need_real_byte || beat_hold_valid;
          if (need_real_byte)
            // Lower record first; each record itself is sent MSB first.
            m_axis_tdata = beat_byte_index < 32 ?
              beat_hold[255 - (beat_byte_index*8) -: 8] :
              beat_hold[511 - ((beat_byte_index-32)*8) -: 8];
          else
            m_axis_tdata = 8'h00;
          m_axis_tlast = (byte_index == PAYLOAD_BYTES-1);
        end
        ST_DONE_PAYLOAD: begin
          m_axis_tvalid = 1'b1;
          m_axis_tlast = (done_index == 45);
          case (done_index)
            0: m_axis_tdata = active_hart ? 8'h48 : 8'h48;
            1: m_axis_tdata = active_hart ? 8'h31 : 8'h30;
            2: m_axis_tdata = 8'h44;
            3: m_axis_tdata = 8'h4E;
            4: m_axis_tdata = {7'b0, active_hart};
            5: m_axis_tdata = 8'h01;
            6: m_axis_tdata = 8'h00;
            7: m_axis_tdata = 8'h20;
            8: m_axis_tdata = active_total[31:24];
            9: m_axis_tdata = active_total[23:16];
            10: m_axis_tdata = active_total[15:8];
            11: m_axis_tdata = active_total[7:0];
            12: m_axis_tdata = frames_total[31:24];
            13: m_axis_tdata = frames_total[23:16];
            14: m_axis_tdata = frames_total[15:8];
            15: m_axis_tdata = frames_total[7:0];
            16: m_axis_tdata = active_total == 0 ? 8'hFF :
                                ((active_total-1) >> 24);
            17: m_axis_tdata = active_total == 0 ? 8'hFF :
                                ((active_total-1) >> 16);
            18: m_axis_tdata = active_total == 0 ? 8'hFF :
                                ((active_total-1) >> 8);
            19: m_axis_tdata = active_total == 0 ? 8'hFF :
                                (active_total-1);
            20: m_axis_tdata = 8'h00;
            21: m_axis_tdata = 8'h00;
            22: m_axis_tdata = 8'h00;
            23: m_axis_tdata = {7'b0, ~active_hart};
            default: m_axis_tdata = 8'h00;
          endcase
        end
        default: begin end
      endcase
    end

    always_ff @(posedge clk or negedge resetn) begin
      if (!resetn) begin
        state <= ST_IDLE;
        active_hart <= 1'b0;
        active_total <= 0;
        records_sent <= 0;
        frame_index <= 0;
        byte_index <= 0;
        header_index <= 0;
        done_index <= 0;
        beat_hold <= 0;
        beat_hold_valid <= 1'b0;
        beat_byte_index <= 0;
        busy <= 1'b0;
        done <= 1'b0;
      end else begin
        done <= 1'b0;
        if (beat_ready && beat_valid) begin
          beat_hold <= beat_data;
          beat_hold_valid <= 1'b1;
          beat_byte_index <= 0;
        end

        case (state)
          ST_IDLE: if (start) begin
            active_hart <= hart;
            active_total <= total_records;
            records_sent <= 0;
            frame_index <= 0;
            header_index <= 0;
            busy <= 1'b1;
            state <= total_records == 0 ? ST_DONE_HEADER : ST_DATA_HEADER;
          end
          ST_DATA_HEADER: if (m_axis_tvalid && m_axis_tready) begin
            if (header_index == 13) begin
              header_index <= 0;
              byte_index <= 0;
              state <= ST_DATA_PAYLOAD;
            end else
              header_index <= header_index + 1'b1;
          end
          ST_DATA_PAYLOAD: if (m_axis_tvalid && m_axis_tready) begin
            if (need_real_byte) begin
              if ((beat_byte_index == 63) ||
                  (((current_payload_record + 1) == active_total) &&
                   (byte_index[4:0] == 5'd31))) begin
                beat_hold_valid <= 1'b0;
                beat_byte_index <= 0;
              end else
                beat_byte_index <= beat_byte_index + 1'b1;
            end
            if (byte_index == PAYLOAD_BYTES-1) begin
              if (frame_index + 1 == frames_total) begin
                header_index <= 0;
                state <= ST_DONE_HEADER;
              end else begin
                frame_index <= frame_index + 1'b1;
                header_index <= 0;
                state <= ST_DATA_HEADER;
              end
            end else
              byte_index <= byte_index + 1'b1;
          end
          ST_DONE_HEADER: if (m_axis_tvalid && m_axis_tready) begin
            if (header_index == 13) begin
              header_index <= 0;
              done_index <= 0;
              state <= ST_DONE_PAYLOAD;
            end else
              header_index <= header_index + 1'b1;
          end
          ST_DONE_PAYLOAD: if (m_axis_tvalid && m_axis_tready) begin
            if (done_index == 45) begin
              busy <= 1'b0;
              done <= 1'b1;
              state <= ST_IDLE;
            end else
              done_index <= done_index + 1'b1;
          end
          default: state <= ST_IDLE;
        endcase
      end
    end
endmodule
