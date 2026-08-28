// SPDX-License-Identifier: Apache-2.0

// One physical instruction-information bank per EH2 Hart. Keeping all
// nonblocking ownership, completion, WAW cancellation and emit state local to
// a bank prevents the two large state arrays from being merged across SLRs.
(* KEEP_HIERARCHY = "yes" *)
module instr_info_capture_hart_bank #(
    parameter logic HART_ID = 1'b0
) (
    input  logic                         clk,
    input  logic                         rst_l,
    input  logic [1:0]                   process_valid,
    input  logic [1:0][31:0]             lane_sequence,
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

    output logic [3:0]                   record_valid,
    output logic [3:0][255:0]            record_data,
    input  logic [3:0]                   record_ready,
    output logic [2:0]                   accepted_count,
    output logic [5:0]                   pending_nonblock_count,
    output logic                         idle,
    output logic                         nonblock_conflict,
    output logic                         record_overflow,
    output logic                         waw_cause_error
);
    import info_struct_pkg::*;

    localparam logic [1:0] EVENT_GPR = 2'd1;
    localparam logic [1:0] EVENT_CSR = 2'd2;

    logic [1:0][1:0] lane_event;
    logic [1:0][11:0] lane_register;
    logic [1:0][31:0] lane_result;
    logic [1:0][1:0] lane_waw_kind;
    logic [1:0][31:0] lane_cancel_number;
    logic [1:0][191:0] lane_struct;
    logic [1:0] same_cycle_nb_return;
    logic [1:0][31:0] same_cycle_nb_data;
    logic [1:0] alloc_request;
    logic [1:0] alloc_accept;
    logic [1:0] alloc_atomic;
    logic [1:0] direct_valid;

    logic [191:0] nb_struct [0:31];
    logic         nb_valid [0:31];
    logic         nb_resolved [0:31];
    logic         nb_is_load [0:31];
    logic [191:0] emit_struct [0:31];
    logic         emit_valid [0:31];
    logic         emit_selected [0:31];
    logic         nb_cancel_match [0:31];
    logic [1:0]   nb_cancel_kind [0:31];
    logic [31:0]  nb_cancel_number [0:31];
    logic         nb_atomic [0:31];
    logic [191:0] nb_atomic_struct [0:31];

    logic [31:0] pick_mask [0:4];
    logic [31:0] pick_onehot [0:3];
    logic        pick_valid [0:3];
    logic [4:0]  pick_rd [0:3];
    logic [191:0] pick_struct [0:3];
    logic [3:0] candidate_valid;
    logic [3:0][191:0] candidate_struct;
    logic [3:0] candidate_is_emit;
    logic [3:0][4:0] candidate_emit_rd;
    logic [3:0] candidate_accept;

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

    always_comb begin
      lane_event = '0;
      lane_register = '0;
      lane_result = '0;
      lane_waw_kind = '0;
      lane_cancel_number = '0;
      lane_struct = '0;
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
        alloc_request[lane] = process_valid[lane] &&
          (rv_commit_hart_id[lane] == HART_ID) &&
          rv_commit_is_nonblock[lane] &&
          rv_commit_gpr_wen_intent[lane] &&
          (rv_commit_gpr_rd[lane] != 0) &&
          !rv_commit_waw_victim[lane] &&
          !same_cycle_nb_return[lane];
        direct_valid[lane] = process_valid[lane] &&
          (rv_commit_hart_id[lane] == HART_ID) &&
          !alloc_request[lane];
      end
    end

    always_comb begin
      for (integer rd = 0; rd < 32; rd = rd + 1) begin
        nb_cancel_match[rd] = 1'b0;
        nb_cancel_kind[rd] = WAW_CANCEL_NONE;
        nb_cancel_number[rd] = 32'b0;
        for (integer lane = 0; lane < 2; lane = lane + 1)
          if (rv_nb_waw_valid[lane] &&
              (rv_nb_waw_victim_hart_id[lane] == HART_ID) &&
              (rv_nb_waw_victim_gpr_rd[lane] == rd)) begin
            nb_cancel_match[rd] = 1'b1;
            nb_cancel_number[rd] = lane_sequence[lane];
            if (rv_nb_waw_victim_is_load[lane])
              nb_cancel_kind[rd] = WAW_CANCEL_NB_LOAD;
            else if (rv_nb_waw_victim_is_div[lane])
              nb_cancel_kind[rd] = WAW_CANCEL_NB_DIV;
          end
      end
    end

    always_comb begin
      pick_mask[0] = 32'b0;
      for (integer rd = 1; rd < 32; rd = rd + 1)
        pick_mask[0][rd] = emit_valid[rd];
      for (integer slot = 0; slot < 4; slot = slot + 1) begin
        pick_valid[slot] = |pick_mask[slot];
        pick_onehot[slot] = pick_mask[slot] &
                            (~pick_mask[slot] + 1'b1);
        pick_mask[slot+1] = pick_mask[slot] & ~pick_onehot[slot];
        pick_rd[slot] = 5'b0;
        pick_struct[slot] = '0;
        for (integer rd = 1; rd < 32; rd = rd + 1)
          if (pick_onehot[slot][rd]) begin
            pick_rd[slot] = rd[4:0];
            pick_struct[slot] = emit_struct[rd];
          end
      end
    end

    always_comb begin
      integer out_slot;
      candidate_valid = '0;
      candidate_struct = '0;
      candidate_is_emit = '0;
      candidate_emit_rd = '0;
      out_slot = 0;
      for (integer lane = 0; lane < 2; lane = lane + 1)
        if (direct_valid[lane]) begin
          candidate_valid[out_slot] = 1'b1;
          candidate_struct[out_slot] = lane_struct[lane];
          out_slot = out_slot + 1;
        end
      for (integer pick = 0; pick < 4; pick = pick + 1)
        if (pick_valid[pick] && (out_slot < 4)) begin
          candidate_valid[out_slot] = 1'b1;
          candidate_struct[out_slot] = pick_struct[pick];
          candidate_is_emit[out_slot] = 1'b1;
          candidate_emit_rd[out_slot] = pick_rd[pick];
          out_slot = out_slot + 1;
        end
    end

    always_comb begin
      record_valid = candidate_valid;
      record_data = '0;
      candidate_accept = candidate_valid & record_ready;
      accepted_count = '0;
      for (integer rd = 0; rd < 32; rd = rd + 1)
        emit_selected[rd] = 1'b0;
      for (integer slot = 0; slot < 4; slot = slot + 1) begin
        record_data[slot] = {candidate_struct[slot], 64'b0};
        if (candidate_accept[slot]) begin
          accepted_count = accepted_count + 1'b1;
          if (candidate_is_emit[slot])
            emit_selected[candidate_emit_rd[slot]] = 1'b1;
        end
      end
    end

    always_comb begin
      alloc_accept = '0;
      alloc_atomic = '0;
      for (integer rd = 0; rd < 32; rd = rd + 1) begin
        nb_atomic[rd] = 1'b0;
        nb_atomic_struct[rd] = nb_struct[rd];
      end

      for (integer lane = 0; lane < 2; lane = lane + 1)
        if (alloc_request[lane]) begin
          logic [4:0] rd;
          logic old_return_match;
          logic [31:0] old_return_data;
          logic emit_slot_ready;
          rd = rv_commit_gpr_rd[lane];
          old_return_match =
            (nb_is_load[rd] && rv_nb_load_gpr_wen &&
             (rv_nb_load_gpr_hart_id == HART_ID) &&
             (rv_nb_load_gpr_rd == rd)) ||
            (!nb_is_load[rd] && rv_nb_div_gpr_wen &&
             (rv_nb_div_gpr_hart_id == HART_ID) &&
             (rv_nb_div_gpr_rd == rd));
          old_return_data = nb_is_load[rd] ?
                            rv_nb_load_gpr_wdata : rv_nb_div_gpr_wdata;
          emit_slot_ready = !emit_valid[rd] || emit_selected[rd];
          alloc_atomic[lane] = nb_valid[rd] && emit_slot_ready &&
                               (nb_cancel_match[rd] ||
                                nb_resolved[rd] ||
                                old_return_match);
          alloc_accept[lane] = !nb_valid[rd] || alloc_atomic[lane];
          if ((lane == 1) && alloc_accept[0] &&
              (rv_commit_hart_id[0] == rv_commit_hart_id[1]) &&
              (rv_commit_gpr_rd[0] == rv_commit_gpr_rd[1])) begin
            alloc_accept[lane] = 1'b0;
            alloc_atomic[lane] = 1'b0;
          end
          if (alloc_accept[lane] && alloc_atomic[lane]) begin
            nb_atomic[rd] = 1'b1;
            if (nb_cancel_match[rd]) begin
              nb_atomic_struct[rd] = cancel_struct(
                nb_struct[rd], nb_cancel_kind[rd],
                nb_cancel_number[rd]);
            end else if (!nb_resolved[rd] && old_return_match) begin
              nb_atomic_struct[rd] = nb_struct[rd];
              nb_atomic_struct[rd][63:32] = old_return_data;
            end
          end
        end
    end

    always_comb begin
      pending_nonblock_count = 6'b0;
      idle = 1'b1;
      for (integer rd = 1; rd < 32; rd = rd + 1) begin
        if (nb_valid[rd])
          pending_nonblock_count = pending_nonblock_count + 1'b1;
        if (nb_valid[rd] || emit_valid[rd])
          idle = 1'b0;
      end
    end

    always_ff @(posedge clk or negedge rst_l) begin
      if (!rst_l) begin
        nonblock_conflict <= 1'b0;
        record_overflow <= 1'b0;
        waw_cause_error <= 1'b0;
        for (integer rd = 0; rd < 32; rd = rd + 1) begin
          nb_struct[rd] <= '0;
          nb_valid[rd] <= 1'b0;
          nb_resolved[rd] <= 1'b0;
          nb_is_load[rd] <= 1'b0;
          emit_struct[rd] <= '0;
          emit_valid[rd] <= 1'b0;
        end
      end else begin
        for (integer slot = 0; slot < 4; slot = slot + 1)
          if (candidate_valid[slot] &&
              !candidate_is_emit[slot] &&
              !candidate_accept[slot])
            record_overflow <= 1'b1;

        for (integer lane = 0; lane < 2; lane = lane + 1) begin
          if (alloc_request[lane] && !alloc_accept[lane])
            nonblock_conflict <= 1'b1;
          if (rv_commit_waw_victim[lane] &&
              (rv_commit_hart_id[lane] == HART_ID) &&
              (!(lane == 0 && process_valid[1] &&
                 (rv_commit_hart_id[0] == rv_commit_hart_id[1]) &&
                 (rv_commit_gpr_rd[0] == rv_commit_gpr_rd[1]))))
            waw_cause_error <= 1'b1;
          if (rv_nb_waw_valid[lane] &&
              (rv_nb_waw_victim_hart_id[lane] == HART_ID) &&
              ((!rv_nb_waw_victim_is_load[lane] &&
                !rv_nb_waw_victim_is_div[lane]) ||
               !nb_valid[rv_nb_waw_victim_gpr_rd[lane]]))
            waw_cause_error <= 1'b1;
        end

        for (integer rd = 1; rd < 32; rd = rd + 1) begin
          if (emit_selected[rd])
            emit_valid[rd] <= 1'b0;

          if (nb_atomic[rd]) begin
            emit_struct[rd] <= nb_atomic_struct[rd];
            emit_valid[rd] <= 1'b1;
          end else if (nb_valid[rd] && nb_cancel_match[rd]) begin
            nb_struct[rd] <= cancel_struct(
              nb_struct[rd], nb_cancel_kind[rd],
              nb_cancel_number[rd]);
            nb_resolved[rd] <= 1'b1;
          end else if (nb_valid[rd] && nb_resolved[rd] &&
                       (!emit_valid[rd] || emit_selected[rd])) begin
            emit_struct[rd] <= nb_struct[rd];
            emit_valid[rd] <= 1'b1;
            nb_valid[rd] <= 1'b0;
            nb_resolved[rd] <= 1'b0;
          end

          if (nb_valid[rd] && !nb_resolved[rd] &&
              !nb_atomic[rd]) begin
            if (nb_cancel_match[rd]) begin
              nb_struct[rd] <= cancel_struct(
                nb_struct[rd], nb_cancel_kind[rd],
                nb_cancel_number[rd]);
              nb_resolved[rd] <= 1'b1;
            end else if (rv_nb_load_gpr_wen &&
                         (rv_nb_load_gpr_hart_id == HART_ID) &&
                         (rv_nb_load_gpr_rd == rd)) begin
              nb_struct[rd][63:32] <= rv_nb_load_gpr_wdata;
              nb_resolved[rd] <= 1'b1;
            end else if (rv_nb_div_gpr_wen &&
                         (rv_nb_div_gpr_hart_id == HART_ID) &&
                         (rv_nb_div_gpr_rd == rd)) begin
              nb_struct[rd][63:32] <= rv_nb_div_gpr_wdata;
              nb_resolved[rd] <= 1'b1;
            end
          end
        end

        for (integer lane = 0; lane < 2; lane = lane + 1)
          if (alloc_accept[lane]) begin
            nb_struct[rv_commit_gpr_rd[lane]] <= lane_struct[lane];
            nb_valid[rv_commit_gpr_rd[lane]] <= 1'b1;
            nb_resolved[rv_commit_gpr_rd[lane]] <= 1'b0;
            nb_is_load[rv_commit_gpr_rd[lane]] <=
              rv_commit_is_nonblock_load[lane];
          end
      end
    end
endmodule
