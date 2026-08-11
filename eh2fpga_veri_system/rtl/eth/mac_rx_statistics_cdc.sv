`timescale 1ns/1ps

// Preserve TEMAC receive errors that are reported only in the recovered RX
// clock domain.  The event path cannot miss an 8 ns pulse, and the Gray-coded
// diagnostic count can be sampled safely by the 100 MHz controller domain.
module mac_rx_statistics_cdc (
  input  logic        rx_clk,
  input  logic        ctrl_clk,
  input  logic        resetn,
  input  logic [27:0] statistics_vector,
  input  logic        statistics_valid,
  output logic        fcs_error_pulse,
  output logic [31:0] fcs_error_count
);
  logic [31:0] count_rx;
  logic [31:0] count_gray_rx;
  logic [31:0] count_gray_ctrl;
  wire fcs_event_rx = statistics_valid && statistics_vector[2];

  always_ff @(posedge rx_clk or negedge resetn) begin
    if (!resetn)
      count_rx <= 32'b0;
    else if (fcs_event_rx)
      count_rx <= count_rx + 32'd1;
  end
  assign count_gray_rx = (count_rx >> 1) ^ count_rx;

  event_toggle_cdc fcs_event_cdc_i (
    .src_clk(rx_clk), .dst_clk(ctrl_clk), .resetn,
    .src_event(fcs_event_rx), .dst_pulse(fcs_error_pulse)
  );
  sync_bits #(.WIDTH(32)) count_sync_i (
    .clk(ctrl_clk), .resetn, .async_in(count_gray_rx),
    .sync_out(count_gray_ctrl)
  );

  always_comb begin
    fcs_error_count[31] = count_gray_ctrl[31];
    for (integer bit_index = 30; bit_index >= 0; bit_index = bit_index - 1)
      fcs_error_count[bit_index] = fcs_error_count[bit_index+1] ^
                                   count_gray_ctrl[bit_index];
  end
endmodule
