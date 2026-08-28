`timescale 1ns/1ps

module tb_rx_fifo_overflow_cdc;
  import eh2_system_pkg::*;

  logic src_clk = 1'b0;
  logic ctrl_clk = 1'b0;
  logic resetn = 1'b0;
  logic src_overflow = 1'b0;
  logic overflow_pulse;
  logic fatal_pending;
  logic [31:0] fatal_code;
  logic led0;
  system_state_t state;
  integer pulse_count = 0;

  always #4 src_clk = ~src_clk;   // 125 MHz MAC RX clock
  always #5 ctrl_clk = ~ctrl_clk; // 100 MHz controller clock

  event_toggle_cdc cdc_i (
    .src_clk, .dst_clk(ctrl_clk), .resetn,
    .src_event(src_overflow), .dst_pulse(overflow_pulse)
  );

  system_error_monitor monitor_i (
    .clk(ctrl_clk), .resetn, .clear(1'b0),
    .err_nb_hart0(1'b0), .err_nb_hart1(1'b0),
    .err_hash_hart0(1'b0), .err_hash_hart1(1'b0),
    .err_txmac_fifo(1'b0), .err_txmac_stream(1'b0),
    .err_waw_hart0(1'b0), .err_waw_hart1(1'b0),
    .err_bank_hart0(1'b0), .err_bank_hart1(1'b0),
    .err_info_rx_fifo(1'b0), .err_info_tx_fifo(1'b0),
    .err_rx_frame_buf(overflow_pulse), .err_rx_frame_len(1'b0),
    .err_mac_rx_fcs(1'b0),
    .err_mac_config(1'b0), .err_phy_init(1'b0), .err_phy_link(1'b0),
    .err_mig0(1'b0), .err_mig1(1'b0),
    .err_ddr_zero(1'b0), .err_ddr_check(1'b0),
    .err_eh2_init(1'b0), .err_eh2_ifu_axi(1'b0),
    .err_eh2_lsu_axi(1'b0), .err_program_write(1'b0),
    .err_program_fifo(1'b0), .err_program_dma(1'b0),
    .err_program_sequence(1'b0),
    .err_info_fifo_h0(1'b0), .err_info_fifo_h1(1'b0),
    .err_info_queue_h0(1'b0), .err_info_queue_h1(1'b0),
    .err_info_capture_h0(1'b0), .err_info_capture_h1(1'b0),
    .err_info_dma(1'b0), .err_info_dump(1'b0),
    .err_info_dump_read_protocol(1'b0),
    .err_info_dump_frame_protocol(1'b0),
    .err_info_dump_release(1'b0),
    .err_waw_cause_h0(1'b0), .err_waw_cause_h1(1'b0),
    .pending(fatal_pending), .code(fatal_code)
  );

  eh2_system_controller #(
    .PROGRAM_TIMEOUT_CYCLES(100),
    .EXECUTE_GUARD_CYCLES(2), .AXI_IDLE_GUARD_CYCLES(2)
  ) controller_i (
    .clk(ctrl_clk), .resetn,
    .mac_config_done(1'b0), .phy_init_done(1'b0), .phy_link_up(1'b0),
    .rgmii_rx_ready(1'b0),
    .mig0_ready(1'b0), .mig1_ready(1'b0),
    .preconfig_program_end_pulse(1'b0),
    .program_first_write_pulse(1'b0), .program_end_pulse(1'b0),
    .program_frame_count(32'b0), .program_dma_done_count(32'b0),
    .program_end_total_count(32'b0),
    .program_dma_busy(1'b0),
    .host_send_stopped_pulse(1'b0), .data_atg_done(1'b0),
    .host_global_reset_pulse(1'b0),
    .data_atg_error(1'b0), .instr_check_done(1'b0),
    .instr_check_pass(1'b0), .instr_check_error(1'b0),
    .data_check_done(1'b0), .data_check_pass(1'b0),
    .data_check_error(1'b0), .zero_done(1'b0), .zero_error(1'b0),
    .eh2_init_done(1'b0), .eh2_init_error(1'b0), .eh2_started(2'b00),
    .eh2_stopped(2'b00), .eh2_axi_idle(1'b1),
    .info_write_done(1'b0), .info_dump_done(1'b0),
    .fatal_error_pending(fatal_pending), .fatal_error_code(fatal_code),
    .info_tx_full(1'b0), .info_frame_done(1'b0),
    .info_sent_code(32'b0), .tx_frame_complete_count(32'b0),
    .tx_submitted_frame_count(32'b0),
    .info_tx_push(), .info_tx_code(),
    .data_atg_start(), .instr_check_start(), .data_check_start(),
    .zero_start(), .program_session_clear(), .global_reset_request(),
    .eh2_execute_enable(), .prefer_log_tx(), .info_dump_start(),
    .led0, .state,
    .ddr0_owner(), .ddr1_owner()
  );

  always @(posedge ctrl_clk)
    if (resetn && overflow_pulse)
      pulse_count <= pulse_count + 1;

  initial begin
    repeat (4) @(posedge ctrl_clk);
    resetn <= 1'b1;
    repeat (8) @(posedge ctrl_clk);
    if (overflow_pulse || fatal_pending || state == ST_ERROR)
      $fatal(1, "false overflow/error without a source event");

    // One 125 MHz clock pulse is shorter than one 100 MHz clock period.
    @(negedge src_clk);
    src_overflow <= 1'b1;
    @(negedge src_clk);
    src_overflow <= 1'b0;

    fork
      begin
        repeat (20) @(posedge ctrl_clk);
        $fatal(1, "short RX overflow event was not captured");
      end
      begin
        wait (state == ST_ERROR);
      end
    join_any
    disable fork;

    if (!fatal_pending || fatal_code != ERR_RX_FRAME_BUF || !led0)
      $fatal(1, "wrong fatal result pending=%b code=%h led0=%b",
             fatal_pending, fatal_code, led0);
    repeat (5) @(posedge ctrl_clk);
    if (pulse_count != 1)
      $fatal(1, "short source event produced %0d destination pulses",
             pulse_count);

    // Reset, then hold overflow high for several RX cycles.  Rising-edge
    // conversion must still emit exactly one control-domain pulse.
    resetn <= 1'b0;
    src_overflow <= 1'b0;
    repeat (4) @(posedge ctrl_clk);
    pulse_count <= 0;
    resetn <= 1'b1;
    repeat (3) @(posedge src_clk);
    src_overflow <= 1'b1;
    repeat (6) @(posedge src_clk);
    src_overflow <= 1'b0;
    repeat (10) @(posedge ctrl_clk);
    if (pulse_count != 1 || !fatal_pending || state != ST_ERROR)
      $fatal(1, "long source level was not reduced to one fatal event");

    $display("RX_FIFO_OVERFLOW_CDC_PASS pulses=%0d code=%h state=%0d led0=%b",
             pulse_count, fatal_code, state, led0);
    $finish;
  end
endmodule
