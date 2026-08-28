// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Produces exactly one Ethernet frame's 30-beat source stream.  Only beats
// containing valid records are read from DDR1; the unused tail is generated
// locally as zero so an ECC-enabled MIG is never asked to read unwritten
// padding lines.  AXI transfers are split at 4-KiB boundaries, while the frame
// builder still observes one continuous 0..29 sequence.
module info_ddr_read_dma (
    input  logic         clk,
    input  logic         resetn,
    input  logic         start,
    input  logic         hart,
    input  logic [31:0]  frame_number,
    input  logic [5:0]   valid_records,
    output logic         busy,
    output logic         done,
    output logic         axi_error,
    output logic         protocol_error,
    axi4_if.master       axi,
    output logic         data_valid,
    output logic [511:0] data,
    output logic [4:0]   data_index,
    output logic         data_last,
    input  logic         data_ready
);
    localparam integer BEATS_PER_FRAME = 30;
    localparam logic [32:0] HART1_BASE = 33'h0_0000_0000;
    localparam logic [32:0] HART0_BASE = 33'h1_0000_0000;

    typedef enum logic [2:0] {ST_IDLE, ST_PLAN, ST_AR, ST_R, ST_PAD} state_t;
    state_t state;
    logic [32:0] address;
    logic [5:0] read_beats_remaining;
    logic [5:0] burst_beats;
    logic [5:0] burst_index;
    logic [4:0] frame_data_index;
    integer beats_to_4k;
    integer planned_beats;
    logic [32:0] frame_byte_offset;

    // 1920 = 2048 - 128, avoiding a large general multiplier.
    always_comb begin
      frame_byte_offset = ({1'b0,frame_number} << 11) -
                          ({1'b0,frame_number} << 7);
      beats_to_4k = (4096 - address[11:0]) >> 6;
      if (beats_to_4k == 0)
        beats_to_4k = 64;
      planned_beats = read_beats_remaining;
      if (planned_beats > beats_to_4k)
        planned_beats = beats_to_4k;
    end

    always_comb begin
      axi.awid = '0; axi.awaddr = '0; axi.awlen = '0;
      axi.awsize = 3'd6; axi.awburst = 2'b01; axi.awlock = 1'b0;
      axi.awcache = 4'b0011; axi.awprot = 3'b000;
      axi.awregion = 4'b0000; axi.awqos = 4'b0000;
      axi.awvalid = 1'b0; axi.wdata = '0; axi.wstrb = '0;
      axi.wlast = 1'b0; axi.wvalid = 1'b0; axi.bready = 1'b0;

      axi.arid = 4'h0;
      axi.araddr = address;
      axi.arlen = burst_beats - 1'b1;
      axi.arsize = 3'd6;
      axi.arburst = 2'b01;
      axi.arlock = 1'b0;
      axi.arcache = 4'b0011;
      axi.arprot = 3'b000;
      axi.arregion = 4'b0000;
      axi.arqos = 4'b0000;
      axi.arvalid = (state == ST_AR);
      axi.rready = (state == ST_R) && data_ready;

      data_valid = ((state == ST_R) && axi.rvalid) || (state == ST_PAD);
      data = (state == ST_PAD) ? 512'b0 : axi.rdata;
      data_index = frame_data_index;
      data_last = (frame_data_index == BEATS_PER_FRAME-1);
    end

    always_ff @(posedge clk or negedge resetn) begin
      if (!resetn) begin
        state <= ST_IDLE;
        address <= '0;
        read_beats_remaining <= 6'd0;
        burst_beats <= 6'd0;
        burst_index <= 6'd0;
        frame_data_index <= 5'd0;
        busy <= 1'b0;
        done <= 1'b0;
        axi_error <= 1'b0;
        protocol_error <= 1'b0;
      end else begin
        done <= 1'b0;
        case (state)
          ST_IDLE: begin
            busy <= 1'b0;
            if (start) begin
              address <= (hart ? HART1_BASE : HART0_BASE) +
                         frame_byte_offset;
              // Only addresses containing real records are read from DDR.
              // The output stream remains exactly 30 beats; ST_PAD supplies
              // zeros for the unused tail of the final Ethernet frame.  This
              // is required when MIG ECC is enabled because never-written
              // DDR lines do not yet contain valid ECC check bits.
              read_beats_remaining <= (valid_records + 1'b1) >> 1;
              frame_data_index <= 5'd0;
              busy <= 1'b1;
              state <= ST_PLAN;
            end
          end
          ST_PLAN: begin
            burst_beats <= planned_beats[5:0];
            burst_index <= 6'd0;
            state <= ST_AR;
          end
          ST_AR: if (axi.arvalid && axi.arready) begin
            burst_index <= 6'd0;
            state <= ST_R;
          end
          ST_R: if (axi.rvalid && axi.rready) begin
            if (axi.rresp != 2'b00)
              axi_error <= 1'b1;
            if (axi.rlast != (burst_index == burst_beats-1'b1))
              protocol_error <= 1'b1;
            address <= address + 33'd64;
            read_beats_remaining <= read_beats_remaining - 6'd1;
            if (frame_data_index != BEATS_PER_FRAME-1)
              frame_data_index <= frame_data_index + 5'd1;
            if (burst_index == burst_beats-1'b1) begin
              if (read_beats_remaining == 1) begin
                if (frame_data_index == BEATS_PER_FRAME-1) begin
                  busy <= 1'b0;
                  done <= 1'b1;
                  state <= ST_IDLE;
                end else begin
                  state <= ST_PAD;
                end
              end else begin
                state <= ST_PLAN;
              end
            end else begin
              burst_index <= burst_index + 6'd1;
            end
          end
          ST_PAD: if (data_valid && data_ready) begin
            if (frame_data_index == BEATS_PER_FRAME-1) begin
              busy <= 1'b0;
              done <= 1'b1;
              state <= ST_IDLE;
            end else begin
              frame_data_index <= frame_data_index + 5'd1;
            end
          end
          default: state <= ST_IDLE;
        endcase
      end
    end
endmodule
