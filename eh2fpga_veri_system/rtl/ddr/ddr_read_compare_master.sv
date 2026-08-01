`timescale 1ns/1ps

// Reads a fixed, cache-line-aligned region and compares every valid byte.
// PRECONFIG instantiates this twice for the 1024-byte all-ones instruction
// and data DDR link tests.
module ddr_read_compare_master #(
  parameter logic [32:0] BASE_ADDR    = 33'h0,
  parameter integer      LENGTH_BYTES = 1024,
  parameter logic [511:0] EXPECT_DATA = {512{1'b1}},
  parameter logic [3:0] AXI_ID        = 4'h1
) (
  input  logic clk,
  input  logic resetn,
  input  logic start,
  output logic busy,
  output logic done,
  output logic pass,
  output logic error,
  output logic [31:0] mismatch_count,
  axi4_if.master m_axi
);
  localparam integer TOTAL_BEATS = LENGTH_BYTES / 64;
  localparam integer BURST_BEATS = (TOTAL_BEATS > 256) ? 256 : TOTAL_BEATS;

  typedef enum logic [2:0] {IDLE, SEND_AR, RECEIVE_R, COMPLETE, FAILED} state_t;
  state_t state;
  logic [32:0] current_addr;
  logic [31:0] beats_remaining;
  logic [8:0]  active_beats;
  logic [8:0]  beat_index;

  always_comb begin
    m_axi.awid     = AXI_ID;
    m_axi.awaddr   = 33'b0;
    m_axi.awlen    = 8'b0;
    m_axi.awsize   = 3'd6;
    m_axi.awburst  = 2'b01;
    m_axi.awlock   = 1'b0;
    m_axi.awcache  = 4'b0011;
    m_axi.awprot   = 3'b000;
    m_axi.awregion = 4'b0000;
    m_axi.awqos    = 4'b0000;
    m_axi.awvalid  = 1'b0;
    m_axi.wdata    = 512'b0;
    m_axi.wstrb    = 64'b0;
    m_axi.wlast    = 1'b0;
    m_axi.wvalid   = 1'b0;
    m_axi.bready   = 1'b1;

    m_axi.arid     = AXI_ID;
    m_axi.araddr   = current_addr;
    m_axi.arlen    = active_beats[7:0] - 8'd1;
    m_axi.arsize   = 3'd6;
    m_axi.arburst  = 2'b01;
    m_axi.arlock   = 1'b0;
    m_axi.arcache  = 4'b0011;
    m_axi.arprot   = 3'b000;
    m_axi.arregion = 4'b0000;
    m_axi.arqos    = 4'b0000;
    m_axi.arvalid  = (state == SEND_AR);
    m_axi.rready   = (state == RECEIVE_R);
    busy           = (state == SEND_AR) || (state == RECEIVE_R);
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state           <= IDLE;
      current_addr    <= BASE_ADDR;
      beats_remaining <= TOTAL_BEATS;
      active_beats    <= BURST_BEATS;
      beat_index      <= 9'd0;
      done            <= 1'b0;
      pass            <= 1'b0;
      error           <= 1'b0;
      mismatch_count  <= 32'd0;
    end else begin
      case (state)
        IDLE: begin
          if (start) begin
            current_addr    <= BASE_ADDR;
            beats_remaining <= TOTAL_BEATS;
            active_beats    <= BURST_BEATS;
            beat_index      <= 9'd0;
            pass            <= 1'b0;
            error           <= 1'b0;
            mismatch_count  <= 32'd0;
            done            <= 1'b0;
            state           <= SEND_AR;
          end
        end

        SEND_AR: begin
          if (m_axi.arvalid && m_axi.arready) begin
            beat_index <= 9'd0;
            state      <= RECEIVE_R;
          end
        end

        RECEIVE_R: begin
          if (m_axi.rvalid && m_axi.rready) begin
            if ((m_axi.rresp != 2'b00) || (m_axi.rid != AXI_ID)) begin
              error <= 1'b1;
              done  <= 1'b1;
              state <= FAILED;
            end else begin
              if (m_axi.rdata != EXPECT_DATA)
                mismatch_count <= mismatch_count + 32'd1;
              if (m_axi.rlast != (beat_index == (active_beats - 9'd1))) begin
                error <= 1'b1;
                done  <= 1'b1;
                state <= FAILED;
              end else if (m_axi.rlast) begin
                current_addr    <= current_addr + ({24'b0, active_beats} << 6);
                beats_remaining <= beats_remaining - active_beats;
                if (beats_remaining == active_beats) begin
                  pass <= (mismatch_count == 0) && (m_axi.rdata == EXPECT_DATA);
                  done <= 1'b1;
                  state <= COMPLETE;
                end else begin
                  if ((beats_remaining - active_beats) > 32'd256)
                    active_beats <= 9'd256;
                  else
                    active_beats <= beats_remaining - active_beats;
                  state <= SEND_AR;
                end
              end else begin
                beat_index <= beat_index + 9'd1;
              end
            end
          end
        end

        COMPLETE: begin
          done <= 1'b1;
          if (!start)
            state <= IDLE;
        end

        FAILED: begin
          done <= 1'b1;
          if (!start)
            state <= IDLE;
        end

        default: begin
          error <= 1'b1;
          state <= FAILED;
        end
      endcase
    end
  end
endmodule
