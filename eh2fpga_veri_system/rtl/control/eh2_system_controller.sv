`timescale 1ns/1ps

module eh2_system_controller #(
  parameter integer PROGRAM_TIMEOUT_CYCLES = 2_000_000_000,
  parameter integer EXECUTE_GUARD_CYCLES   = 16,
  parameter integer AXI_IDLE_GUARD_CYCLES  = 16
) (
  input  logic clk,
  input  logic resetn,

  input  logic mac_config_done,
  input  logic phy_init_done,
  input  logic phy_link_up,
  input  logic rgmii_rx_ready,
  input  logic mig0_ready,
  input  logic mig1_ready,

  input  logic preconfig_program_end_pulse,
  input  logic program_first_write_pulse,
  input  logic program_end_pulse,
  input  logic [31:0] program_end_total_count,
  input  logic [31:0] program_frame_count,
  input  logic [31:0] program_dma_done_count,
  input  logic program_dma_busy,
  input  logic host_send_stopped_pulse,

  input  logic data_atg_done,
  input  logic data_atg_error,
  input  logic instr_check_done,
  input  logic instr_check_pass,
  input  logic instr_check_error,
  input  logic data_check_done,
  input  logic data_check_pass,
  input  logic data_check_error,
  input  logic zero_done,
  input  logic zero_error,

  input  logic eh2_init_done,
  input  logic eh2_init_error,
  input  logic [1:0] eh2_started,
  input  logic [1:0] eh2_stopped,
  input  logic eh2_axi_idle,
  input  logic log_tx_all_done,

  input  logic fatal_error_pending,
  input  logic [31:0] fatal_error_code,

  input  logic info_tx_full,
  input  logic info_frame_done,
  input  logic [31:0] info_sent_code,
  input  logic [31:0] tx_frame_complete_count,
  input  logic [31:0] tx_submitted_frame_count,
  output logic info_tx_push,
  output logic [31:0] info_tx_code,

  output logic data_atg_start,
  output logic instr_check_start,
  output logic data_check_start,
  output logic zero_start,
  output logic program_session_clear,
  output logic global_reset_request,
  output logic eh2_execute_enable,
  output logic prefer_log_tx,
  output logic led0,
  output eh2_system_pkg::system_state_t state,
  output eh2_system_pkg::ddr0_owner_t ddr0_owner,
  output eh2_system_pkg::ddr1_owner_t ddr1_owner
);
  import eh2_system_pkg::*;

  logic [4:0] phase;
  logic [31:0] expected_info_code;
  logic        waiting_info;
  logic        preconfig_end_seen;
  logic        program_end_seen;
  logic [31:0] preconfig_end_frame_count;
  logic [31:0] program_end_frame_count;
  logic [31:0] preconfig_end_total_count;
  logic [31:0] program_end_total_count_latched;
  logic        program_start_seen;
  logic        program_timer_running;
  logic [30:0] program_timer;
  logic [7:0]  reset_counter;
  logic [1:0]  preconfig_fail_mask;
  logic [31:0] captured_error_code;
  logic        error_code_already_sent;
  logic        host_stopped_seen;
  logic [3:0]  hart_status_pending;
  logic [3:0]  hart_status_queued;
  logic [3:0]  hart_status_sent;

  wire init_ready = mac_config_done && phy_init_done && phy_link_up &&
                    rgmii_rx_ready &&
                    mig0_ready && mig1_ready;
  wire info_expected_done = waiting_info && info_frame_done &&
                            (info_sent_code == expected_info_code);
  wire [31:0] preconfig_target_frame_count =
      preconfig_program_end_pulse ? program_frame_count :
                                    preconfig_end_frame_count;
  wire [31:0] program_target_frame_count =
      program_end_pulse ? program_frame_count : program_end_frame_count;
  wire [31:0] preconfig_target_total_count =
      preconfig_program_end_pulse ? program_end_total_count :
                                    preconfig_end_total_count;
  wire [31:0] program_target_total_count =
      program_end_pulse ? program_end_total_count :
                          program_end_total_count_latched;

  task automatic queue_info(input logic [31:0] code_value);
    begin
      if (!info_tx_full) begin
        info_tx_push      <= 1'b1;
        info_tx_code      <= code_value;
        expected_info_code <= code_value;
        waiting_info      <= 1'b1;
      end
    end
  endtask

  always_comb begin
    ddr0_owner = DDR0_OWNER_IDLE;
    ddr1_owner = DDR1_OWNER_IDLE;
    case (state)
      ST_PRECONFIG: begin
        // Phases 6..9 send the START/RECEIVE status frames and wait for the
        // accepted program frame to finish DMA.  They are still part of the
        // program-write window; do not hand DDR0 to the checker until phase 3
        // explicitly starts the readback check.
        if ((phase == 5'd3) || (phase == 5'd4) || (phase == 5'd5))
          ddr0_owner = DDR0_OWNER_CHECKER;
        else
          ddr0_owner = DDR0_OWNER_PROGRAM;
        // The data ATG runs in parallel with the PRECONFIG program-path test.
        // Preserve its ownership through phases 6..9 for the same reason.
        if ((phase == 5'd3) || (phase == 5'd4) || (phase == 5'd5))
          ddr1_owner = DDR1_OWNER_CHECKER;
        else
          ddr1_owner = DDR1_OWNER_ATG;
      end
      ST_READY: begin
        ddr0_owner = DDR0_OWNER_IDLE;
        ddr1_owner = DDR1_OWNER_ZERO;
      end
      ST_PROGRAM_WRITE: begin
        ddr0_owner = DDR0_OWNER_PROGRAM;
        ddr1_owner = DDR1_OWNER_IDLE;
      end
      ST_EXECUTE, ST_END: begin
        ddr0_owner = DDR0_OWNER_EH2;
        ddr1_owner = DDR1_OWNER_EH2;
      end
      default: begin
        ddr0_owner = DDR0_OWNER_IDLE;
        ddr1_owner = DDR1_OWNER_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state                   <= ST_PRECONFIG;
      phase                   <= 5'd0;
      expected_info_code      <= 32'b0;
      waiting_info            <= 1'b0;
      preconfig_end_seen      <= 1'b0;
      program_end_seen        <= 1'b0;
      preconfig_end_frame_count <= 32'b0;
      program_end_frame_count <= 32'b0;
      preconfig_end_total_count <= 32'b0;
      program_end_total_count_latched <= 32'b0;
      program_start_seen       <= 1'b0;
      program_timer_running   <= 1'b0;
      program_timer           <= 31'd0;
      reset_counter           <= 8'd0;
      preconfig_fail_mask     <= 2'b0;
      captured_error_code     <= 32'b0;
      error_code_already_sent <= 1'b0;
      host_stopped_seen       <= 1'b0;
      hart_status_pending     <= 4'b0;
      hart_status_queued      <= 4'b0;
      hart_status_sent        <= 4'b0;
      info_tx_push            <= 1'b0;
      info_tx_code            <= 32'b0;
      data_atg_start          <= 1'b0;
      instr_check_start       <= 1'b0;
      data_check_start        <= 1'b0;
      zero_start              <= 1'b0;
      program_session_clear   <= 1'b0;
      global_reset_request    <= 1'b0;
      eh2_execute_enable      <= 1'b0;
      prefer_log_tx           <= 1'b0;
      led0                    <= 1'b0;
    end else begin
      info_tx_push        <= 1'b0;
      data_atg_start      <= 1'b0;
      instr_check_start   <= 1'b0;
      data_check_start    <= 1'b0;
      zero_start          <= 1'b0;
      program_session_clear <= 1'b0;
      global_reset_request  <= 1'b0;

      // The acknowledgement may arrive while the error information frame is
      // still being drained.  Retain it until the hard-reset request is made.
      if ((state == ST_ERROR) && host_send_stopped_pulse)
        host_stopped_seen <= 1'b1;

      if (program_first_write_pulse &&
          ((state == ST_PRECONFIG) || (state == ST_PROGRAM_WRITE)))
        program_start_seen <= 1'b1;

      if (preconfig_program_end_pulse && (state == ST_PRECONFIG)) begin
        preconfig_end_seen <= 1'b1;
        preconfig_end_frame_count <= program_frame_count;
        preconfig_end_total_count <= program_end_total_count;
      end
      if (program_end_pulse && (state == ST_PROGRAM_WRITE)) begin
        program_end_seen <= 1'b1;
        program_end_frame_count <= program_frame_count;
        program_end_total_count_latched <= program_end_total_count;
      end

      if (info_expected_done)
        waiting_info <= 1'b0;

      // Capture first-retirement and stop levels only while EXECUTE is
      // active. These information frames use an independent four-entry event
      // tracker, so they cannot overwrite the state machine's expected code.
      if (state != ST_EXECUTE) begin
        hart_status_pending <= 4'b0;
        hart_status_queued  <= 4'b0;
        hart_status_sent    <= 4'b0;
      end else if (!fatal_error_pending) begin
        if (eh2_started[0] && !hart_status_queued[0])
          hart_status_pending[0] <= 1'b1;
        if (eh2_started[1] && !hart_status_queued[1])
          hart_status_pending[1] <= 1'b1;
        if (eh2_stopped[0] && !hart_status_queued[2])
          hart_status_pending[2] <= 1'b1;
        if (eh2_stopped[1] && !hart_status_queued[3])
          hart_status_pending[3] <= 1'b1;

        if (!info_tx_full) begin
          if (hart_status_pending[0]) begin
            info_tx_push <= 1'b1;
            info_tx_code <= MSG_HART0_START;
            hart_status_pending[0] <= 1'b0;
            hart_status_queued[0] <= 1'b1;
          end else if (hart_status_pending[1]) begin
            info_tx_push <= 1'b1;
            info_tx_code <= MSG_HART1_START;
            hart_status_pending[1] <= 1'b0;
            hart_status_queued[1] <= 1'b1;
          end else if (hart_status_pending[2]) begin
            info_tx_push <= 1'b1;
            info_tx_code <= MSG_HART0_DONE;
            hart_status_pending[2] <= 1'b0;
            hart_status_queued[2] <= 1'b1;
          end else if (hart_status_pending[3]) begin
            info_tx_push <= 1'b1;
            info_tx_code <= MSG_HART1_DONE;
            hart_status_pending[3] <= 1'b0;
            hart_status_queued[3] <= 1'b1;
          end
        end

        if (info_frame_done) begin
          case (info_sent_code)
            MSG_HART0_START: hart_status_sent[0] <= 1'b1;
            MSG_HART1_START: hart_status_sent[1] <= 1'b1;
            MSG_HART0_DONE:  hart_status_sent[2] <= 1'b1;
            MSG_HART1_DONE:  hart_status_sent[3] <= 1'b1;
            default: ;
          endcase
        end
      end

      // Hardware failures take priority over normal phase progress.  In
      // EXECUTE the arbiter completes any active log frame before selecting
      // the system-information error frame.
      if (fatal_error_pending && (state != ST_ERROR)) begin
        state                   <= ST_ERROR;
        phase                   <= 5'd0;
        waiting_info            <= 1'b0;
        captured_error_code     <= fatal_error_code;
        error_code_already_sent <= 1'b0;
        eh2_execute_enable      <= 1'b0;
        prefer_log_tx           <= 1'b0;
        led0                    <= 1'b1;
      end else begin
        case (state)
          ST_PRECONFIG: begin
            eh2_execute_enable <= 1'b0;
            prefer_log_tx      <= 1'b0;
            case (phase)
              5'd0: begin
                if (init_ready) begin
                  queue_info(MSG_PREINIT_DONE);
                  if (!info_tx_full)
                    phase <= 5'd1;
                end
              end
              5'd1: begin
                if (info_expected_done) begin
                  data_atg_start <= 1'b1;
                  phase <= 5'd2;
                end
              end
              5'd2: begin
                if (program_start_seen) begin
                  queue_info(MSG_PROGRAM_START);
                  if (!info_tx_full)
                    phase <= 5'd6;
                end
              end
              5'd6: begin
                if (info_expected_done)
                  phase <= 5'd7;
              end
              5'd7: begin
                if (preconfig_end_seen || preconfig_program_end_pulse) begin
                  queue_info(MSG_RECEIVE_DONE);
                  if (!info_tx_full)
                    phase <= 5'd8;
                end
              end
              5'd8: begin
                if (info_expected_done)
                  phase <= 5'd9;
              end
              5'd9: begin
                // PRECONFIG accepts exactly sequence zero and an end marker
                // declaring one packet. The 32-bit sequence prefix is never
                // written to DDR; only the unchanged 1024-byte FF payload is.
                if ((preconfig_target_total_count != 32'd1) ||
                    (preconfig_target_frame_count !=
                     preconfig_target_total_count)) begin
                  captured_error_code <= ERR_PROGRAM_COUNT;
                  state <= ST_ERROR;
                  phase <= 5'd0;
                end else if (program_dma_done_count >
                             preconfig_target_total_count) begin
                  captured_error_code <= ERR_PROGRAM_COUNT;
                  state <= ST_ERROR;
                  phase <= 5'd0;
                end else if ((program_dma_done_count ==
                              preconfig_target_total_count) &&
                             !program_dma_busy && data_atg_done) begin
                  if (data_atg_error) begin
                    captured_error_code <= ERR_DDR_CHECK;
                    state <= ST_ERROR;
                    phase <= 5'd0;
                  end else begin
                    instr_check_start <= 1'b1;
                    data_check_start  <= 1'b1;
                    phase <= 5'd3;
                  end
                end
              end
              5'd3: begin
                if (instr_check_done && data_check_done) begin
                  preconfig_fail_mask[0] <= instr_check_error ||
                                            !instr_check_pass;
                  preconfig_fail_mask[1] <= data_check_error ||
                                            !data_check_pass;
                  phase <= 5'd4;
                end
              end
              5'd4: begin
                if (preconfig_fail_mask[1])
                  queue_info(MSG_DATA_FAIL);
                else if (preconfig_fail_mask[0])
                  queue_info(MSG_INSTR_FAIL);
                else
                  queue_info(MSG_CHECK_PASS);
                if (!info_tx_full)
                  phase <= 5'd5;
              end
              5'd5: begin
                if (info_expected_done) begin
                  if (preconfig_fail_mask[1]) begin
                    preconfig_fail_mask[1] <= 1'b0;
                    if (preconfig_fail_mask[0])
                      phase <= 5'd4;
                    else begin
                      captured_error_code <= MSG_DATA_FAIL;
                      error_code_already_sent <= 1'b1;
                      state <= ST_ERROR;
                      phase <= 5'd0;
                    end
                  end else if (preconfig_fail_mask[0]) begin
                    preconfig_fail_mask[0] <= 1'b0;
                    captured_error_code <= MSG_INSTR_FAIL;
                    error_code_already_sent <= 1'b1;
                    state <= ST_ERROR;
                    phase <= 5'd0;
                  end else begin
                    state <= ST_READY;
                    phase <= 5'd0;
                    preconfig_end_seen <= 1'b0;
                    program_start_seen <= 1'b0;
                  end
                end
              end
              default: begin
                captured_error_code <= ERR_ILLEGAL_STATE;
                state <= ST_ERROR;
                phase <= 5'd0;
              end
            endcase
          end

          ST_READY: begin
            led0               <= 1'b0;
            eh2_execute_enable <= 1'b0;
            prefer_log_tx      <= 1'b0;
            case (phase)
              5'd0: begin
                zero_start <= 1'b1;
                phase <= 5'd1;
              end
              5'd1: begin
                if (zero_done) begin
                  if (zero_error) begin
                    captured_error_code <= ERR_DDR_ZERO;
                    state <= ST_ERROR;
                    phase <= 5'd0;
                  end else begin
                    // PRECONFIG used the same receive/DMA path for its one
                    // test frame.  Reload only the idle protocol bookkeeping;
                    // no clock domain, MAC, DMA engine, EH2 or log block is
                    // reset here.
                    program_session_clear <= 1'b1;
                    phase               <= 5'd2;
                  end
                end
              end
              5'd2: begin
                phase <= 5'd3;
              end
              5'd3: begin
                queue_info(MSG_READY);
                if (!info_tx_full)
                  phase <= 5'd4;
              end
              5'd4: begin
                if (info_expected_done) begin
                  state <= ST_PROGRAM_WRITE;
                  phase <= 5'd0;
                  program_start_seen <= 1'b0;
                  program_end_seen <= 1'b0;
                  program_end_frame_count <= 32'b0;
                  program_end_total_count_latched <= 32'b0;
                  program_timer <= 31'd0;
                  program_timer_running <= 1'b0;
                end
              end
              default: begin
                captured_error_code <= ERR_ILLEGAL_STATE;
                state <= ST_ERROR;
                phase <= 5'd0;
              end
            endcase
          end

          ST_PROGRAM_WRITE: begin
            eh2_execute_enable <= 1'b0;
            prefer_log_tx      <= 1'b0;
            if (program_first_write_pulse && !program_timer_running) begin
              program_timer_running <= 1'b1;
              program_timer <= 31'd1;
            end else if (program_timer_running && !program_end_seen &&
                         !program_end_pulse) begin
              if (program_timer >= PROGRAM_TIMEOUT_CYCLES - 1) begin
                program_timer_running <= 1'b0;
                captured_error_code <= ERR_PROGRAM_OVERTIME;
                state <= ST_ERROR;
                phase <= 5'd0;
              end else begin
                program_timer <= program_timer + 31'd1;
              end
            end

            case (phase)
              5'd0: begin
                if (program_start_seen) begin
                  queue_info(MSG_PROGRAM_START);
                  if (!info_tx_full)
                    phase <= 5'd2;
                end
              end
              5'd2: begin
                if (info_expected_done) begin
                  phase <= 5'd3;
                end
              end
              5'd3: begin
                if (program_end_seen || program_end_pulse) begin
                  queue_info(MSG_RECEIVE_DONE);
                  if (!info_tx_full)
                    phase <= 5'd4;
                end
              end
              5'd4: begin
                if (info_expected_done)
                  phase <= 5'd5;
              end
              5'd5: begin
                // The external count, accepted sequence count and successful
                // DMA count must all agree before PROGRAM_WRITE_DONE.
                if ((program_target_total_count == 32'd0) ||
                    (program_target_frame_count !=
                     program_target_total_count)) begin
                  captured_error_code <= ERR_PROGRAM_COUNT;
                  state <= ST_ERROR;
                  phase <= 5'd0;
                end else if (program_dma_done_count >
                             program_target_total_count) begin
                  captured_error_code <= ERR_PROGRAM_COUNT;
                  state <= ST_ERROR;
                  phase <= 5'd0;
                end else if ((program_dma_done_count ==
                               program_target_total_count) &&
                              !program_dma_busy) begin
                  program_timer_running <= 1'b0;
                  queue_info(MSG_PROGRAM_DONE);
                  if (!info_tx_full)
                    phase <= 5'd1;
                end
              end
              5'd1: begin
                if (info_expected_done) begin
                  state <= ST_EXECUTE;
                  phase <= 5'd0;
                  reset_counter <= 8'd0;
                  prefer_log_tx <= 1'b1;
                end
              end
              default: begin
                captured_error_code <= ERR_ILLEGAL_STATE;
                state <= ST_ERROR;
                phase <= 5'd0;
              end
            endcase
          end

          ST_EXECUTE: begin
            prefer_log_tx <= 1'b1;
            case (phase)
              5'd0: begin
                if (reset_counter >= EXECUTE_GUARD_CYCLES - 1) begin
                  eh2_execute_enable <= 1'b1;
                  reset_counter <= 8'd0;
                  phase <= 5'd1;
                end else begin
                  reset_counter <= reset_counter + 8'd1;
                end
              end
              5'd1: begin
                eh2_execute_enable <= 1'b1;
                if (eh2_init_error) begin
                  captured_error_code <= ERR_EH2_INIT;
                  state <= ST_ERROR;
                  phase <= 5'd0;
                  prefer_log_tx <= 1'b0;
                  eh2_execute_enable <= 1'b0;
                end else if (eh2_init_done) begin
                  phase <= 5'd2;
                end
              end
              5'd2: begin
                eh2_execute_enable <= 1'b1;
                // A stop marker is observed on the EH2-side AXI interface
                // before the final DDR response necessarily returns through
                // the clock/width converters. Keep the core and both DDR
                // muxes in EXECUTE until all accepted IFU/LSU transactions
                // have drained for a continuous guard interval.
                if ((eh2_stopped == 2'b11) && log_tx_all_done &&
                    (hart_status_sent == 4'b1111) && eh2_axi_idle) begin
                  if (reset_counter >= AXI_IDLE_GUARD_CYCLES - 1) begin
                    state <= ST_END;
                    phase <= 5'd0;
                    prefer_log_tx <= 1'b0;
                    reset_counter <= 8'd0;
                  end else begin
                    reset_counter <= reset_counter + 8'd1;
                  end
                end else begin
                  reset_counter <= 8'd0;
                end
              end
              default: begin
                captured_error_code <= ERR_ILLEGAL_STATE;
                state <= ST_ERROR;
                phase <= 5'd0;
                prefer_log_tx <= 1'b0;
                eh2_execute_enable <= 1'b0;
              end
            endcase
          end

          ST_END: begin
            eh2_execute_enable <= 1'b0;
            prefer_log_tx      <= 1'b0;
            case (phase)
              5'd0: begin
                queue_info(MSG_EH2_DONE);
                if (!info_tx_full)
                  phase <= 5'd1;
              end
              5'd1: begin
                if (info_expected_done)
                  phase <= 5'd4;
              end
              5'd4: begin
                if (tx_frame_complete_count == tx_submitted_frame_count)
                  phase <= 5'd2;
              end
              5'd2: begin
                queue_info(MSG_EXE_END);
                if (!info_tx_full)
                  phase <= 5'd3;
              end
              5'd3: begin
                if (info_expected_done)
                  phase <= 5'd5;
              end
              5'd5: begin
                if (tx_frame_complete_count == tx_submitted_frame_count) begin
                  // A normal session terminates only after EXE_END has crossed
                  // the physical MAC completion boundary.
                  global_reset_request <= 1'b1;
                end
              end
              default: begin
                captured_error_code <= ERR_ILLEGAL_STATE;
                state <= ST_ERROR;
                phase <= 5'd0;
              end
            endcase
          end

          ST_ERROR: begin
            led0               <= 1'b1;
            eh2_execute_enable <= 1'b0;
            prefer_log_tx      <= 1'b0;
            if (error_code_already_sent) begin
              // Do not reset while the PC may still be injecting frames.
              // Once it acknowledges that transmission has stopped, request
              // the board-equivalent reset and remain in ERROR until it acts.
              if (host_stopped_seen || host_send_stopped_pulse)
                global_reset_request <= 1'b1;
            end else begin
              if (phase == 5'd0) begin
                queue_info(captured_error_code);
                if (!info_tx_full)
                  phase <= 5'd1;
              end else if ((phase == 5'd1) && info_expected_done) begin
                error_code_already_sent <= 1'b1;
                program_timer_running <= 1'b0;
              end
            end
          end

          default: begin
            captured_error_code <= ERR_ILLEGAL_STATE;
            state <= ST_ERROR;
            phase <= 5'd0;
          end
        endcase
      end
    end
  end
endmodule
