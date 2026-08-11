`timescale 1ns/1ps

module tb_system_controller;
  import eh2_system_pkg::*;

  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #5 clk = ~clk;

  logic mac_config_done, phy_init_done, phy_link_up, rgmii_rx_ready;
  logic mig0_ready, mig1_ready;
  logic preconfig_program_end_pulse, program_first_write_pulse;
  logic program_end_pulse, program_dma_busy;
  logic [31:0] program_frame_count, program_dma_done_count;
  logic [31:0] program_end_total_count;
  logic host_send_stopped_pulse;
  logic data_atg_done, data_atg_error;
  logic instr_check_done, instr_check_pass, instr_check_error;
  logic data_check_done, data_check_pass, data_check_error;
  logic zero_done, zero_error;
  logic eh2_init_done, eh2_init_error;
  logic [1:0] eh2_started, eh2_stopped;
  logic eh2_axi_idle;
  logic log_tx_all_done;
  logic fatal_error_pending;
  logic [31:0] fatal_error_code;

  logic info_push, info_full, info_overflow;
  logic [31:0] info_code;
  logic info_rd_en, info_empty;
  logic [31:0] info_rd_code;
  logic [7:0] tx_data;
  logic tx_valid, tx_last, tx_ready;
  logic info_frame_done;
  logic [31:0] info_sent_code;
  logic [31:0] tx_frame_complete_count;
  logic [31:0] tx_submitted_frame_count;

  logic data_atg_start, instr_check_start, data_check_start, zero_start;
  logic program_session_clear, global_reset_request, eh2_execute_enable;
  logic prefer_log_tx, led0;
  system_state_t state;
  ddr0_owner_t ddr0_owner;
  ddr1_owner_t ddr1_owner;

  system_info_tx_fifo #(.DEPTH(8)) tx_fifo_i (
    .clk, .resetn, .wr_en(info_push), .wr_code(info_code),
    .full(info_full), .overflow(info_overflow),
    .rd_en(info_rd_en), .rd_code(info_rd_code), .empty(info_empty)
  );

  system_info_tx_formatter formatter_i (
    .clk, .resetn, .fifo_code(info_rd_code), .fifo_empty(info_empty),
    .fifo_rd_en(info_rd_en), .m_axis_tdata(tx_data),
    .m_axis_tvalid(tx_valid), .m_axis_tlast(tx_last),
    .m_axis_tready(tx_ready), .frame_done(info_frame_done),
    .sent_code(info_sent_code)
  );

  eh2_system_controller #(
    .PROGRAM_TIMEOUT_CYCLES(80),
    .EXECUTE_GUARD_CYCLES(4)
  ) dut (
    .clk, .resetn,
    .mac_config_done, .phy_init_done, .phy_link_up, .rgmii_rx_ready,
    .mig0_ready, .mig1_ready,
    .preconfig_program_end_pulse, .program_first_write_pulse,
    .program_end_pulse, .program_frame_count, .program_dma_done_count,
    .program_end_total_count,
    .program_dma_busy, .host_send_stopped_pulse,
    .data_atg_done, .data_atg_error,
    .instr_check_done, .instr_check_pass, .instr_check_error,
    .data_check_done, .data_check_pass, .data_check_error,
    .zero_done, .zero_error, .eh2_init_done, .eh2_init_error,
    .eh2_started, .eh2_stopped, .eh2_axi_idle, .log_tx_all_done,
    .fatal_error_pending, .fatal_error_code,
    .info_tx_full(info_full), .info_frame_done, .info_sent_code,
    .tx_frame_complete_count,
    .tx_submitted_frame_count,
    .info_tx_push(info_push), .info_tx_code(info_code),
    .data_atg_start, .instr_check_start, .data_check_start, .zero_start,
    .program_session_clear, .global_reset_request, .eh2_execute_enable,
    .prefer_log_tx, .led0, .state, .ddr0_owner, .ddr1_owner
  );

  logic [7:0] frame [0:59];
  integer frame_index;
  integer frame_count;
  logic [31:0] observed_codes [0:15];

  always_ff @(posedge clk) begin
    if (!resetn) begin
      frame_index <= 0;
      frame_count <= 0;
      tx_frame_complete_count <= 32'b0;
      tx_submitted_frame_count <= 32'b0;
    end else if (tx_valid && tx_ready) begin
      frame[frame_index] <= tx_data;
      if (tx_last) begin
        if (frame_index != 59)
          $fatal(1, "system frame length was %0d, expected 60", frame_index + 1);
        if ({frame[0],frame[1],frame[2],frame[3],frame[4],frame[5]} !=
            48'hff_ff_ff_ff_ff_ff)
          $fatal(1, "destination MAC mismatch");
        if ({frame[6],frame[7],frame[8],frame[9],frame[10],frame[11]} !=
            48'h02_32_05_25_00_ff)
          $fatal(1, "source MAC mismatch");
        if ({frame[12],frame[13]} != 16'h88b5)
          $fatal(1, "EtherType mismatch");
        if ({frame[18],frame[19]} != 16'h0320)
          $fatal(1, "payload signature mismatch");
        for (integer k = 20; k < 60; k = k + 1)
          if (frame[k] != 8'h00)
            $fatal(1, "payload zero padding mismatch at byte %0d", k);
        observed_codes[frame_count] <=
          {frame[14],frame[15],frame[16],frame[17]};
        frame_count <= frame_count + 1;
        tx_frame_complete_count <= tx_frame_complete_count + 32'd1;
        tx_submitted_frame_count <= tx_submitted_frame_count + 32'd1;
        frame_index <= 0;
      end else begin
        frame_index <= frame_index + 1;
      end
    end
  end

  task automatic pulse(input integer which);
    begin
      @(posedge clk);
      case (which)
        0: preconfig_program_end_pulse <= 1'b1;
        1: program_first_write_pulse <= 1'b1;
        2: program_end_pulse <= 1'b1;
      endcase
      @(posedge clk);
      preconfig_program_end_pulse <= 1'b0;
      program_first_write_pulse <= 1'b0;
      program_end_pulse <= 1'b0;
    end
  endtask

  task automatic wait_for_state(input system_state_t wanted);
    integer guard;
    begin
      guard = 0;
      while ((state != wanted) && (guard < 5000)) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (state != wanted)
        $fatal(1, "timeout waiting for state %0d, current %0d", wanted, state);
    end
  endtask

  initial begin
    tx_ready = 1'b1;
    mac_config_done = 1'b0;
    phy_init_done = 1'b0;
    phy_link_up = 1'b0;
    rgmii_rx_ready = 1'b0;
    mig0_ready = 1'b0;
    mig1_ready = 1'b0;
    preconfig_program_end_pulse = 1'b0;
    program_first_write_pulse = 1'b0;
    program_end_pulse = 1'b0;
    program_frame_count = 32'b0;
    program_dma_done_count = 32'b0;
    program_end_total_count = 32'b0;
    program_dma_busy = 1'b0;
    host_send_stopped_pulse = 1'b0;
    data_atg_done = 1'b0;
    data_atg_error = 1'b0;
    instr_check_done = 1'b0;
    instr_check_pass = 1'b0;
    instr_check_error = 1'b0;
    data_check_done = 1'b0;
    data_check_pass = 1'b0;
    data_check_error = 1'b0;
    zero_done = 1'b0;
    zero_error = 1'b0;
    eh2_init_done = 1'b0;
    eh2_init_error = 1'b0;
    eh2_started = 2'b00;
    eh2_stopped = 2'b00;
    eh2_axi_idle = 1'b1;
    log_tx_all_done = 1'b0;
    fatal_error_pending = 1'b0;
    fatal_error_code = 32'b0;

    repeat (5) @(posedge clk);
    resetn <= 1'b1;
    repeat (4) @(posedge clk);
    mac_config_done <= 1'b1;
    phy_init_done <= 1'b1;
    phy_link_up <= 1'b1;
    rgmii_rx_ready <= 1'b1;
    mig0_ready <= 1'b1;
    mig1_ready <= 1'b1;

    while (!data_atg_start) @(posedge clk);
    if ((ddr0_owner != DDR0_OWNER_PROGRAM) ||
        (ddr1_owner != DDR1_OWNER_ATG))
      $fatal(1, "PRECONFIG owner mismatch");
    repeat (3) @(posedge clk);
    data_atg_done <= 1'b1;
    program_frame_count <= 32'd1;
    pulse(1);
    wait (frame_count >= 2);
    program_end_total_count <= 32'd1;
    pulse(0);
    repeat (4) @(posedge clk);
    if ((ddr0_owner != DDR0_OWNER_PROGRAM) ||
        (ddr1_owner != DDR1_OWNER_ATG))
      $fatal(1, "PRECONFIG ownership changed before DMA/ATG completion");
    if (instr_check_start)
      $fatal(1, "PRECONFIG check started without preceding DMA done");
    program_dma_done_count <= 32'd1;
    while (!instr_check_start) @(posedge clk);
    if (!data_check_start)
      $fatal(1, "read checkers did not start together");
    if ((ddr0_owner != DDR0_OWNER_CHECKER) ||
        (ddr1_owner != DDR1_OWNER_CHECKER))
      $fatal(1, "PRECONFIG checker owner mismatch");
    @(posedge clk);
    instr_check_pass <= 1'b1;
    data_check_pass <= 1'b1;
    instr_check_done <= 1'b1;
    data_check_done <= 1'b1;

    wait_for_state(ST_READY);
    instr_check_done <= 1'b0;
    data_check_done <= 1'b0;
    while (!zero_start) @(posedge clk);
    if (ddr1_owner != DDR1_OWNER_ZERO)
      $fatal(1, "READY zero owner mismatch");
    repeat (5) @(posedge clk);
    zero_done <= 1'b1;
    wait (program_session_clear);

    wait_for_state(ST_PROGRAM_WRITE);
    zero_done <= 1'b0;
    if (ddr0_owner != DDR0_OWNER_PROGRAM)
      $fatal(1, "PROGRAM_WRITE owner mismatch");
    // Three program frames precede the end marker. Two older completions
    // must not be mistaken for completion of the immediately preceding
    // third frame.
    program_frame_count <= 32'd3;
    program_dma_done_count <= 32'd0;
    pulse(1);
    wait (frame_count >= 6);
    program_dma_done_count <= 32'd2;
    // The end marker alone must not produce PROGRAM_DONE.
    program_end_total_count <= 32'd3;
    pulse(2);
    repeat (8) @(posedge clk);
    if (state != ST_PROGRAM_WRITE)
      $fatal(1, "PROGRAM_WRITE completed without DMA done");
    // DMA done is also insufficient while the DataMover still reports busy.
    program_dma_busy <= 1'b1;
    program_dma_done_count <= 32'd3;
    repeat (4) @(posedge clk);
    if (state != ST_PROGRAM_WRITE)
      $fatal(1, "PROGRAM_WRITE completed while DMA busy");
    program_dma_busy <= 1'b0;

    wait_for_state(ST_EXECUTE);
    if ((ddr0_owner != DDR0_OWNER_EH2) || (ddr1_owner != DDR1_OWNER_EH2))
      $fatal(1, "EXECUTE owner mismatch");
    while (!eh2_execute_enable) @(posedge clk);
    eh2_init_done <= 1'b1;
    repeat (5) @(posedge clk);
    eh2_started[0] <= 1'b1;
    repeat (5) @(posedge clk);
    eh2_started[1] <= 1'b1;
    repeat (5) @(posedge clk);
    eh2_stopped[0] <= 1'b1;
    repeat (5) @(posedge clk);
    eh2_stopped[1] <= 1'b1;
    log_tx_all_done <= 1'b1;

    wait_for_state(ST_END);
    wait (global_reset_request);
    while (frame_count < 14) @(posedge clk);
    if (observed_codes[0] != MSG_PREINIT_DONE) $fatal(1, "preinit code");
    if (observed_codes[1] != MSG_PROGRAM_START)$fatal(1, "preconfig start code");
    if (observed_codes[2] != MSG_RECEIVE_DONE) $fatal(1, "preconfig receive code");
    if (observed_codes[3] != MSG_CHECK_PASS)   $fatal(1, "check pass code");
    if (observed_codes[4] != MSG_READY)        $fatal(1, "ready code");
    if (observed_codes[5] != MSG_PROGRAM_START)$fatal(1, "program start code");
    if (observed_codes[6] != MSG_RECEIVE_DONE) $fatal(1, "program receive code");
    if (observed_codes[7] != MSG_PROGRAM_DONE) $fatal(1, "program code");
    if (observed_codes[8] != MSG_HART0_START)  $fatal(1, "hart0 start code");
    if (observed_codes[9] != MSG_HART1_START)  $fatal(1, "hart1 start code");
    if (observed_codes[10] != MSG_HART0_DONE)  $fatal(1, "hart0 done code");
    if (observed_codes[11] != MSG_HART1_DONE)  $fatal(1, "hart1 done code");
    if (observed_codes[12] != MSG_EH2_DONE)    $fatal(1, "eh2 done code");
    if (observed_codes[13] != MSG_EXE_END)     $fatal(1, "end code");
    $display("TB_PASS controller frames=%0d", frame_count);
    $finish;
  end

  initial begin
    #2ms;
    $fatal(1, "global simulation timeout");
  end
endmodule
