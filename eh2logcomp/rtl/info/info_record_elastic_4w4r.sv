// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Core-clock elastic queue between the instruction-info capture logic and
// the four-bank asynchronous FIFO.  The capture block may create as many as
// four compact records in one clock.  Keeping sixteen records in registers
// gives placement a hard timing boundary on both sides of the wide capture
// logic while preserving the original four-record-per-cycle throughput.
//
// Source readiness is deliberately based only on registered occupancy.  It
// never depends combinationally on the downstream XPM FIFO ready signals, so
// a BRAM full/reset path cannot feed back into the capture/WAW logic.  Four
// slots are reserved whenever the source is admitted; therefore a compact
// source bundle is accepted atomically and can never be partially lost.
module info_record_elastic_4w4r #(
    parameter integer DEPTH = 16
) (
    input  logic                         clk,
    input  logic                         rst_l,

    input  logic [3:0]                   in_valid,
    input  logic [3:0][255:0]            in_data,
    output logic [3:0]                   in_ready,

    output logic [3:0]                   out_valid,
    output logic [3:0][255:0]            out_data,
    input  logic [3:0]                   out_ready,

    output logic                         empty,
    output logic                         overflow,
    output logic [$clog2(DEPTH+1)-1:0]   occupancy
);
    localparam integer COUNT_WIDTH = $clog2(DEPTH + 1);

    (* SHREG_EXTRACT = "NO" *) logic [DEPTH-1:0][255:0] data_mem;
    logic [2:0] push_count;
    logic [2:0] pop_count;
    logic [3:0] push_accept;
    integer source_index;

    initial begin
      if (DEPTH < 8)
        $error("info_record_elastic_4w4r DEPTH must be at least eight");
    end

    always_comb begin
      // Reserve a complete four-record source bundle.  Do not use a same-
      // cycle downstream pop to advertise space across this timing boundary.
      in_ready = {4{rst_l && (occupancy <= DEPTH-4)}};
      push_accept = in_valid & in_ready;
      push_count = 3'd0;
      for (integer slot = 0; slot < 4; slot = slot + 1)
        if (push_accept[slot])
          push_count = push_count + 1'b1;

      out_valid = '0;
      out_data = '0;
      for (integer slot = 0; slot < 4; slot = slot + 1) begin
        if (occupancy > slot) begin
          out_valid[slot] = 1'b1;
          out_data[slot] = data_mem[slot];
        end
      end

      // Downstream ready is compact in normal operation.  Count only the
      // accepted prefix so an unexpected ready hole cannot reorder records.
      pop_count = 3'd0;
      for (integer slot = 0; slot < 4; slot = slot + 1)
        if ((pop_count == slot) && out_valid[slot] && out_ready[slot])
          pop_count = pop_count + 1'b1;

      empty = (occupancy == 0);
    end

    always_ff @(posedge clk or negedge rst_l) begin
      if (!rst_l) begin
        data_mem <= '0;
        occupancy <= '0;
        overflow <= 1'b0;
      end else begin
        // Keep the oldest record at element zero.  Variable removal affects
        // only the D input of these queue registers; the timing-critical
        // output toward the XPM BRAM always starts at a register Q pin.
        for (integer index = 0; index < DEPTH; index = index + 1)
          if ((index + pop_count) < occupancy)
            data_mem[index] <= data_mem[index + pop_count];

        source_index = 0;
        for (integer slot = 0; slot < 4; slot = slot + 1)
          if (push_accept[slot]) begin
            data_mem[occupancy - pop_count + source_index] <= in_data[slot];
            source_index = source_index + 1;
          end

        occupancy <= occupancy - pop_count + push_count;
        // valid while not-ready is ordinary backpressure.  The capture block
        // already reports an error if a non-replayable direct record arrives
        // then; this queue reports only an impossible internal over-capacity
        // condition, avoiding a duplicate false overflow indication.
        if ((occupancy - pop_count + push_count) > DEPTH)
          overflow <= 1'b1;
      end
    end
endmodule
