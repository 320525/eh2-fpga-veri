`timescale 1ns/1ps

module tb_mac_rx_statistics_cdc;
  logic rx_clk = 1'b0;
  logic ctrl_clk = 1'b0;
  logic resetn = 1'b0;
  logic [27:0] statistics_vector = 28'b0;
  logic statistics_valid = 1'b0;
  logic fcs_error_pulse;
  logic [31:0] fcs_error_count;
  integer pulse_count = 0;

  always #4 rx_clk = ~rx_clk;
  always #5 ctrl_clk = ~ctrl_clk;

  mac_rx_statistics_cdc dut (.*);

  always @(posedge ctrl_clk)
    if (resetn && fcs_error_pulse)
      pulse_count <= pulse_count + 1;

  task automatic send_statistics(input logic [27:0] value);
    begin
      @(negedge rx_clk);
      statistics_vector <= value;
      statistics_valid <= 1'b1;
      @(negedge rx_clk);
      statistics_valid <= 1'b0;
      statistics_vector <= 28'b0;
    end
  endtask

  initial begin
    repeat (4) @(posedge ctrl_clk);
    resetn <= 1'b1;
    repeat (4) @(posedge rx_clk);

    // GOOD_FRAME without FCS_ERROR must not alter either output.
    send_statistics(28'h000_0001);
    repeat (8) @(posedge ctrl_clk);
    if (pulse_count != 0 || fcs_error_count != 0)
      $fatal(1, "good frame changed FCS diagnostics");

    send_statistics(28'h000_0004);
    repeat (8) @(posedge ctrl_clk);
    if (pulse_count != 1 || fcs_error_count != 1)
      $fatal(1, "first FCS event pulse/count %0d/%0d",
             pulse_count, fcs_error_count);

    send_statistics(28'h000_0004);
    repeat (8) @(posedge ctrl_clk);
    if (pulse_count != 2 || fcs_error_count != 2)
      $fatal(1, "second FCS event pulse/count %0d/%0d",
             pulse_count, fcs_error_count);

    $display("TB_PASS MAC RX FCS event/count CDC pulses=%0d count=%0d",
             pulse_count, fcs_error_count);
    $finish;
  end
endmodule
