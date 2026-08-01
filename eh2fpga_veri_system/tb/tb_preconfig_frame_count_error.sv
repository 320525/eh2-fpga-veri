`timescale 1ns/1ps

module preconfig_frame_count_error_case #(
  parameter integer ILLEGAL_FRAME_COUNT = 2
);
  import eh2_system_pkg::*;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5 clk = ~clk;

  logic info_tx_push;
  logic [31:0] info_tx_code;
  logic data_atg_start, instr_check_start, data_check_start, zero_start;
  logic ready_soft_reset, error_monitor_clear, eh2_execute_enable;
  logic prefer_log_tx, led0;
  system_state_t state;
  ddr0_owner_t ddr0_owner;
  ddr1_owner_t ddr1_owner;

  logic preconfig_program_end_pulse = 1'b0;
  logic program_end_pulse = 1'b0;
  logic info_frame_done = 1'b0;
  logic [31:0] info_sent_code = 32'b0;
  logic [31:0] program_frame_count = 32'b0;
  logic [31:0] program_dma_done_count = 32'b0;

  eh2_system_controller #(
    .PROGRAM_TIMEOUT_CYCLES(80),
    .SOFT_RESET_CYCLES(4),
    .EXECUTE_GUARD_CYCLES(4)
  ) dut (
    .clk, .resetn,
    .mac_config_done(1'b1), .phy_init_done(1'b1),
    .phy_link_up(1'b1), .mig0_ready(1'b1), .mig1_ready(1'b1),
    .preconfig_program_end_pulse,
    .program_first_write_pulse(1'b0), .program_end_pulse,
    .program_frame_count, .program_dma_done_count,
    .program_dma_busy(1'b0),
    .data_atg_done(1'b1), .data_atg_error(1'b0),
    .instr_check_done(1'b0), .instr_check_pass(1'b0),
    .instr_check_error(1'b0),
    .data_check_done(1'b0), .data_check_pass(1'b0),
    .data_check_error(1'b0),
    .zero_done(1'b0), .zero_error(1'b0),
    .eh2_init_done(1'b0), .eh2_init_error(1'b0),
    .eh2_stopped(2'b0), .eh2_axi_idle(1'b1),
    .log_tx_all_done(1'b0),
    .fatal_error_pending(1'b0), .fatal_error_code(32'b0),
    .info_tx_full(1'b0), .info_frame_done, .info_sent_code,
    .info_tx_push, .info_tx_code,
    .data_atg_start, .instr_check_start, .data_check_start,
    .zero_start, .ready_soft_reset, .error_monitor_clear,
    .eh2_execute_enable, .prefer_log_tx, .led0,
    .state, .ddr0_owner, .ddr1_owner
  );

  initial begin
    repeat (5) @(posedge clk);
    resetn <= 1'b1;

    wait (info_tx_push && (info_tx_code == MSG_PREINIT_DONE));
    @(posedge clk);
    info_sent_code <= MSG_PREINIT_DONE;
    info_frame_done <= 1'b1;
    @(posedge clk);
    info_frame_done <= 1'b0;

    wait (data_atg_start);
    // PRECONFIG is defined to accept exactly one test frame. Presenting an
    // end marker after two completed frames must enter the locked ERROR
    // state and must never start either DDR checker.
    program_frame_count <= ILLEGAL_FRAME_COUNT;
    program_dma_done_count <= ILLEGAL_FRAME_COUNT;
    @(posedge clk);
    preconfig_program_end_pulse <= 1'b1;
    program_end_pulse <= 1'b1;
    @(posedge clk);
    preconfig_program_end_pulse <= 1'b0;
    program_end_pulse <= 1'b0;

    wait (state == ST_ERROR);
    @(posedge clk);
    #1;
    if (!led0)
      $fatal(1, "PRECONFIG illegal frame count did not assert LED0");
    if (instr_check_start || data_check_start)
      $fatal(1, "PRECONFIG checker started for illegal program-frame count");
    if (dut.captured_error_code != ERR_PROGRAM_WRITE)
      $fatal(1, "PRECONFIG frame-count error code %08h",
             dut.captured_error_code);
    $display("TB_PASS preconfig exact-one-frame rejection count=%0d",
             ILLEGAL_FRAME_COUNT);
    $finish;
  end

  initial begin
    #200us;
    $fatal(1, "global simulation timeout");
  end
endmodule

module tb_preconfig_frame_count_error;
  preconfig_frame_count_error_case #(
    .ILLEGAL_FRAME_COUNT(2)
  ) case_i ();
endmodule

module tb_preconfig_zero_frame_error;
  preconfig_frame_count_error_case #(
    .ILLEGAL_FRAME_COUNT(0)
  ) case_i ();
endmodule
