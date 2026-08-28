// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Cycle-accurate reference retained for differential verification after the
// production implementation was split into two physical Hart banks.  This
// module is not instantiated by the FPGA top level.
module instr_info_capture_dual_reference #(
    parameter integer LSU_TAG_WIDTH = 4
) (
    input  logic                         clk,
    input  logic                         rst_l,
    input  logic [1:0]                   rv_commit_valid,
    input  logic [1:0][31:0]             rv_commit_insn,
    input  logic [1:0][31:0]             rv_commit_pc,
    input  logic [1:0]                   rv_commit_hart_id,
    input  logic [1:0][1:0]              rv_commit_priv_mode,
    input  logic [1:0]                   rv_commit_gpr_wen_intent,
    input  logic [1:0]                   rv_commit_gpr_wen,
    input  logic [1:0][4:0]              rv_commit_gpr_rd,
    input  logic [1:0][31:0]             rv_commit_gpr_wdata,
    input  logic [1:0]                   rv_commit_csr_wen,
    input  logic [1:0][11:0]             rv_commit_csr_addr,
    input  logic [1:0][31:0]             rv_commit_csr_wdata,
    input  logic [1:0]                   rv_commit_is_nonblock,
    input  logic [1:0]                   rv_commit_is_nonblock_load,
    input  logic [1:0]                   rv_commit_is_nonblock_div,
    input  logic [1:0]                   rv_commit_waw_victim,
    input  logic [1:0]                   rv_nb_waw_valid,
    input  logic [1:0]                   rv_nb_waw_victim_hart_id,
    input  logic [1:0][4:0]              rv_nb_waw_victim_gpr_rd,
    input  logic [1:0]                   rv_nb_waw_victim_is_load,
    input  logic [1:0]                   rv_nb_waw_victim_is_div,
    input  logic                         rv_nb_load_gpr_wen,
    input  logic                         rv_nb_load_gpr_hart_id,
    input  logic [4:0]                   rv_nb_load_gpr_rd,
    input  logic [31:0]                  rv_nb_load_gpr_wdata,
    input  logic                         rv_nb_div_gpr_wen,
    input  logic                         rv_nb_div_gpr_hart_id,
    input  logic [4:0]                   rv_nb_div_gpr_rd,
    input  logic [31:0]                  rv_nb_div_gpr_wdata,
    input  logic                         lsu_axi_awvalid,
    input  logic                         lsu_axi_awready,
    input  logic [LSU_TAG_WIDTH-1:0]     lsu_axi_awid,
    input  logic [31:0]                  lsu_axi_awaddr,
    input  logic                         lsu_axi_wvalid,
    input  logic                         lsu_axi_wready,
    input  logic [63:0]                  lsu_axi_wdata,
    input  logic [7:0]                   lsu_axi_wstrb,

    output logic [1:0][3:0]              record_valid,
    output logic [1:0][3:0][255:0]       record_data,
    input  logic [1:0][3:0]              record_ready,
    output logic [1:0]                   stopped,
    output logic [1:0][31:0]             next_sequence,
    output logic [1:0][31:0]             commit_count,
    output logic [1:0][31:0]             generated_count,
    output logic [1:0][5:0]              pending_nonblock_count,
    output logic                         capture_done,
    output logic [1:0]                   nonblock_conflict_hart,
    output logic [1:0]                   record_overflow_hart,
    output logic [1:0]                   waw_cause_error_hart
);
    import info_struct_pkg::*;
    localparam logic [1:0] EVENT_NONE = 2'd0;
    localparam logic [1:0] EVENT_GPR  = 2'd1;
    localparam logic [1:0] EVENT_CSR  = 2'd2;
    localparam logic [31:0] STOP_ADDR = 32'hD058_0000;
    localparam logic [31:0] STOP_DATA = 32'h0032_0525;

    logic marker_addr_pending, marker_data_pending, marker_addr_hart;
    logic marker_addr_hs, marker_data_hs, marker_store_event;
    logic marker_store_hart;
    logic [1:0] stopped_next;
    logic [1:0] process_valid;
    logic [1:0][31:0] lane_sequence;
    logic [1:0][31:0] sequence_work;
    logic [1:0][1:0] lane_event;
    logic [1:0][11:0] lane_register;
    logic [1:0][31:0] lane_result;
    logic [1:0][1:0] lane_waw_kind;
    logic [1:0][31:0] lane_cancel_number;
    logic [1:0][191:0] lane_struct;
    logic [1:0][255:0] lane_record;
    logic [1:0] same_cycle_nb_return;
    logic [1:0][31:0] same_cycle_nb_data;
    logic [1:0] alloc_request, alloc_accept, alloc_atomic;
    logic [1:0] direct_valid;

    logic [191:0] nb_struct [0:1][0:31];
    logic         nb_valid [0:1][0:31];
    logic         nb_resolved [0:1][0:31];
    logic         nb_is_load [0:1][0:31];
    logic [191:0] emit_struct [0:1][0:31];
    logic         emit_valid [0:1][0:31];
    logic         emit_selected [0:1][0:31];
    logic         nb_cancel_match [0:1][0:31];
    logic [1:0]   nb_cancel_kind [0:1][0:31];
    logic [31:0]  nb_cancel_number [0:1][0:31];
    logic         nb_atomic [0:1][0:31];
    logic [191:0] nb_atomic_struct [0:1][0:31];

    logic [31:0] pick_mask [0:1][0:4];
    logic [31:0] pick_onehot [0:1][0:3];
    logic        pick_valid [0:1][0:3];
    logic [4:0]  pick_rd [0:1][0:3];
    logic [191:0] pick_struct [0:1][0:3];
    logic [1:0][3:0] candidate_valid;
    logic [1:0][3:0][191:0] candidate_struct;
    logic [1:0][3:0] candidate_is_emit;
    logic [1:0][3:0][4:0] candidate_emit_rd;
    logic [1:0][3:0] candidate_accept;
    logic [1:0][2:0] accepted_count;

    function automatic logic [191:0] make_struct(
        input logic [31:0] sequence_id,
        input logic [31:0] pc,
        input logic [31:0] instruction,
        input logic hart,
        input logic [1:0] privilege,
        input logic [1:0] event_type,
        input logic [11:0] register_number,
        input logic [31:0] data,
        input logic [1:0] cancel_kind,
        input logic [31:0] cancel_number
    );
      logic [31:0] metadata;
      begin
        metadata = {cancel_kind, 13'b0, hart, privilege,
                    event_type, register_number};
        make_struct = {sequence_id, pc, instruction, metadata,
                       data, cancel_number};
      end
    endfunction

    function automatic logic [191:0] cancel_struct(
        input logic [191:0] original,
        input logic [1:0] cancel_kind,
        input logic [31:0] cancel_number
    );
      logic [191:0] changed;
      begin
        changed = original;
        changed[95:94] = cancel_kind;
        changed[63:32] = 32'b0;
        changed[31:0] = cancel_number;
        cancel_struct = changed;
      end
    endfunction

    assign marker_addr_hs = lsu_axi_awvalid && lsu_axi_awready &&
                            (lsu_axi_awaddr == STOP_ADDR);
    assign marker_data_hs = lsu_axi_wvalid && lsu_axi_wready &&
                            (&lsu_axi_wstrb[3:0]) &&
                            (lsu_axi_wdata[31:0] == STOP_DATA);
    assign marker_store_event = (marker_addr_pending || marker_addr_hs) &&
                                (marker_data_pending || marker_data_hs);
    assign marker_store_hart = marker_addr_hs ?
                               lsu_axi_awid[LSU_TAG_WIDTH-1] :
                               marker_addr_hart;

    always_comb begin
      stopped_next = stopped;
      if (marker_store_event)
        stopped_next[marker_store_hart] = 1'b1;
      for (integer lane = 0; lane < 2; lane = lane + 1)
        process_valid[lane] = rv_commit_valid[lane] &&
          !stopped_next[rv_commit_hart_id[lane]];
    end

    always_comb begin
      sequence_work = next_sequence;
      lane_sequence = '0;
      for (integer lane = 0; lane < 2; lane = lane + 1) begin
        lane_sequence[lane] = sequence_work[rv_commit_hart_id[lane]];
        if (process_valid[lane])
          sequence_work[rv_commit_hart_id[lane]] =
              sequence_work[rv_commit_hart_id[lane]] + 1'b1;
      end
    end

    always_comb begin
      lane_event = '0;
      lane_register = '0;
      lane_result = '0;
      lane_waw_kind = '0;
      lane_cancel_number = '0;
      lane_struct = '0;
      lane_record = '0;
      same_cycle_nb_return = '0;
      same_cycle_nb_data = '0;
      alloc_request = '0;
      direct_valid = '0;

      for (integer lane = 0; lane < 2; lane = lane + 1) begin
        same_cycle_nb_return[lane] =
          (rv_commit_is_nonblock_load[lane] && rv_nb_load_gpr_wen &&
           (rv_nb_load_gpr_hart_id == rv_commit_hart_id[lane]) &&
           (rv_nb_load_gpr_rd == rv_commit_gpr_rd[lane])) ||
          (rv_commit_is_nonblock_div[lane] && rv_nb_div_gpr_wen &&
           (rv_nb_div_gpr_hart_id == rv_commit_hart_id[lane]) &&
           (rv_nb_div_gpr_rd == rv_commit_gpr_rd[lane]));
        same_cycle_nb_data[lane] = rv_commit_is_nonblock_load[lane] ?
                                   rv_nb_load_gpr_wdata :
                                   rv_nb_div_gpr_wdata;

        if (rv_commit_waw_victim[lane] &&
            (rv_commit_gpr_rd[lane] != 0)) begin
          lane_event[lane] = EVENT_GPR;
          lane_register[lane] = {7'b0, rv_commit_gpr_rd[lane]};
          lane_result[lane] = 32'b0;
          lane_waw_kind[lane] = WAW_CANCEL_DIRECT;
          // EH2 only marks older lane0 as a same-cycle victim.  Lane1 is the
          // younger writer that suppresses its architectural writeback.
          lane_cancel_number[lane] = lane_sequence[1];
        end else if (rv_commit_csr_wen[lane]) begin
          lane_event[lane] = EVENT_CSR;
          lane_register[lane] = rv_commit_csr_addr[lane];
          lane_result[lane] = rv_commit_csr_wdata[lane];
        end else if (rv_commit_gpr_wen[lane] &&
                     (rv_commit_gpr_rd[lane] != 0)) begin
          lane_event[lane] = EVENT_GPR;
          lane_register[lane] = {7'b0, rv_commit_gpr_rd[lane]};
          lane_result[lane] = rv_commit_gpr_wdata[lane];
        end else if (rv_commit_is_nonblock[lane] &&
                     rv_commit_gpr_wen_intent[lane] &&
                     (rv_commit_gpr_rd[lane] != 0)) begin
          lane_event[lane] = EVENT_GPR;
          lane_register[lane] = {7'b0, rv_commit_gpr_rd[lane]};
          lane_result[lane] = same_cycle_nb_return[lane] ?
                              same_cycle_nb_data[lane] : 32'b0;
        end

        lane_struct[lane] = make_struct(
          lane_sequence[lane], rv_commit_pc[lane], rv_commit_insn[lane],
          rv_commit_hart_id[lane], rv_commit_priv_mode[lane],
          lane_event[lane], lane_register[lane], lane_result[lane],
          lane_waw_kind[lane], lane_cancel_number[lane]
        );
        lane_record[lane] = {lane_struct[lane], 64'b0};
        alloc_request[lane] = process_valid[lane] &&
          rv_commit_is_nonblock[lane] &&
          rv_commit_gpr_wen_intent[lane] &&
          (rv_commit_gpr_rd[lane] != 0) &&
          !rv_commit_waw_victim[lane] &&
          !same_cycle_nb_return[lane];
        direct_valid[lane] = process_valid[lane] && !alloc_request[lane];
      end
    end

    // A nonblocking WAW sideband belongs to the current commit lane.  Its
    // lane sequence is therefore the cancelling instruction number.  If both
    // lanes hit the same victim, the later loop iteration deliberately keeps
    // lane1, the younger architectural writer.
    always_comb begin
      for (integer hart = 0; hart < 2; hart = hart + 1)
        for (integer rd = 0; rd < 32; rd = rd + 1) begin
          nb_cancel_match[hart][rd] = 1'b0;
          nb_cancel_kind[hart][rd] = WAW_CANCEL_NONE;
          nb_cancel_number[hart][rd] = 32'b0;
          for (integer lane = 0; lane < 2; lane = lane + 1)
            if (rv_nb_waw_valid[lane] &&
                (rv_nb_waw_victim_hart_id[lane] == hart) &&
                (rv_nb_waw_victim_gpr_rd[lane] == rd)) begin
              nb_cancel_match[hart][rd] = 1'b1;
              nb_cancel_number[hart][rd] = lane_sequence[lane];
              if (rv_nb_waw_victim_is_load[lane])
                nb_cancel_kind[hart][rd] = WAW_CANCEL_NB_LOAD;
              else if (rv_nb_waw_victim_is_div[lane])
                nb_cancel_kind[hart][rd] = WAW_CANCEL_NB_DIV;
            end
        end
    end

    always_comb begin
      for (integer hart = 0; hart < 2; hart = hart + 1) begin
        pick_mask[hart][0] = 32'b0;
        for (integer rd = 1; rd < 32; rd = rd + 1)
          pick_mask[hart][0][rd] = emit_valid[hart][rd];
        for (integer slot = 0; slot < 4; slot = slot + 1) begin
          pick_valid[hart][slot] = |pick_mask[hart][slot];
          pick_onehot[hart][slot] = pick_mask[hart][slot] &
                                    (~pick_mask[hart][slot] + 1'b1);
          pick_mask[hart][slot+1] = pick_mask[hart][slot] &
                                    ~pick_onehot[hart][slot];
          pick_rd[hart][slot] = 5'b0;
          pick_struct[hart][slot] = '0;
          for (integer rd = 1; rd < 32; rd = rd + 1)
            if (pick_onehot[hart][slot][rd]) begin
              pick_rd[hart][slot] = rd[4:0];
              pick_struct[hart][slot] = emit_struct[hart][rd];
            end
        end
      end
    end

    // Direct commits have priority because they cannot backpressure EH2.
    // Buffered nonblocking completions remain pending if four slots are used.
    always_comb begin
      candidate_valid = '0;
      candidate_struct = '0;
      candidate_is_emit = '0;
      candidate_emit_rd = '0;
      for (integer hart = 0; hart < 2; hart = hart + 1) begin
        integer out_slot;
        out_slot = 0;
        for (integer lane = 0; lane < 2; lane = lane + 1)
          if (direct_valid[lane] && (rv_commit_hart_id[lane] == hart)) begin
            candidate_valid[hart][out_slot] = 1'b1;
            candidate_struct[hart][out_slot] = lane_struct[lane];
            out_slot = out_slot + 1;
          end
        for (integer pick = 0; pick < 4; pick = pick + 1)
          if (pick_valid[hart][pick] && (out_slot < 4)) begin
            candidate_valid[hart][out_slot] = 1'b1;
            candidate_struct[hart][out_slot] = pick_struct[hart][pick];
            candidate_is_emit[hart][out_slot] = 1'b1;
            candidate_emit_rd[hart][out_slot] = pick_rd[hart][pick];
            out_slot = out_slot + 1;
          end
      end
    end

    always_comb begin
      record_valid = candidate_valid;
      record_data = '0;
      candidate_accept = candidate_valid & record_ready;
      accepted_count = '0;
      for (integer hart = 0; hart < 2; hart = hart + 1) begin
        for (integer rd = 0; rd < 32; rd = rd + 1)
          emit_selected[hart][rd] = 1'b0;
        for (integer slot = 0; slot < 4; slot = slot + 1) begin
          record_data[hart][slot] = {candidate_struct[hart][slot], 64'b0};
          if (candidate_accept[hart][slot]) begin
            accepted_count[hart] = accepted_count[hart] + 1'b1;
            if (candidate_is_emit[hart][slot])
              emit_selected[hart][candidate_emit_rd[hart][slot]] = 1'b1;
          end
        end
      end
    end

    always_comb begin
      alloc_accept = '0;
      alloc_atomic = '0;
      for (integer hart = 0; hart < 2; hart = hart + 1)
        for (integer rd = 0; rd < 32; rd = rd + 1) begin
          nb_atomic[hart][rd] = 1'b0;
          nb_atomic_struct[hart][rd] = nb_struct[hart][rd];
        end

      for (integer lane = 0; lane < 2; lane = lane + 1)
        if (alloc_request[lane]) begin
          logic hart;
          logic [4:0] rd;
          logic old_return_match;
          logic [31:0] old_return_data;
          logic emit_slot_ready;
          hart = rv_commit_hart_id[lane];
          rd = rv_commit_gpr_rd[lane];
          old_return_match =
            (nb_is_load[hart][rd] && rv_nb_load_gpr_wen &&
             (rv_nb_load_gpr_hart_id == hart) &&
             (rv_nb_load_gpr_rd == rd)) ||
            (!nb_is_load[hart][rd] && rv_nb_div_gpr_wen &&
             (rv_nb_div_gpr_hart_id == hart) &&
             (rv_nb_div_gpr_rd == rd));
          old_return_data = nb_is_load[hart][rd] ?
                            rv_nb_load_gpr_wdata : rv_nb_div_gpr_wdata;
          emit_slot_ready = !emit_valid[hart][rd] ||
                            emit_selected[hart][rd];

          // A single per-rd owner is sufficient only if its old instruction
          // can be retired atomically when a younger deferred writer takes
          // the same rd.  Besides the original WAW-cancel case, the old entry
          // may already be resolved or may return in this exact cycle.  In
          // all three cases move the complete old record to emit_struct and
          // give nb_struct to the younger instruction without a false
          // nonblock-overflow report.
          alloc_atomic[lane] = nb_valid[hart][rd] &&
                               emit_slot_ready &&
                               (nb_cancel_match[hart][rd] ||
                                nb_resolved[hart][rd] ||
                                old_return_match);
          alloc_accept[lane] = !nb_valid[hart][rd] || alloc_atomic[lane];
          if ((lane == 1) && alloc_accept[0] &&
              (rv_commit_hart_id[0] == rv_commit_hart_id[1]) &&
              (rv_commit_gpr_rd[0] == rv_commit_gpr_rd[1])) begin
            alloc_accept[lane] = 1'b0;
            alloc_atomic[lane] = 1'b0;
          end
          if (alloc_accept[lane] && alloc_atomic[lane]) begin
            nb_atomic[hart][rd] = 1'b1;
            if (nb_cancel_match[hart][rd]) begin
              nb_atomic_struct[hart][rd] = cancel_struct(
                nb_struct[hart][rd], nb_cancel_kind[hart][rd],
                nb_cancel_number[hart][rd]);
            end else if (!nb_resolved[hart][rd] && old_return_match) begin
              nb_atomic_struct[hart][rd] = nb_struct[hart][rd];
              nb_atomic_struct[hart][rd][63:32] = old_return_data;
            end
          end
        end
    end

    always_comb begin
      for (integer hart = 0; hart < 2; hart = hart + 1) begin
        pending_nonblock_count[hart] = 6'b0;
        for (integer rd = 1; rd < 32; rd = rd + 1)
          if (nb_valid[hart][rd])
            pending_nonblock_count[hart] =
              pending_nonblock_count[hart] + 1'b1;
      end
    end

    always_comb begin
      capture_done = &stopped;
      for (integer hart = 0; hart < 2; hart = hart + 1)
        for (integer rd = 1; rd < 32; rd = rd + 1)
          if (nb_valid[hart][rd] || emit_valid[hart][rd])
            capture_done = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_l) begin
      if (!rst_l) begin
        marker_addr_pending <= 1'b0;
        marker_data_pending <= 1'b0;
        marker_addr_hart <= 1'b0;
        stopped <= 2'b00;
        next_sequence <= '0;
        commit_count <= '0;
        generated_count <= '0;
        nonblock_conflict_hart <= 2'b00;
        record_overflow_hart <= 2'b00;
        waw_cause_error_hart <= 2'b00;
        for (integer hart = 0; hart < 2; hart = hart + 1)
          for (integer rd = 0; rd < 32; rd = rd + 1) begin
            nb_struct[hart][rd] <= '0;
            nb_valid[hart][rd] <= 1'b0;
            nb_resolved[hart][rd] <= 1'b0;
            nb_is_load[hart][rd] <= 1'b0;
            emit_struct[hart][rd] <= '0;
            emit_valid[hart][rd] <= 1'b0;
          end
      end else begin
        if (marker_store_event) begin
          marker_addr_pending <= 1'b0;
          marker_data_pending <= 1'b0;
        end else begin
          if (marker_addr_hs) begin
            marker_addr_pending <= 1'b1;
            marker_addr_hart <= lsu_axi_awid[LSU_TAG_WIDTH-1];
          end
          if (marker_data_hs)
            marker_data_pending <= 1'b1;
        end

        stopped <= stopped_next;
        next_sequence <= sequence_work;
        for (integer hart = 0; hart < 2; hart = hart + 1) begin
          commit_count[hart] <= commit_count[hart] +
            ((process_valid[0] && rv_commit_hart_id[0] == hart) ? 1 : 0) +
            ((process_valid[1] && rv_commit_hart_id[1] == hart) ? 1 : 0);
          generated_count[hart] <= generated_count[hart] +
                                   accepted_count[hart];
          for (integer slot = 0; slot < 4; slot = slot + 1)
            if (candidate_valid[hart][slot] &&
                !candidate_is_emit[hart][slot] &&
                !candidate_accept[hart][slot])
              record_overflow_hart[hart] <= 1'b1;
        end

        for (integer lane = 0; lane < 2; lane = lane + 1) begin
          if (alloc_request[lane] && !alloc_accept[lane])
            nonblock_conflict_hart[rv_commit_hart_id[lane]] <= 1'b1;
          if (rv_commit_waw_victim[lane] &&
              (!(lane == 0 && process_valid[1] &&
                 (rv_commit_hart_id[0] == rv_commit_hart_id[1]) &&
                 (rv_commit_gpr_rd[0] == rv_commit_gpr_rd[1]))))
            waw_cause_error_hart[rv_commit_hart_id[lane]] <= 1'b1;
          if (rv_nb_waw_valid[lane] &&
              ((!rv_nb_waw_victim_is_load[lane] &&
                !rv_nb_waw_victim_is_div[lane]) ||
               !nb_valid[rv_nb_waw_victim_hart_id[lane]]
                        [rv_nb_waw_victim_gpr_rd[lane]]))
            waw_cause_error_hart[rv_nb_waw_victim_hart_id[lane]] <= 1'b1;
        end

        for (integer hart = 0; hart < 2; hart = hart + 1)
          for (integer rd = 1; rd < 32; rd = rd + 1) begin
            if (emit_selected[hart][rd])
              emit_valid[hart][rd] <= 1'b0;

            if (nb_atomic[hart][rd]) begin
              emit_struct[hart][rd] <= nb_atomic_struct[hart][rd];
              emit_valid[hart][rd] <= 1'b1;
            end else if (nb_valid[hart][rd] &&
                         nb_cancel_match[hart][rd]) begin
              // Cancellation can arrive after the result has already made
              // nb_resolved true but before that record is emitted.  Update
              // the holding record first and preserve the established
              // one-cycle resolved-to-emit latency used by the original
              // capture interface.
              nb_struct[hart][rd] <= cancel_struct(
                nb_struct[hart][rd], nb_cancel_kind[hart][rd],
                nb_cancel_number[hart][rd]);
              nb_resolved[hart][rd] <= 1'b1;
            end else if (nb_valid[hart][rd] && nb_resolved[hart][rd] &&
                         (!emit_valid[hart][rd] ||
                          emit_selected[hart][rd])) begin
              emit_struct[hart][rd] <= nb_struct[hart][rd];
              emit_valid[hart][rd] <= 1'b1;
              nb_valid[hart][rd] <= 1'b0;
              nb_resolved[hart][rd] <= 1'b0;
            end

            if (nb_valid[hart][rd] && !nb_resolved[hart][rd] &&
                !nb_atomic[hart][rd]) begin
              if (nb_cancel_match[hart][rd]) begin
                nb_struct[hart][rd] <= cancel_struct(
                  nb_struct[hart][rd], nb_cancel_kind[hart][rd],
                  nb_cancel_number[hart][rd]);
                nb_resolved[hart][rd] <= 1'b1;
              end else if (rv_nb_load_gpr_wen &&
                           (rv_nb_load_gpr_hart_id == hart) &&
                           (rv_nb_load_gpr_rd == rd)) begin
                nb_struct[hart][rd][63:32] <= rv_nb_load_gpr_wdata;
                nb_resolved[hart][rd] <= 1'b1;
              end else if (rv_nb_div_gpr_wen &&
                           (rv_nb_div_gpr_hart_id == hart) &&
                           (rv_nb_div_gpr_rd == rd)) begin
                nb_struct[hart][rd][63:32] <= rv_nb_div_gpr_wdata;
                nb_resolved[hart][rd] <= 1'b1;
              end
            end
          end

        for (integer lane = 0; lane < 2; lane = lane + 1)
          if (alloc_accept[lane]) begin
            nb_struct[rv_commit_hart_id[lane]]
                     [rv_commit_gpr_rd[lane]] <= lane_struct[lane];
            nb_valid[rv_commit_hart_id[lane]]
                    [rv_commit_gpr_rd[lane]] <= 1'b1;
            nb_resolved[rv_commit_hart_id[lane]]
                       [rv_commit_gpr_rd[lane]] <= 1'b0;
            nb_is_load[rv_commit_hart_id[lane]]
                      [rv_commit_gpr_rd[lane]] <=
                        rv_commit_is_nonblock_load[lane];
          end
      end
    end
endmodule
