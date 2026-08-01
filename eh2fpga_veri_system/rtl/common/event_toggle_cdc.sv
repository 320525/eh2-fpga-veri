`timescale 1ns/1ps

// Transfer an event that may be shorter than one destination clock period.
// Each source-domain rising edge toggles a bit; a three-stage ASYNC_REG chain
// carries that state into the destination domain and recreates one pulse.
// Events must be separated by at least three destination clock periods.
module event_toggle_cdc (
  input  logic src_clk,
  input  logic dst_clk,
  input  logic resetn,
  input  logic src_event,
  output logic dst_pulse
);
  logic src_event_d;
  logic src_toggle;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [2:0] toggle_sync;

  always_ff @(posedge src_clk or negedge resetn) begin
    if (!resetn) begin
      src_event_d <= 1'b0;
      src_toggle  <= 1'b0;
    end else begin
      src_event_d <= src_event;
      if (src_event && !src_event_d)
        src_toggle <= ~src_toggle;
    end
  end

  always_ff @(posedge dst_clk or negedge resetn) begin
    if (!resetn)
      toggle_sync <= 3'b000;
    else
      toggle_sync <= {toggle_sync[1:0], src_toggle};
  end

  assign dst_pulse = toggle_sync[2] ^ toggle_sync[1];
endmodule
