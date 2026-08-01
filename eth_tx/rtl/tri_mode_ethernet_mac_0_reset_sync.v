`timescale 1ps / 1ps

// Reset synchronizer used by the TEMAC example design before the MAC-side
// active-high reset is converted to the FIFO's AXI-compliant resetn input.
(* dont_touch = "yes" *)
module tri_mode_ethernet_mac_0_reset_sync #(
  parameter INITIALISE = 1'b1,
  parameter DEPTH      = 5
)(
  input  wire reset_in,
  input  wire clk,
  input  wire enable,
  output wire reset_out
);

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  reg [DEPTH-1:0] reset_sync_reg = {DEPTH{INITIALISE}};

  always @(posedge clk or posedge reset_in) begin
    if (reset_in)
      reset_sync_reg <= {DEPTH{1'b1}};
    else if (enable)
      reset_sync_reg <= {reset_sync_reg[DEPTH-2:0], 1'b0};
  end

  assign reset_out = reset_sync_reg[DEPTH-1];

endmodule
