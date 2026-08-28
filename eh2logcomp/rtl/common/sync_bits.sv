`timescale 1ns/1ps

module sync_bits #(
  parameter integer WIDTH = 1,
  parameter integer STAGES = 2
) (
  input  logic             clk,
  input  logic             resetn,
  input  logic [WIDTH-1:0] async_in,
  output logic [WIDTH-1:0] sync_out
);
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [WIDTH-1:0] pipe [0:STAGES-1];

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      for (integer i = 0; i < STAGES; i = i + 1)
        pipe[i] <= '0;
    end else begin
      pipe[0] <= async_in;
      for (integer i = 1; i < STAGES; i = i + 1)
        pipe[i] <= pipe[i-1];
    end
  end
  assign sync_out = pipe[STAGES-1];
endmodule

