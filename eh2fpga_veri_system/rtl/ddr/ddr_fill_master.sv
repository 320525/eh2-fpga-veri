`timescale 1ns/1ps

// Full-width AXI4 fill engine.  READY uses 256-beat, 16 KiB bursts so the
// low 4 GiB data-DDR clear runs at the native 512-bit MIG UI width without
// changing the validated MIG configuration.
module ddr_fill_master #(
  parameter logic [32:0] BASE_ADDR    = 33'h0,
  parameter logic [32:0] LENGTH_BYTES = 33'h1_0000_0000,
  parameter logic [511:0] FILL_DATA   = 512'b0,
  parameter logic [3:0] AXI_ID        = 4'h0
) (
  input  logic clk,
  input  logic resetn,
  input  logic start,
  output logic busy,
  output logic done,
  output logic error,
  output logic [32:0] bytes_completed,
  axi4_if.master m_axi
);
  typedef enum logic [2:0] {IDLE, SEND_AW, SEND_W, WAIT_B, COMPLETE, FAILED} state_t;
  state_t state;

  logic [32:0] current_addr;
  logic [32:0] beats_remaining;
  logic [8:0]  burst_beats;
  logic [8:0]  beat_index;

  always_comb begin
    m_axi.awid     = AXI_ID;
    m_axi.awaddr   = current_addr;
    m_axi.awlen    = burst_beats[7:0] - 8'd1;
    m_axi.awsize   = 3'd6;
    m_axi.awburst  = 2'b01;
    m_axi.awlock   = 1'b0;
    m_axi.awcache  = 4'b0011;
    m_axi.awprot   = 3'b000;
    m_axi.awregion = 4'b0000;
    m_axi.awqos    = 4'b0000;
    m_axi.awvalid  = (state == SEND_AW);

    m_axi.wdata    = FILL_DATA;
    m_axi.wstrb    = 64'hffff_ffff_ffff_ffff;
    m_axi.wlast    = (beat_index == (burst_beats - 9'd1));
    m_axi.wvalid   = (state == SEND_W);
    m_axi.bready   = (state == WAIT_B);

    m_axi.arid     = AXI_ID;
    m_axi.araddr   = 33'b0;
    m_axi.arlen    = 8'b0;
    m_axi.arsize   = 3'd6;
    m_axi.arburst  = 2'b01;
    m_axi.arlock   = 1'b0;
    m_axi.arcache  = 4'b0011;
    m_axi.arprot   = 3'b000;
    m_axi.arregion = 4'b0000;
    m_axi.arqos    = 4'b0000;
    m_axi.arvalid  = 1'b0;
    m_axi.rready   = 1'b1;

    busy = (state == SEND_AW) || (state == SEND_W) || (state == WAIT_B);
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state           <= IDLE;
      current_addr    <= BASE_ADDR;
      beats_remaining <= LENGTH_BYTES >> 6;
      burst_beats     <= 9'd0;
      beat_index      <= 9'd0;
      bytes_completed <= 33'd0;
      done            <= 1'b0;
      error           <= 1'b0;
    end else begin
      case (state)
        IDLE: begin
          if (start) begin
            current_addr    <= BASE_ADDR;
            beats_remaining <= LENGTH_BYTES >> 6;
            bytes_completed <= 33'd0;
            error           <= 1'b0;
            done            <= 1'b0;
            beat_index      <= 9'd0;
            if (LENGTH_BYTES == 0) begin
              done  <= 1'b1;
              state <= COMPLETE;
            end else begin
              burst_beats <= ((LENGTH_BYTES >> 6) > 33'd256) ?
                             9'd256 : (LENGTH_BYTES >> 6);
              state <= SEND_AW;
            end
          end
        end

        SEND_AW: begin
          if (m_axi.awvalid && m_axi.awready) begin
            beat_index <= 9'd0;
            state      <= SEND_W;
          end
        end

        SEND_W: begin
          if (m_axi.wvalid && m_axi.wready) begin
            if (m_axi.wlast)
              state <= WAIT_B;
            else
              beat_index <= beat_index + 9'd1;
          end
        end

        WAIT_B: begin
          if (m_axi.bvalid && m_axi.bready) begin
            if ((m_axi.bresp != 2'b00) || (m_axi.bid != AXI_ID)) begin
              error <= 1'b1;
              done  <= 1'b1;
              state <= FAILED;
            end else begin
              bytes_completed <= bytes_completed + ({24'b0, burst_beats} << 6);
              current_addr    <= current_addr + ({24'b0, burst_beats} << 6);
              beats_remaining <= beats_remaining - burst_beats;
              if (beats_remaining == burst_beats) begin
                done  <= 1'b1;
                state <= COMPLETE;
              end else begin
                if ((beats_remaining - burst_beats) > 33'd256)
                  burst_beats <= 9'd256;
                else
                  burst_beats <= beats_remaining - burst_beats;
                state <= SEND_AW;
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

        default: state <= FAILED;
      endcase
    end
  end
endmodule
