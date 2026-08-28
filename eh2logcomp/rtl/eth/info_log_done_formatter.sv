// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Completion frame for one hart.  This keeps the established 46-byte payload
// and EtherType while the data frames use the new 1444-byte/60-record format.
module info_log_done_formatter #(
    parameter logic [47:0] DEST_MAC = 48'hFFFF_FFFF_FFFF,
    parameter logic [47:0] HART0_MAC = 48'h0232_0525_1000,
    parameter logic [47:0] HART1_MAC = 48'h0232_0525_1001,
    parameter logic [15:0] DONE_ETHERTYPE = 16'h88B8
) (
    input  logic        clk,
    input  logic        resetn,
    input  logic        start,
    input  logic        hart,
    input  logic [31:0] total_records,
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready,
    output logic        busy,
    output logic        done
);
    typedef enum logic [1:0] {ST_IDLE, ST_HEADER, ST_PAYLOAD} state_t;
    state_t state;
    logic active_hart;
    logic [31:0] active_total;
    logic [4:0] header_index;
    logic [5:0] payload_index;
    logic [31:0] frames_total;
    logic [47:0] source_mac;

    assign source_mac = active_hart ? HART1_MAC : HART0_MAC;
    assign frames_total = (active_total + 32'd59) / 32'd60;

    always_comb begin
      m_axis_tdata = 8'h00;
      m_axis_tvalid = 1'b0;
      m_axis_tlast = 1'b0;
      if (state == ST_HEADER) begin
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
          12: m_axis_tdata = DONE_ETHERTYPE[15:8];
          default: m_axis_tdata = DONE_ETHERTYPE[7:0];
        endcase
      end else if (state == ST_PAYLOAD) begin
        m_axis_tvalid = 1'b1;
        m_axis_tlast = (payload_index == 45);
        case (payload_index)
          0: m_axis_tdata = 8'h48;
          1: m_axis_tdata = active_hart ? 8'h31 : 8'h30;
          2: m_axis_tdata = 8'h44;
          3: m_axis_tdata = 8'h4E;
          4: m_axis_tdata = {7'b0,active_hart};
          5: m_axis_tdata = 8'h01;
          6: m_axis_tdata = 8'h00;
          7: m_axis_tdata = 8'h18;
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
          23: m_axis_tdata = {7'b0,~active_hart};
          default: m_axis_tdata = 8'h00;
        endcase
      end
    end

    always_ff @(posedge clk or negedge resetn) begin
      if (!resetn) begin
        state <= ST_IDLE;
        active_hart <= 1'b0;
        active_total <= 32'b0;
        header_index <= 5'd0;
        payload_index <= 6'd0;
        busy <= 1'b0;
        done <= 1'b0;
      end else begin
        done <= 1'b0;
        case (state)
          ST_IDLE: if (start) begin
            active_hart <= hart;
            active_total <= total_records;
            header_index <= 5'd0;
            busy <= 1'b1;
            state <= ST_HEADER;
          end
          ST_HEADER: if (m_axis_tvalid && m_axis_tready) begin
            if (header_index == 13) begin
              payload_index <= 6'd0;
              state <= ST_PAYLOAD;
            end else
              header_index <= header_index + 5'd1;
          end
          ST_PAYLOAD: if (m_axis_tvalid && m_axis_tready) begin
            if (payload_index == 45) begin
              busy <= 1'b0;
              done <= 1'b1;
              state <= ST_IDLE;
            end else
              payload_index <= payload_index + 6'd1;
          end
          default: state <= ST_IDLE;
        endcase
      end
    end
endmodule
