// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Writes one frozen 512-record information bank at a time to DDR1.  The
// producer-side FIFO has already stopped modifying a claimed bank, so this
// DMA can commit its exact record count before releasing that bank for reuse.
// If both harts have a ready bank, the priority token alternates only after a
// *whole bank* has completed; the four legal 64-beat AXI bursts belonging to
// a 512-record bank are never interleaved with the other hart.
module info_ddr_pingpong_write_dma #(
    parameter logic [33:0] HART1_BASE = 34'h0_0000_0000,
    parameter logic [33:0] HART0_BASE = 34'h1_0000_0000,
    parameter logic [33:0] HART1_LIMIT = 34'h1_0000_0000,
    parameter logic [33:0] HART0_LIMIT = 34'h2_0000_0000
) (
    input  logic         clk,
    input  logic         rst_l,
    input  logic         capture_done,

    input  logic         h0_batch_valid,
    input  logic [9:0]   h0_batch_record_count,
    output logic         h0_batch_claim,
    output logic         h0_batch_done,
    input  logic         h0_valid,
    input  logic [511:0] h0_data,
    input  logic [1:0]   h0_record_count,
    input  logic         h0_empty,
    output logic         h0_ready,

    input  logic         h1_batch_valid,
    input  logic [9:0]   h1_batch_record_count,
    output logic         h1_batch_claim,
    output logic         h1_batch_done,
    input  logic         h1_valid,
    input  logic [511:0] h1_data,
    input  logic [1:0]   h1_record_count,
    input  logic         h1_empty,
    output logic         h1_ready,

    axi4_if.master       axi,
    output logic [31:0]  h0_written_records,
    output logic [31:0]  h1_written_records,
    output logic         busy,
    output logic         all_writes_done,
    output logic         axi_error,
    output logic         region_overflow
);
    typedef enum logic [2:0] {
      ST_IDLE, ST_PLAN, ST_LIMIT, ST_CHECK, ST_AW, ST_W, ST_B
    } state_t;

    state_t state;
    logic active_hart;
    logic [33:0] h0_address;
    logic [33:0] h1_address;
    logic [33:0] plan_address;
    logic [33:0] plan_limit;
    logic [9:0]  batch_records_remaining;
    logic [6:0]  burst_beats;
    logic [6:0]  beat_index;
    logic [7:0]  burst_record_sent;
    logic [7:0]  burst_record_total;
    logic [6:0]  planned_beats_stage;
    logic [6:0]  boundary_beats_stage;
    logic        select_h0;
    logic        select_h1;
    logic        selected_valid;
    logic [511:0] selected_data;
    logic [1:0]   selected_record_count;
    integer       remaining_beats;
    integer       beats_to_4k;
    integer       planned_beats;

    always_comb begin
      // active_hart is only a priority token while idle.  It changes after a
      // full bank, not after each 64-beat AXI sub-burst.
      select_h0 = (!active_hart && h0_batch_valid) ||
                  (active_hart && !h1_batch_valid && h0_batch_valid);
      select_h1 = (active_hart && h1_batch_valid) ||
                  (!active_hart && !h0_batch_valid && h1_batch_valid);

      remaining_beats = (batch_records_remaining + 1) >> 1;
      beats_to_4k = boundary_beats_stage;
      planned_beats = remaining_beats;
      if (planned_beats > 64)
        planned_beats = 64;
      if (planned_beats > beats_to_4k)
        planned_beats = beats_to_4k;

      selected_valid = active_hart ? h1_valid : h0_valid;
      selected_data = active_hart ? h1_data : h0_data;
      selected_record_count = active_hart ? h1_record_count :
                                            h0_record_count;
      h0_ready = 1'b0;
      h1_ready = 1'b0;
      h0_batch_claim = (state == ST_IDLE) && select_h0;
      h1_batch_claim = (state == ST_IDLE) && select_h1;

      axi.awid = 4'h0;
      axi.awaddr = plan_address[32:0];
      axi.awlen = burst_beats - 1'b1;
      axi.awsize = 3'd6;                 // 64-byte / 512-bit beat
      axi.awburst = 2'b01;
      axi.awlock = 1'b0;
      axi.awcache = 4'b0011;
      axi.awprot = 3'b000;
      axi.awregion = 4'b0000;
      axi.awqos = 4'b0000;
      axi.awvalid = (state == ST_AW);

      // The final odd record must still initialize a full 64-byte ECC line;
      // its high half is padding and is not counted as an instruction record.
      axi.wdata = (selected_record_count == 2'd1) ?
                  {256'b0, selected_data[255:0]} : selected_data;
      axi.wstrb = 64'hFFFF_FFFF_FFFF_FFFF;
      axi.wlast = (beat_index == (burst_beats - 1'b1));
      axi.wvalid = (state == ST_W) && selected_valid;
      axi.bready = (state == ST_B);

      axi.arid = '0;
      axi.araddr = '0;
      axi.arlen = '0;
      axi.arsize = 3'd6;
      axi.arburst = 2'b01;
      axi.arlock = 1'b0;
      axi.arcache = 4'b0011;
      axi.arprot = 3'b000;
      axi.arregion = 4'b0000;
      axi.arqos = 4'b0000;
      axi.arvalid = 1'b0;
      axi.rready = 1'b0;

      if ((state == ST_W) && axi.wready && selected_valid) begin
        if (active_hart)
          h1_ready = 1'b1;
        else
          h0_ready = 1'b1;
      end
    end

    always_ff @(posedge clk or negedge rst_l) begin
      if (!rst_l) begin
        state <= ST_IDLE;
        active_hart <= 1'b0;
        h0_address <= HART0_BASE;
        h1_address <= HART1_BASE;
        plan_address <= '0;
        plan_limit <= '0;
        batch_records_remaining <= '0;
        burst_beats <= '0;
        beat_index <= '0;
        burst_record_sent <= '0;
        burst_record_total <= '0;
        planned_beats_stage <= '0;
        boundary_beats_stage <= '0;
        h0_batch_done <= 1'b0;
        h1_batch_done <= 1'b0;
        h0_written_records <= '0;
        h1_written_records <= '0;
        axi_error <= 1'b0;
        region_overflow <= 1'b0;
      end else begin
        h0_batch_done <= 1'b0;
        h1_batch_done <= 1'b0;
        case (state)
          ST_IDLE: begin
            if (select_h0) begin
              active_hart <= 1'b0;
              batch_records_remaining <= h0_batch_record_count;
              plan_address <= h0_address;
              plan_limit <= HART0_LIMIT;
              state <= ST_PLAN;
            end else if (select_h1) begin
              active_hart <= 1'b1;
              batch_records_remaining <= h1_batch_record_count;
              plan_address <= h1_address;
              plan_limit <= HART1_LIMIT;
              state <= ST_PLAN;
            end
          end

          ST_PLAN: begin
            // This registered planning step keeps conversion/boundary logic
            // out of the 266.5 MHz AXI address-control critical path.
            planned_beats_stage <= (batch_records_remaining + 1'b1) >> 1;
            if (((4096 - plan_address[11:0]) >> 6) == 0)
              boundary_beats_stage <= 7'd64;
            else
              boundary_beats_stage <=
                ((4096 - plan_address[11:0]) >> 6);
            state <= ST_LIMIT;
          end

          ST_LIMIT: begin
            burst_beats <= planned_beats[6:0];
            state <= ST_CHECK;
          end

          ST_CHECK: begin
            if ((burst_beats == 0) ||
                ((plan_address + (burst_beats << 6)) > plan_limit)) begin
              region_overflow <= 1'b1;
              state <= ST_IDLE;
            end else begin
              beat_index <= '0;
              burst_record_sent <= '0;
              state <= ST_AW;
            end
          end

          ST_AW: begin
            if (axi.awvalid && axi.awready)
              state <= ST_W;
          end

          ST_W: begin
            if (axi.wvalid && axi.wready) begin
              burst_record_sent <= burst_record_sent + selected_record_count;
              if (active_hart)
                h1_address <= h1_address + 34'd64;
              else
                h0_address <= h0_address + 34'd64;
              if (beat_index == (burst_beats - 1'b1)) begin
                burst_record_total <= burst_record_sent + selected_record_count;
                state <= ST_B;
              end else begin
                beat_index <= beat_index + 1'b1;
              end
            end
          end

          ST_B: begin
            if (axi.bvalid && axi.bready) begin
              if (axi.bresp != 2'b00) begin
                axi_error <= 1'b1;
                state <= ST_IDLE;
              end else if (burst_record_total >= batch_records_remaining) begin
                if (active_hart) begin
                  h1_written_records <= h1_written_records + burst_record_total;
                  h1_batch_done <= 1'b1;
                end else begin
                  h0_written_records <= h0_written_records + burst_record_total;
                  h0_batch_done <= 1'b1;
                end
                active_hart <= ~active_hart;
                state <= ST_IDLE;
              end else begin
                if (active_hart)
                  h1_written_records <= h1_written_records + burst_record_total;
                else
                  h0_written_records <= h0_written_records + burst_record_total;
                batch_records_remaining <=
                  batch_records_remaining - burst_record_total;
                if (active_hart) begin
                  plan_address <= h1_address;
                  plan_limit <= HART1_LIMIT;
                end else begin
                  plan_address <= h0_address;
                  plan_limit <= HART0_LIMIT;
                end
                state <= ST_PLAN;
              end
            end
          end

          default: state <= ST_IDLE;
        endcase
      end
    end

    assign busy = (state != ST_IDLE) || !h0_empty || !h1_empty;
    assign all_writes_done = capture_done && h0_empty && h1_empty &&
                             (state == ST_IDLE);
endmodule
