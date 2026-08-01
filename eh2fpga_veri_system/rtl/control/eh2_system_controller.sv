`timescale 1ns/1ps

module eh2_system_controller #(
  parameter integer PROGRAM_TIMEOUT_CYCLES = 2_000_000_000,
  parameter integer SOFT_RESET_CYCLES      = 16,
  parameter integer EXECUTE_GUARD_CYCLES   = 16,
  parameter integer AXI_IDLE_GUARD_CYCLES  = 16
) (
  input  logic clk,
  input  logic resetn,

  input  logic mac_config_done,
  input  logic phy_init_done,
  input  logic phy_link_up,
  input  logic mig0_ready,
  input  logic mig1_ready,

  input  logic preconfig_program_end_pulse,
  input  logic program_first_write_pulse,
  input  logic program_end_pulse,
  input  logic [31:0] program_frame_count,
  input  logic [31:0] program_dma_done_count,
  input  logic program_dma_busy,

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
  input  logic [1:0] eh2_stopped,
  input  logic eh2_axi_idle,
  input  logic log_tx_all_done,

  input  logic fatal_error_pending,
  input  logic [31:0] fatal_error_code,

  input  logic info_tx_full,
  input  logic info_frame_done,
  input  logic [31:0] info_sent_code,
  output logic info_tx_push,
  output logic [31:0] info_tx_code,

  output logic data_atg_start,
  output logic instr_check_start,
  output logic data_check_start,
  output logic zero_start,
  output logic ready_soft_reset,
  output logic error_monitor_clear,
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
  logic        program_timer_running;
  logic [30:0] program_timer;
  logic [7:0]  reset_counter;
  logic [1:0]  preconfig_fail_mask;
  logic [31:0] captured_error_code;
  logic        error_code_already_sent;

  wire init_ready = mac_config_done && phy_init_done && phy_link_up &&
                    mig0_ready && mig1_ready;
  wire info_expected_done = waiting_info && info_frame_done &&
                            (info_sent_code == expected_info_code);
  wire [31:0] preconfig_target_frame_count =
      preconfig_program_end_pulse ? program_frame_count :
                                    preconfig_end_frame_count;
  wire [31:0] program_target_frame_count =
      program_end_pulse ? program_frame_count : program_end_frame_count;

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
        if (phase < 5'd3)
          ddr0_owner = DDR0_OWNER_PROGRAM;
        else
          ddr0_owner = DDR0_OWNER_CHECKER;
        if (phase < 5'd3)
          ddr1_owner = DDR1_OWNER_ATG;
        else
          ddr1_owner = DDR1_OWNER_CHECKER;
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
      program_timer_running   <= 1'b0;
      program_timer           <= 31'd0;
      reset_counter           <= 8'd0;
      preconfig_fail_mask     <= 2'b0;
      captured_error_code     <= 32'b0;
      error_code_already_sent <= 1'b0;
      info_tx_push            <= 1'b0;
      info_tx_code            <= 32'b0;
      data_atg_start          <= 1'b0;
      instr_check_start       <= 1'b0;
      data_check_start        <= 1'b0;
      zero_start              <= 1'b0;
      ready_soft_reset        <= 1'b0;
      error_monitor_clear     <= 1'b0;
      eh2_execute_enable      <= 1'b0;
      prefer_log_tx           <= 1'b0;
      led0                    <= 1'b0;
    end else begin
      info_tx_push        <= 1'b0;
      data_atg_start      <= 1'b0;
      instr_check_start   <= 1'b0;
      data_check_start    <= 1'b0;
      zero_start          <= 1'b0;
      error_monitor_clear <= 1'b0;

      if (preconfig_program_end_pulse) begin
        preconfig_end_seen <= 1'b1;
        if (state == ST_PRECONFIG)
          preconfig_end_frame_count <= program_frame_count;
      end
      if (program_end_pulse) begin
        program_end_seen <= 1'b1;
        if (state == ST_PROGRAM_WRITE)
          program_end_frame_count <= program_frame_count;
      end

      if (info_expected_done)
        waiting_info <= 1'b0;

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
                if (preconfig_end_seen || preconfig_program_end_pulse) begin
                  // PRECONFIG accepts exactly one program frame. The end
                  // frame snapshots target count 1, and the check starts
                  // only after that same frame has completed successfully.
                  if (preconfig_target_frame_count != 32'd1) begin
                    captured_error_code <= ERR_PROGRAM_WRITE;
                    state <= ST_ERROR;
                    phase <= 5'd0;
                  end else if (program_dma_done_count >
                               preconfig_target_frame_count) begin
                    captured_error_code <= ERR_PROGRAM_WRITE;
                    state <= ST_ERROR;
                    phase <= 5'd0;
                  end else if ((program_dma_done_count ==
                                preconfig_target_frame_count) &&
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
                    ready_soft_reset    <= 1'b1;
                    error_monitor_clear <= 1'b1;
                    reset_counter       <= 8'd1;
                    phase               <= 5'd2;
                  end
                end
              end
              5'd2: begin
                ready_soft_reset <= 1'b1;
                if (reset_counter >= SOFT_RESET_CYCLES - 1) begin
                  ready_soft_reset <= 1'b0;
                  reset_counter <= 8'd0;
                  phase <= 5'd3;
                end else begin
                  reset_counter <= reset_counter + 8'd1;
                end
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
                  program_end_seen <= 1'b0;
                  program_end_frame_count <= 32'b0;
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
                if (program_end_seen || program_end_pulse) begin
                  // The end frame snapshots the number of preceding program
                  // frames. An older DMA completion cannot satisfy the last
                  // frame: the success count must reach this exact target.
                  if (program_target_frame_count == 32'd0) begin
                    captured_error_code <= ERR_PROGRAM_WRITE;
                    state <= ST_ERROR;
                    phase <= 5'd0;
                  end else if (program_dma_done_count >
                               program_target_frame_count) begin
                    captured_error_code <= ERR_PROGRAM_WRITE;
                    state <= ST_ERROR;
                    phase <= 5'd0;
                  end else if ((program_dma_done_count ==
                                program_target_frame_count) &&
                               !program_dma_busy) begin
                    program_timer_running <= 1'b0;
                    queue_info(MSG_PROGRAM_DONE);
                    if (!info_tx_full)
                      phase <= 5'd1;
                  end
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
                    eh2_axi_idle) begin
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
                  phase <= 5'd2;
              end
              5'd2: begin
                queue_info(MSG_EXE_END);
                if (!info_tx_full)
                  phase <= 5'd3;
              end
              5'd3: begin
                if (info_expected_done) begin
                  state <= ST_READY;
                  phase <= 5'd0;
                  program_end_seen <= 1'b0;
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
            if (!error_code_already_sent) begin
              if (phase == 5'd0) begin
                queue_info(captured_error_code);
                if (!info_tx_full)
                  phase <= 5'd1;
              end else if ((phase == 5'd1) && info_expected_done) begin
                error_code_already_sent <= 1'b1;
                phase <= 5'd2;
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
