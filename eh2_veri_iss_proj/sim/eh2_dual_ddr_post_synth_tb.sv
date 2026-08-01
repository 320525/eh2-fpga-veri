`timescale 1ns/1ps

// Post-synthesis functional testbench. It intentionally drives only the
// board clocks and reset pins and observes only the four top-level LEDs.
module eh2_dual_ddr_post_synth_tb;
  logic sw3_1 = 1'b0;
  logic sw4_1 = 1'b0;
  logic core_clk_p = 1'b0;
  logic atg_clk_p = 1'b0;
  logic c0_sys_clk_p = 1'b0;
  logic c1_sys_clk_p = 1'b0;
  wire core_clk_n = ~core_clk_p;
  wire atg_clk_n = ~atg_clk_p;
  wire c0_sys_clk_n = ~c0_sys_clk_p;
  wire c1_sys_clk_n = ~c1_sys_clk_p;
  wire [7:0] led;

  wire c0_ddr4_act_n;
  wire [16:0] c0_ddr4_adr;
  wire [1:0] c0_ddr4_ba;
  wire [1:0] c0_ddr4_bg;
  wire [0:0] c0_ddr4_cke;
  wire [0:0] c0_ddr4_odt;
  wire [0:0] c0_ddr4_cs_n;
  wire [0:0] c0_ddr4_ck_t;
  wire [0:0] c0_ddr4_ck_c;
  wire c0_ddr4_reset_n;
  wire [8:0] c0_ddr4_dm_dbi_n;
  wire [71:0] c0_ddr4_dq;
  wire [8:0] c0_ddr4_dqs_c;
  wire [8:0] c0_ddr4_dqs_t;

  wire c1_ddr4_act_n;
  wire [16:0] c1_ddr4_adr;
  wire [1:0] c1_ddr4_ba;
  wire [1:0] c1_ddr4_bg;
  wire [0:0] c1_ddr4_cke;
  wire [0:0] c1_ddr4_odt;
  wire [0:0] c1_ddr4_cs_n;
  wire [0:0] c1_ddr4_ck_t;
  wire [0:0] c1_ddr4_ck_c;
  wire c1_ddr4_reset_n;
  wire [8:0] c1_ddr4_dm_dbi_n;
  wire [71:0] c1_ddr4_dq;
  wire [8:0] c1_ddr4_dqs_c;
  wire [8:0] c1_ddr4_dqs_t;

  always #10.000 core_clk_p = ~core_clk_p;
  always #5.000 atg_clk_p = ~atg_clk_p;
  always #6.566 c0_sys_clk_p = ~c0_sys_clk_p;
  always #6.566 c1_sys_clk_p = ~c1_sys_clk_p;

  eh2_dual_ddr_top dut (.*);

  initial begin
    #1;
    if (led !== 8'b0000_0000)
      $fatal(1, "POST_SYNTH LEDs must all be off during board reset: %b", led);
    repeat (20) @(posedge atg_clk_p);
    sw3_1 <= 1'b1;
    sw4_1 <= 1'b1;
    #1;
    if (led !== 8'b0000_0000)
      $fatal(1, "POST_SYNTH LEDs must remain off immediately after reset release: %b", led);

    wait (led[0] === 1'b1);
    $display("POST_SYNTH_STAGE %0t: DDR0 ATG write and readback passed", $time);
    wait (led[1] === 1'b1);
    $display("POST_SYNTH_STAGE %0t: DDR1 ATG write and readback passed", $time);
    wait (led[2] === 1'b1);
    $display("POST_SYNTH_STAGE %0t: EH2 issued IFU request", $time);
    wait (led[3] === 1'b1);
    $display("POST_SYNTH_STAGE %0t: EH2 accepted IFU read response", $time);
    wait (led[4] === 1'b1);
    $display("POST_SYNTH_STAGE %0t: EH2 issued LSU read request", $time);
    wait (led[5] === 1'b1);
    $display("POST_SYNTH_STAGE %0t: EH2 accepted LSU read response", $time);
    wait (led[6] === 1'b1);
    $display("POST_SYNTH_STAGE %0t: EH2 issued LSU write", $time);
    wait (led[7] === 1'b1);
    $display("POST_SYNTH_STAGE %0t: DDR terminal readback passed", $time);
    repeat (20) @(posedge core_clk_p);
    if (led !== 8'b1111_1111)
      $fatal(1, "POST_SYNTH unexpected LED value: %b", led);
    $display("POST_SYNTH_PASS: synthesized TCM scrub path, debug resume, IFU/LSU reads and DDR result; LED=11111111");
    $finish;
  end

  initial begin
    #10_000_000;
    $fatal(1, "POST_SYNTH_TIMEOUT at 10 ms: LED=%b", led);
  end
endmodule
