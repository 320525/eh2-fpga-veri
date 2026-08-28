// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Two-entry registered elastic queue in the DDR1 UI clock domain.
//
// The upstream asynchronous FIFO is allowed to advance solely from local
// queue space.  AXI WREADY can therefore stop the DDR writer without forming
// a long combinational path back through the DMA arbiter into the XPM FIFO
// read enables.  Each entry is one 512-bit DDR beat and carries whether it
// contains one (final odd record) or two 256-bit records.
module info_fifo_read_elastic (
    input  logic         clk,
    input  logic         rst_l,

    input  logic         in_valid,
    input  logic [511:0] in_data,
    input  logic [1:0]   in_record_count,
    output logic         in_ready,

    output logic         out_valid,
    output logic [511:0] out_data,
    output logic [1:0]   out_record_count,
    input  logic         out_ready,

    output logic         empty,
    output logic [2:0]   buffered_records
);
    logic [1:0][511:0] data_mem;
    logic [1:0][1:0]   count_mem;
    logic               write_pointer;
    logic               read_pointer;
    logic [1:0]         entry_count;
    logic               push;
    logic               pop;

    // Deliberately do not make in_ready depend on out_ready.  A full queue
    // accepts its next upstream beat on the cycle after one entry is popped;
    // the remaining entry keeps AXI WVALID continuous during that refill.
    always_comb begin
      // entry_count is reset asynchronously, so an additional combinational
      // rst_l term is unnecessary and would put reset release directly on
      // the upstream XPM BRAM read-enable path.
      in_ready = (entry_count != 2);
      out_valid = (entry_count != 0);
      out_data = data_mem[read_pointer];
      out_record_count = count_mem[read_pointer];
      empty = (entry_count == 0);
      push = in_valid && in_ready;
      pop = out_valid && out_ready;
    end


    // Payload state is qualified exclusively by entry_count and therefore
    // does not need reset.  Keeping these 1028 payload bits off the reset tree
    // materially reduces 266.5 MHz reset fanout and route delay.
    always_ff @(posedge clk) begin
      if (push) begin
        data_mem[write_pointer] <= in_data;
        count_mem[write_pointer] <= in_record_count;
      end
    end

    always_ff @(posedge clk or negedge rst_l) begin
      if (!rst_l) begin
        write_pointer <= 1'b0;
        read_pointer <= 1'b0;
        entry_count <= 2'd0;
        buffered_records <= 3'd0;
      end else begin
        if (push)
          write_pointer <= ~write_pointer;
        if (pop)
          read_pointer <= ~read_pointer;

        case ({push, pop})
          2'b10: begin
            entry_count <= entry_count + 1'b1;
            buffered_records <= buffered_records + in_record_count;
          end
          2'b01: begin
            entry_count <= entry_count - 1'b1;
            buffered_records <= buffered_records - out_record_count;
          end
          2'b11: begin
            entry_count <= entry_count;
            buffered_records <= buffered_records + in_record_count -
                                out_record_count;
          end
          default: begin
            entry_count <= entry_count;
            buffered_records <= buffered_records;
          end
        endcase
      end
    end
endmodule
