`timescale 1ns/1ps

module sync_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 16,
  localparam int ADDR_W = $clog2(DEPTH)
) (
  input  logic             clk,
  input  logic             resetn,
  input  logic             clear,
  input  logic             wr_en,
  input  logic [WIDTH-1:0] wr_data,
  output logic             full,
  output logic             overflow,
  input  logic             rd_en,
  output logic [WIDTH-1:0] rd_data,
  output logic             empty,
  output logic             underflow,
  output logic [ADDR_W:0]  count
);
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [ADDR_W-1:0] wr_ptr;
  logic [ADDR_W-1:0] rd_ptr;

  assign full    = (count == DEPTH);
  assign empty   = (count == 0);
  assign rd_data = mem[rd_ptr];

  always_ff @(posedge clk) begin
    if (!resetn || clear) begin
      wr_ptr    <= '0;
      rd_ptr    <= '0;
      count     <= '0;
      overflow  <= 1'b0;
      underflow <= 1'b0;
    end else begin
      overflow  <= wr_en && full;
      underflow <= rd_en && empty;

      if (wr_en && !full) begin
        mem[wr_ptr] <= wr_data;
        wr_ptr <= wr_ptr + 1'b1;
      end
      if (rd_en && !empty)
        rd_ptr <= rd_ptr + 1'b1;

      case ({wr_en && !full, rd_en && !empty})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end

  initial begin
    if ((DEPTH < 2) || ((DEPTH & (DEPTH-1)) != 0))
      $error("sync_fifo DEPTH must be a power of two and at least 2");
  end
endmodule
