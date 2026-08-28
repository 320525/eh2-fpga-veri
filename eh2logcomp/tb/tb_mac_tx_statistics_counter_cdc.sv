`timescale 1ns/1ps

module tb_mac_tx_statistics_counter_cdc;
  logic tx_clk = 1'b0;
  logic ctrl_clk = 1'b0;
  logic resetn = 1'b0;
  logic statistics_valid = 1'b0;
  logic [31:0] frame_complete_count;

  always #4 tx_clk = ~tx_clk;
  always #5 ctrl_clk = ~ctrl_clk;

  mac_tx_statistics_counter_cdc dut (
    .tx_clk, .ctrl_clk, .resetn, .statistics_valid,
    .frame_complete_count
  );

  task automatic drive_valid(input integer high_cycles);
    @(negedge tx_clk);
    statistics_valid = 1'b1;
    repeat (high_cycles) @(negedge tx_clk);
    statistics_valid = 1'b0;
    @(negedge tx_clk);
  endtask

  task automatic wait_for_count(input logic [31:0] expected);
    integer timeout;
    begin
      timeout = 0;
      while ((frame_complete_count != expected) && (timeout < 30)) begin
        @(posedge ctrl_clk);
        timeout = timeout + 1;
      end
      if (frame_complete_count != expected)
        $fatal(1, "expected count %0d, observed %0d", expected,
               frame_complete_count);
    end
  endtask

  initial begin
    repeat (4) @(posedge ctrl_clk);
    resetn = 1'b1;

    drive_valid(1);
    wait_for_count(32'd1);

    // A stretched statistics-valid level still represents exactly one frame.
    drive_valid(4);
    wait_for_count(32'd2);
    repeat (8) @(posedge ctrl_clk);
    if (frame_complete_count != 32'd2)
      $fatal(1, "stretched valid was counted more than once: %0d",
             frame_complete_count);

    drive_valid(2);
    wait_for_count(32'd3);
    $display("TB_PASS tx statistics rising-edge count=%0d",
             frame_complete_count);
    $finish;
  end
endmodule
