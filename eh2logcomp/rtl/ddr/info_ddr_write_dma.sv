// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Drains the two per-hart record FIFOs into disjoint DDR1 regions.  Hart1 uses
// [0, 4 GiB), hart0 uses [4 GiB, 8 GiB).  Bursts are capped at 64 512-bit beats
// and are shortened at every 4 KiB boundary as required by AXI4.
module info_ddr_write_dma #(
    parameter integer FIFO_COUNT_WIDTH = 11,
    parameter logic [33:0] HART1_BASE = 34'h0_0000_0000,
    parameter logic [33:0] HART0_BASE = 34'h1_0000_0000,
    parameter logic [33:0] HART1_LIMIT = 34'h1_0000_0000,
    parameter logic [33:0] HART0_LIMIT = 34'h2_0000_0000
) (
    input  logic                         clk,
    input  logic                         rst_l,
    input  logic                         capture_done,

    input  logic                         h0_valid,
    input  logic [511:0]                 h0_data,
    input  logic [1:0]                   h0_record_count,
    input  logic [FIFO_COUNT_WIDTH-1:0]  h0_occupancy,
    input  logic                         h0_empty,
    output logic                         h0_ready,

    input  logic                         h1_valid,
    input  logic [511:0]                 h1_data,
    input  logic [1:0]                   h1_record_count,
    input  logic [FIFO_COUNT_WIDTH-1:0]  h1_occupancy,
    input  logic                         h1_empty,
    output logic                         h1_ready,

    axi4_if.master                       axi,
    output logic [31:0]                  h0_written_records,
    output logic [31:0]                  h1_written_records,
    output logic                         busy,
    output logic                         all_writes_done,
    output logic                         axi_error,
    output logic                         region_overflow
);
    typedef enum logic [2:0] {
      ST_IDLE, ST_PLAN, ST_LIMIT, ST_CHECK, ST_AW, ST_W, ST_B
    } state_t;

    state_t state;
    logic active_hart;
    logic [1:0] drain_enabled;
    logic [33:0] h0_address;
    logic [33:0] h1_address;
    logic [6:0] burst_beats;
    logic [6:0] beat_index;
    logic [7:0] burst_record_total;
    logic [7:0] burst_record_sent;
    logic [FIFO_COUNT_WIDTH-1:0] plan_occupancy;
    logic [33:0] plan_address;
    logic [33:0] plan_limit;
    logic plan_capture_done;
    logic plan_valid;
    logic [FIFO_COUNT_WIDTH-1:0] available_beats_stage;
    logic [6:0] boundary_beats_stage;
    logic selected_valid;
    logic [511:0] selected_data;
    logic [1:0] selected_record_count;

    integer h0_beats_available;
    integer h1_beats_available;
    integer selected_beats_available;
    integer beats_to_4k;
    integer planned_beats;
    logic [33:0] selected_address;
    logic [33:0] selected_limit;

    always_comb begin
      h0_beats_available = capture_done ? ((h0_occupancy + 1) >> 1) :
                                          (h0_occupancy >> 1);
      h1_beats_available = capture_done ? ((h1_occupancy + 1) >> 1) :
                                          (h1_occupancy >> 1);
      selected_beats_available = available_beats_stage;
      selected_address = plan_address;
      selected_limit = plan_limit;
      beats_to_4k = boundary_beats_stage;
      planned_beats = selected_beats_available;
      if (planned_beats > 64)
        planned_beats = 64;
      if (planned_beats > beats_to_4k)
        planned_beats = beats_to_4k;
      if (planned_beats == 0 && plan_valid)
        planned_beats = 1;

    end

    always_comb begin
      selected_valid = active_hart ? h1_valid : h0_valid;
      selected_data = active_hart ? h1_data : h0_data;
      selected_record_count = active_hart ? h1_record_count :
                                            h0_record_count;
      h0_ready = 1'b0;
      h1_ready = 1'b0;

      axi.awid = 4'h0;
      axi.awaddr = selected_address[32:0];
      axi.awlen = burst_beats - 1'b1;
      axi.awsize = 3'd6;
      axi.awburst = 2'b01;
      axi.awlock = 1'b0;
      axi.awcache = 4'b0011;
      axi.awprot = 3'b000;
      axi.awregion = 4'b0000;
      axi.awqos = 4'b0000;
      axi.awvalid = (state == ST_AW);

      // A one-record tail still initializes the complete 512-bit ECC line.
      // The upper record is protocol padding and is never included in the
      // architectural record counters or emitted as a valid Info Struct.
      axi.wdata = (selected_record_count == 1) ?
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
        drain_enabled <= 2'b00;
        h0_address <= HART0_BASE;
        h1_address <= HART1_BASE;
        burst_beats <= 7'd0;
        beat_index <= 7'd0;
        burst_record_total <= 8'd0;
        burst_record_sent <= 8'd0;
        plan_occupancy <= '0;
        plan_address <= '0;
        plan_limit <= '0;
        plan_capture_done <= 1'b0;
        plan_valid <= 1'b0;
        available_beats_stage <= '0;
        boundary_beats_stage <= 7'd0;
        h0_written_records <= 32'd0;
        h1_written_records <= 32'd0;
        axi_error <= 1'b0;
        region_overflow <= 1'b0;
      end else begin
        if (h0_occupancy >= 2 || (capture_done && !h0_empty))
          drain_enabled[0] <= 1'b1;
        if (h1_occupancy >= 2 || (capture_done && !h1_empty))
          drain_enabled[1] <= 1'b1;
        if ((state == ST_IDLE) && h0_empty)
          drain_enabled[0] <= 1'b0;
        if ((state == ST_IDLE) && h1_empty)
          drain_enabled[1] <= 1'b0;

        case (state)
          ST_IDLE: begin
            // Keep draining the chosen hart until it is empty.  When both are
            // ready after an idle gap, alternate priority to bound latency.
            if ((!active_hart && drain_enabled[0] && !h0_empty && h0_valid) ||
                (active_hart &&
                 !(drain_enabled[1] && !h1_empty) &&
                 drain_enabled[0] && !h0_empty && h0_valid)) begin
              active_hart <= 1'b0;
              if (h0_valid) begin
                if ((h0_address + 64) > HART0_LIMIT)
                  region_overflow <= 1'b1;
                else begin
                  // Sample the FIFO count and address first.  Burst length
                  // arithmetic is performed from these registers in ST_PLAN,
                  // removing the XPM count-to-AW control critical path.
                  plan_occupancy <= h0_occupancy;
                  plan_address <= h0_address;
                  plan_limit <= HART0_LIMIT;
                  plan_capture_done <= capture_done;
                  plan_valid <= h0_valid;
                  state <= ST_PLAN;
                end
              end
            end else if ((active_hart && drain_enabled[1] && !h1_empty &&
                          h1_valid) ||
                         (!active_hart &&
                          !(drain_enabled[0] && !h0_empty) &&
                          drain_enabled[1] && !h1_empty && h1_valid)) begin
              active_hart <= 1'b1;
              if ((h1_address + 64) > HART1_LIMIT)
                region_overflow <= 1'b1;
              else begin
                plan_occupancy <= h1_occupancy;
                plan_address <= h1_address;
                plan_limit <= HART1_LIMIT;
                plan_capture_done <= capture_done;
                plan_valid <= h1_valid;
                state <= ST_PLAN;
              end
            end
          end

          ST_PLAN: begin
            // Pipeline the record-to-beat conversion and 4 KiB boundary
            // distance.  In particular, capture_done no longer feeds the
            // burst-limit/region-check/state-enable chain in one 266 MHz
            // cycle.  No FIFO read occurs before ST_W, so these sampled
            // values cannot overestimate the records available to the burst.
            available_beats_stage <= plan_capture_done ?
                                     ((plan_occupancy + 1'b1) >> 1) :
                                     (plan_occupancy >> 1);
            if (((4096 - plan_address[11:0]) >> 6) == 0)
              boundary_beats_stage <= 7'd64;
            else
              boundary_beats_stage <=
                ((4096 - plan_address[11:0]) >> 6);
            state <= ST_LIMIT;
          end

          ST_LIMIT: begin
            // Cap the already registered candidates independently of the
            // region-limit check.  This adds two UI-clock cycles per burst
            // without changing address, data, ordering, or AXI burst rules.
            burst_beats <= planned_beats[6:0];
            state <= ST_CHECK;
          end

          ST_CHECK: begin
            if ((burst_beats == 0) ||
                ((plan_address + (burst_beats << 6)) > plan_limit)) begin
              region_overflow <= 1'b1;
              state <= ST_IDLE;
            end else begin
              beat_index <= 7'd0;
              burst_record_sent <= 8'd0;
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
                h1_address <= h1_address + 64;
              else
                h0_address <= h0_address + 64;

              if (beat_index == (burst_beats - 1'b1)) begin
                burst_record_total <= burst_record_sent +
                                      selected_record_count;
                state <= ST_B;
              end else begin
                beat_index <= beat_index + 1'b1;
              end
            end
          end

          ST_B: begin
            if (axi.bvalid && axi.bready) begin
              if (axi.bresp != 2'b00)
                axi_error <= 1'b1;
              else if (active_hart)
                h1_written_records <= h1_written_records +
                                      burst_record_total;
              else
                h0_written_records <= h0_written_records +
                                      burst_record_total;
              // active_hart is the priority token, not a permanent owner.
              // Rotate it after every completed burst.  If the preferred
              // hart has no data, ST_IDLE immediately falls back to the
              // other hart; if both are non-empty, neither can be starved
              // for more than one (at most 64-beat) burst.
              active_hart <= ~active_hart;
              state <= ST_IDLE;
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
