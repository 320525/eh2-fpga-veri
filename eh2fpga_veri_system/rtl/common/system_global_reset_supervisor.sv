`timescale 1ns/1ps

// The supervisor is intentionally outside system_resetn.  A one-cycle request
// therefore cannot be cleared by the reset it creates.  It holds every system
// reset input active for RESET_CYCLES controller-clock periods, then releases
// the complete design into its normal PRECONFIG power-up sequence.
module system_global_reset_supervisor #(
  parameter integer RESET_CYCLES = 64
) (
  input  logic clk,
  input  logic base_resetn,
  input  logic reset_request,
  output logic system_resetn,
  output logic reset_active
);
  localparam integer COUNT_WIDTH =
      (RESET_CYCLES <= 2) ? 1 : $clog2(RESET_CYCLES);
  logic [COUNT_WIDTH-1:0] reset_count;

  initial begin
    if (RESET_CYCLES < 2)
      $error("RESET_CYCLES must hold global reset for at least two cycles");
  end

  always_ff @(posedge clk or negedge base_resetn) begin
    if (!base_resetn) begin
      system_resetn <= 1'b0;
      reset_active  <= 1'b1;
      reset_count   <= '0;
    end else if (reset_request && !reset_active) begin
      system_resetn <= 1'b0;
      reset_active  <= 1'b1;
      reset_count   <= '0;
    end else if (reset_active) begin
      if (reset_count == RESET_CYCLES - 1) begin
        system_resetn <= 1'b1;
        reset_active  <= 1'b0;
        reset_count   <= '0;
      end else begin
        system_resetn <= 1'b0;
        reset_count   <= reset_count + 1'b1;
      end
    end else begin
      system_resetn <= 1'b1;
    end
  end
endmodule
