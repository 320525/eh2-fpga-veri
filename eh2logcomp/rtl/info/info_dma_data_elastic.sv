// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Two-entry registered stream boundary between the DDR1 AXI read DMA and the
// complete-frame builder.  AXI RVALID/RDATA and the phase-owner mux therefore
// terminate at these registers instead of driving the 30 x 384-bit frame
// storage control network in the same 266.5 MHz clock cycle.
module info_dma_data_elastic (
    input  logic         clk,
    input  logic         resetn,

    input  logic         in_valid,
    input  logic [511:0] in_data,
    input  logic [4:0]   in_index,
    input  logic         in_last,
    output logic         in_ready,

    output logic         out_valid,
    output logic [511:0] out_data,
    output logic [4:0]   out_index,
    output logic         out_last,
    input  logic         out_ready
);
    logic [1:0][511:0] data_mem;
    logic [1:0][4:0] index_mem;
    logic [1:0] last_mem;
    logic write_pointer;
    logic read_pointer;
    logic [1:0] entry_count;
    logic push;
    logic pop;

    // Deliberately keep input readiness independent of out_ready; this is a
    // true registered timing boundary rather than a combinational bypass.
    always_comb begin
      in_ready = resetn && (entry_count != 2);
      out_valid = resetn && (entry_count != 0);
      out_data = data_mem[read_pointer];
      out_index = index_mem[read_pointer];
      out_last = last_mem[read_pointer];
      push = in_valid && in_ready;
      pop = out_valid && out_ready;
    end

    always_ff @(posedge clk or negedge resetn) begin
      if (!resetn) begin
        data_mem <= '0;
        index_mem <= '0;
        last_mem <= '0;
        write_pointer <= 1'b0;
        read_pointer <= 1'b0;
        entry_count <= 2'd0;
      end else begin
        if (push) begin
          data_mem[write_pointer] <= in_data;
          index_mem[write_pointer] <= in_index;
          last_mem[write_pointer] <= in_last;
          write_pointer <= ~write_pointer;
        end
        if (pop)
          read_pointer <= ~read_pointer;
        case ({push,pop})
          2'b10: entry_count <= entry_count + 1'b1;
          2'b01: entry_count <= entry_count - 1'b1;
          default: entry_count <= entry_count;
        endcase
      end
    end
endmodule
