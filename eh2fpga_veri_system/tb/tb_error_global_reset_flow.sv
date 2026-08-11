`timescale 1ns/1ps

module tb_error_global_reset_flow;
  import eh2_system_pkg::*;

  logic clk = 1'b0;
  logic base_resetn = 1'b0;
  logic hard_resetn;
  logic global_reset_request;
  logic reset_active;
  logic sequence_error = 1'b0;
  logic fcs_error = 1'b0;
  logic fatal_pending;
  logic [31:0] fatal_code;
  logic info_tx_push;
  logic [31:0] info_tx_code;
  logic info_frame_done = 1'b0;
  logic [31:0] info_sent_code = 32'b0;
  logic host_send_stopped_pulse = 1'b0;
  system_state_t state;
  logic led0;

  always #5 clk = ~clk;

  system_global_reset_supervisor #(.RESET_CYCLES(8)) reset_i (
    .clk, .base_resetn, .reset_request(global_reset_request),
    .system_resetn(hard_resetn), .reset_active
  );

  system_error_monitor monitor_i (
    .clk, .resetn(hard_resetn), .clear(1'b0),
    .err_nb_hart0(1'b0), .err_nb_hart1(1'b0),
    .err_hash_hart0(1'b0), .err_hash_hart1(1'b0),
    .err_txmac_fifo(1'b0), .err_txmac_stream(1'b0),
    .err_waw_hart0(1'b0), .err_waw_hart1(1'b0),
    .err_bank_hart0(1'b0), .err_bank_hart1(1'b0),
    .err_info_rx_fifo(1'b0), .err_info_tx_fifo(1'b0),
    .err_rx_frame_buf(1'b0), .err_rx_frame_len(1'b0),
    .err_mac_rx_fcs(fcs_error),
    .err_mac_config(1'b0), .err_phy_init(1'b0), .err_phy_link(1'b0),
    .err_mig0(1'b0), .err_mig1(1'b0),
    .err_ddr_zero(1'b0), .err_ddr_check(1'b0),
    .err_eh2_init(1'b0), .err_eh2_ifu_axi(1'b0),
    .err_eh2_lsu_axi(1'b0), .err_program_write(1'b0),
    .err_program_fifo(1'b0), .err_program_dma(1'b0),
    .err_program_sequence(sequence_error),
    .pending(fatal_pending), .code(fatal_code)
  );

  eh2_system_controller #(
    .PROGRAM_TIMEOUT_CYCLES(100), .EXECUTE_GUARD_CYCLES(2),
    .AXI_IDLE_GUARD_CYCLES(2)
  ) controller_i (
    .clk, .resetn(hard_resetn),
    .mac_config_done(1'b0), .phy_init_done(1'b0), .phy_link_up(1'b0),
    .rgmii_rx_ready(1'b0), .mig0_ready(1'b0), .mig1_ready(1'b0),
    .preconfig_program_end_pulse(1'b0),
    .program_first_write_pulse(1'b0), .program_end_pulse(1'b0),
    .program_end_total_count(32'b0), .program_frame_count(32'b0),
    .program_dma_done_count(32'b0), .program_dma_busy(1'b0),
    .host_send_stopped_pulse,
    .data_atg_done(1'b0), .data_atg_error(1'b0),
    .instr_check_done(1'b0), .instr_check_pass(1'b0),
    .instr_check_error(1'b0), .data_check_done(1'b0),
    .data_check_pass(1'b0), .data_check_error(1'b0),
    .zero_done(1'b0), .zero_error(1'b0),
    .eh2_init_done(1'b0), .eh2_init_error(1'b0),
    .eh2_started(2'b0), .eh2_stopped(2'b0), .eh2_axi_idle(1'b1),
    .log_tx_all_done(1'b0), .fatal_error_pending(fatal_pending),
    .fatal_error_code(fatal_code), .info_tx_full(1'b0),
    .info_frame_done, .info_sent_code, .tx_frame_complete_count(32'b0),
    .tx_submitted_frame_count(32'b0),
    .info_tx_push, .info_tx_code, .data_atg_start(),
    .instr_check_start(), .data_check_start(), .zero_start(),
    .program_session_clear(), .global_reset_request,
    .eh2_execute_enable(), .prefer_log_tx(), .led0, .state,
    .ddr0_owner(), .ddr1_owner()
  );

  task automatic complete_error_frame(input logic [31:0] expected_code);
    begin
      wait (info_tx_push);
      if (info_tx_code != expected_code)
        $fatal(1, "wrong immediate error code %08h expected %08h",
               info_tx_code, expected_code);
      @(posedge clk);
      info_sent_code <= expected_code;
      info_frame_done <= 1'b1;
      @(posedge clk);
      info_frame_done <= 1'b0;
      repeat (3) @(posedge clk);
      if (global_reset_request || !hard_resetn)
        $fatal(1, "reset started before HOST_SEND_STOPPED");
    end
  endtask

  task automatic acknowledge_and_check_reset;
    integer low_cycles;
    begin
      host_send_stopped_pulse <= 1'b1;
      @(posedge clk);
      host_send_stopped_pulse <= 1'b0;
      wait (!hard_resetn);
      low_cycles = 0;
      while (!hard_resetn) begin
        @(posedge clk);
        low_cycles = low_cycles + 1;
      end
      if (low_cycles < 8)
        $fatal(1, "global reset held only %0d cycles", low_cycles);
      if (state != ST_PRECONFIG)
        $fatal(1, "reset release state %0d is not PRECONFIG", state);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    base_resetn <= 1'b1;
    wait (hard_resetn);

    // A discontinuous program sequence is an immediate transfer error.
    sequence_error <= 1'b1;
    @(posedge clk);
    sequence_error <= 1'b0;
    complete_error_frame(ERR_PROGRAM_SEQUENCE);
    acknowledge_and_check_reset();

    // A MAC FCS error uses the same stop/ack/hard-reset handshake.
    fcs_error <= 1'b1;
    @(posedge clk);
    fcs_error <= 1'b0;
    complete_error_frame(ERR_MAC_RX_FCS);
    acknowledge_and_check_reset();

    $display("TB_PASS immediate sequence/FCS error and global reset handshake");
    $finish;
  end

  initial begin
    #100us;
    $fatal(1, "global simulation timeout");
  end
endmodule
