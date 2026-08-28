// SPDX-License-Identifier: Apache-2.0

// Production dual-Hart wrapper.  Global stop-marker pairing and per-Hart
// sequence accounting remain centralized, while all wide instruction-record
// state is contained by one physical bank per Hart.
module instr_info_capture_dual #(
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
    localparam logic [31:0] STOP_ADDR = 32'hD058_0000;
    localparam logic [31:0] STOP_DATA = 32'h0032_0525;

    logic marker_addr_pending;
    logic marker_data_pending;
    logic marker_addr_hart;
    logic marker_addr_hs;
    logic marker_data_hs;
    logic marker_store_event;
    logic marker_store_hart;
    logic [1:0] stopped_next;
    logic [1:0] process_valid;
    logic [1:0][31:0] lane_sequence;
    logic [1:0][31:0] sequence_work;

    logic [1:0][3:0] bank_record_valid;
    logic [1:0][3:0][255:0] bank_record_data;
    logic [1:0][2:0] bank_accepted_count;
    logic [1:0][5:0] bank_pending_count;
    logic [1:0] bank_idle;
    logic [1:0] bank_nonblock_conflict;
    logic [1:0] bank_record_overflow;
    logic [1:0] bank_waw_cause_error;

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

    (* KEEP_HIERARCHY = "yes" *)
    instr_info_capture_hart_bank #(.HART_ID(1'b0)) hart0_bank_i (
      .clk, .rst_l, .process_valid, .lane_sequence,
      .rv_commit_insn, .rv_commit_pc, .rv_commit_hart_id,
      .rv_commit_priv_mode, .rv_commit_gpr_wen_intent,
      .rv_commit_gpr_wen, .rv_commit_gpr_rd, .rv_commit_gpr_wdata,
      .rv_commit_csr_wen, .rv_commit_csr_addr, .rv_commit_csr_wdata,
      .rv_commit_is_nonblock, .rv_commit_is_nonblock_load,
      .rv_commit_is_nonblock_div, .rv_commit_waw_victim,
      .rv_nb_waw_valid, .rv_nb_waw_victim_hart_id,
      .rv_nb_waw_victim_gpr_rd, .rv_nb_waw_victim_is_load,
      .rv_nb_waw_victim_is_div,
      .rv_nb_load_gpr_wen, .rv_nb_load_gpr_hart_id,
      .rv_nb_load_gpr_rd, .rv_nb_load_gpr_wdata,
      .rv_nb_div_gpr_wen, .rv_nb_div_gpr_hart_id,
      .rv_nb_div_gpr_rd, .rv_nb_div_gpr_wdata,
      .record_valid(bank_record_valid[0]),
      .record_data(bank_record_data[0]),
      .record_ready(record_ready[0]),
      .accepted_count(bank_accepted_count[0]),
      .pending_nonblock_count(bank_pending_count[0]),
      .idle(bank_idle[0]),
      .nonblock_conflict(bank_nonblock_conflict[0]),
      .record_overflow(bank_record_overflow[0]),
      .waw_cause_error(bank_waw_cause_error[0])
    );

    (* KEEP_HIERARCHY = "yes" *)
    instr_info_capture_hart_bank #(.HART_ID(1'b1)) hart1_bank_i (
      .clk, .rst_l, .process_valid, .lane_sequence,
      .rv_commit_insn, .rv_commit_pc, .rv_commit_hart_id,
      .rv_commit_priv_mode, .rv_commit_gpr_wen_intent,
      .rv_commit_gpr_wen, .rv_commit_gpr_rd, .rv_commit_gpr_wdata,
      .rv_commit_csr_wen, .rv_commit_csr_addr, .rv_commit_csr_wdata,
      .rv_commit_is_nonblock, .rv_commit_is_nonblock_load,
      .rv_commit_is_nonblock_div, .rv_commit_waw_victim,
      .rv_nb_waw_valid, .rv_nb_waw_victim_hart_id,
      .rv_nb_waw_victim_gpr_rd, .rv_nb_waw_victim_is_load,
      .rv_nb_waw_victim_is_div,
      .rv_nb_load_gpr_wen, .rv_nb_load_gpr_hart_id,
      .rv_nb_load_gpr_rd, .rv_nb_load_gpr_wdata,
      .rv_nb_div_gpr_wen, .rv_nb_div_gpr_hart_id,
      .rv_nb_div_gpr_rd, .rv_nb_div_gpr_wdata,
      .record_valid(bank_record_valid[1]),
      .record_data(bank_record_data[1]),
      .record_ready(record_ready[1]),
      .accepted_count(bank_accepted_count[1]),
      .pending_nonblock_count(bank_pending_count[1]),
      .idle(bank_idle[1]),
      .nonblock_conflict(bank_nonblock_conflict[1]),
      .record_overflow(bank_record_overflow[1]),
      .waw_cause_error(bank_waw_cause_error[1])
    );

    always_comb begin
      record_valid = bank_record_valid;
      record_data = bank_record_data;
      pending_nonblock_count = bank_pending_count;
      nonblock_conflict_hart = bank_nonblock_conflict;
      record_overflow_hart = bank_record_overflow;
      waw_cause_error_hart = bank_waw_cause_error;
      capture_done = (&stopped) && (&bank_idle);
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
                                   bank_accepted_count[hart];
        end
      end
    end
endmodule
