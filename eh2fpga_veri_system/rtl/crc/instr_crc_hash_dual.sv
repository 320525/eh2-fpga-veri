// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module instr_crc_hash_dual #(
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

    input  logic [1:0][1:0][7:0]        fifo_free_count,
    input  logic [1:0][1:0]             fifo_bank_release,
    output logic [1:0][1:0][3:0]        fifo_wr_valid,
    output logic [1:0][1:0][3:0][128:0] fifo_wr_data,
    output logic [1:0][1:0][15:0]       fifo_bank_package,
    output logic [1:0][1:0]             fifo_bank_busy,

    output logic                         buffer_conflict,
    output logic                         fifo_overflow,
    output logic                         bank_conflict,
    output logic [1:0]                   buffer_conflict_hart,
    output logic [1:0]                   fifo_overflow_hart,
    output logic [1:0]                   bank_conflict_hart,
    output logic [3:0]                   waw_cancel_valid,
    output logic [3:0]                   waw_cancel_hart,
    output logic [3:0][15:0]             waw_cancel_package,
    output logic [3:0][15:0]             waw_cancel_sequence,
    output logic [1:0]                   stopped,
    output logic [1:0][15:0]            sequence_number,
    output logic [1:0][15:0]            package_number,
    output logic [1:0][31:0]            commit_count,
    output logic [1:0][31:0]            generated_count,
    output logic [1:0][5:0]             pending_nonblock_count
);
    localparam logic [1:0] EVENT_NONE = 2'd0;
    localparam logic [1:0] EVENT_GPR  = 2'd1;
    localparam logic [1:0] EVENT_CSR  = 2'd2;
    localparam logic [31:0] STOP_ADDR = 32'hD058_0000;
    localparam logic [31:0] STOP_DATA = 32'h0032_0525;

    logic marker_addr_pending;
    logic marker_data_pending;
    logic marker_addr_hart;
    logic marker_addr_hs;
    logic marker_data_hs;
    logic marker_store_event;
    logic marker_store_hart;

    logic [1:0] process_valid;
    logic [1:0][15:0] lane_sequence;
    logic [1:0][15:0] lane_package;
    logic [1:0][15:0] sequence_next;
    logic [1:0][15:0] package_next;
    logic [1:0][15:0] sequence_work;
    logic [1:0][15:0] package_work;

    logic [1:0][1:0] lane_event_type;
    logic [1:0][11:0] lane_reg_num;
    logic [1:0][31:0] lane_data;
    logic [1:0][159:0] lane_struct;
    logic [1:0][63:0] lane_c0;
    logic [1:0][63:0] lane_c1;
    logic [1:0] alloc_request;
    logic [1:0] alloc_accept;
    logic [1:0] same_cycle_nb_return;
    logic [1:0][31:0] same_cycle_nb_data;
    logic [1:0] direct_valid;

    logic [159:0] nb_struct [0:1][0:31];
    logic         nb_valid [0:1][0:31];
    logic         nb_resolved [0:1][0:31];
    logic [63:0]  nb_c0_wire [0:1][0:31];
    logic [63:0]  nb_c1_wire [0:1][0:31];
    logic [127:0] nb_crc_buffer [0:1][0:31];
    logic [15:0]  nb_crc_package [0:1][0:31];
    logic         nb_crc_valid [0:1][0:31];
    logic         nb_cancel_match [0:1][0:31];
    logic         nb_selected [0:1][0:31];

    logic [1:0][3:0] candidate_valid;
    logic [1:0][3:0][127:0] candidate_pair;
    logic [1:0][3:0][15:0] candidate_package;
    logic [1:0][3:0] candidate_is_nb;
    logic [1:0][3:0][4:0] candidate_nb_rd;
    logic [1:0][3:0] candidate_accept;
    logic [31:0] nb_pick_mask [0:1][0:4];
    logic [31:0] nb_pick_onehot [0:1][0:3];
    logic         nb_pick_valid [0:1][0:3];
    logic [4:0]   nb_pick_rd [0:1][0:3];
    logic [127:0] nb_pick_pair [0:1][0:3];
    logic [15:0]  nb_pick_package [0:1][0:3];
    logic [1:0][3:0] candidate_overflow;
    logic [1:0][3:0] candidate_bank_conflict;

    logic [1:0][1:0] tail_valid;
    logic [1:0][1:0][127:0] tail_pair;
    logic [1:0][1:0][16:0] bank_commit_items;
    logic [1:0][1:0][16:0] bank_generated_items;
    logic [1:0][1:0] bank_closed;
    logic [1:0][1:0][1:0] bank_commit_increment;
    logic [1:0][1:0][15:0] bank_commit_package;
    logic [1:0][1:0] packet_tail_valid;
    logic [1:0][1:0][127:0] packet_tail_pair;
    logic [1:0][1:0][2:0] bank_candidate_count;
    logic [1:0][2:0] hart_candidate_count;
    logic [1:0][1:0] bank_close_emit;

    logic [1:0] stopped_next;
    logic conflict_event;
    logic overflow_event;
    logic bank_conflict_event;
    logic [1:0] conflict_hart_event;
    logic [1:0] overflow_hart_event;
    logic [1:0] bank_conflict_hart_event;

    // The monitor is aligned to EH2's WB commit. A matching load/div return in
    // this cycle forms a complete direct-CRC record; only later returns need a
    // nonblocking instruction-structure buffer.
    function automatic [159:0] make_instruction_struct (
        input logic [15:0] struct_package,
        input logic [15:0] struct_sequence,
        input logic [31:0] struct_pc,
        input logic [31:0] struct_instruction,
        input logic        struct_hart,
        input logic [1:0]  struct_priv,
        input logic [1:0]  struct_event,
        input logic [11:0] struct_reg_num,
        input logic [31:0] struct_data
    );
        logic [31:0] metadata;
        begin
            metadata = {15'b0, struct_hart, struct_priv,
                        struct_event, struct_reg_num};
            make_instruction_struct = {
                struct_package, struct_sequence,
                struct_pc, struct_instruction, metadata, struct_data
            };
        end
    endfunction

    assign marker_addr_hs = lsu_axi_awvalid & lsu_axi_awready &
                            (lsu_axi_awaddr == STOP_ADDR);
    assign marker_data_hs = lsu_axi_wvalid & lsu_axi_wready &
                            (&lsu_axi_wstrb[3:0]) &
                            (lsu_axi_wdata[31:0] == STOP_DATA);
    assign marker_store_event =
        (marker_addr_pending | marker_addr_hs) &
        (marker_data_pending | marker_data_hs);
    assign marker_store_hart = marker_addr_hs ?
        lsu_axi_awid[LSU_TAG_WIDTH-1] : marker_addr_hart;

    always_comb begin
        stopped_next = stopped;
        if (marker_store_event)
            stopped_next[marker_store_hart] = 1'b1;
        for (integer stop_lane = 0; stop_lane < 2; stop_lane = stop_lane + 1)
            process_valid[stop_lane] = rv_commit_valid[stop_lane] &
                ~stopped_next[rv_commit_hart_id[stop_lane]];
    end

    always_ff @(posedge clk or negedge rst_l) begin
        if (!rst_l) begin
            marker_addr_pending <= 1'b0;
            marker_data_pending <= 1'b0;
            marker_addr_hart <= 1'b0;
        end else if (marker_store_event) begin
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
    end

    // Per-hart sequence allocation, preserving i0 then i1 age order.
    always_comb begin
        sequence_work = sequence_number;
        package_work = package_number;
        lane_sequence = '0;
        lane_package = '0;
        for (integer seq_lane = 0; seq_lane < 2; seq_lane = seq_lane + 1) begin
            lane_sequence[seq_lane] = sequence_work[rv_commit_hart_id[seq_lane]];
            lane_package[seq_lane] = package_work[rv_commit_hart_id[seq_lane]];
            if (process_valid[seq_lane]) begin
                if (sequence_work[rv_commit_hart_id[seq_lane]] == 16'hffff) begin
                    sequence_work[rv_commit_hart_id[seq_lane]] = 16'h0000;
                    package_work[rv_commit_hart_id[seq_lane]] =
                        package_work[rv_commit_hart_id[seq_lane]] + 16'd1;
                end else begin
                    sequence_work[rv_commit_hart_id[seq_lane]] =
                        sequence_work[rv_commit_hart_id[seq_lane]] + 16'd1;
                end
            end
        end
        sequence_next = sequence_work;
        package_next = package_work;
    end

    always_comb begin
        lane_event_type = '0;
        lane_reg_num = '0;
        lane_data = '0;
        lane_struct = '0;
        alloc_request = '0;
        direct_valid = '0;
        same_cycle_nb_return = '0;
        same_cycle_nb_data = '0;
        for (integer struct_lane = 0; struct_lane < 2;
             struct_lane = struct_lane + 1) begin
            same_cycle_nb_return[struct_lane] =
                (rv_commit_is_nonblock_load[struct_lane] &&
                 rv_nb_load_gpr_wen &&
                 (rv_nb_load_gpr_hart_id == rv_commit_hart_id[struct_lane]) &&
                 (rv_nb_load_gpr_rd == rv_commit_gpr_rd[struct_lane])) ||
                (rv_commit_is_nonblock_div[struct_lane] &&
                 rv_nb_div_gpr_wen &&
                 (rv_nb_div_gpr_hart_id == rv_commit_hart_id[struct_lane]) &&
                 (rv_nb_div_gpr_rd == rv_commit_gpr_rd[struct_lane]));
            if (rv_commit_is_nonblock_load[struct_lane])
                same_cycle_nb_data[struct_lane] = rv_nb_load_gpr_wdata;
            else
                same_cycle_nb_data[struct_lane] = rv_nb_div_gpr_wdata;

            if (rv_commit_waw_victim[struct_lane] &&
                (rv_commit_gpr_rd[struct_lane] != 5'd0)) begin
                lane_event_type[struct_lane] = EVENT_GPR;
                lane_reg_num[struct_lane] = {7'b0, rv_commit_gpr_rd[struct_lane]};
                lane_data[struct_lane] = 32'b0;
            end else if (rv_commit_csr_wen[struct_lane]) begin
                lane_event_type[struct_lane] = EVENT_CSR;
                lane_reg_num[struct_lane] = rv_commit_csr_addr[struct_lane];
                lane_data[struct_lane] = rv_commit_csr_wdata[struct_lane];
            end else if (rv_commit_gpr_wen[struct_lane] &&
                         (rv_commit_gpr_rd[struct_lane] != 5'd0)) begin
                lane_event_type[struct_lane] = EVENT_GPR;
                lane_reg_num[struct_lane] = {7'b0, rv_commit_gpr_rd[struct_lane]};
                lane_data[struct_lane] = rv_commit_gpr_wdata[struct_lane];
            end else if (rv_commit_is_nonblock[struct_lane] &&
                         rv_commit_gpr_wen_intent[struct_lane] &&
                         (rv_commit_gpr_rd[struct_lane] != 5'd0)) begin
                lane_event_type[struct_lane] = EVENT_GPR;
                lane_reg_num[struct_lane] = {7'b0, rv_commit_gpr_rd[struct_lane]};
                lane_data[struct_lane] = same_cycle_nb_return[struct_lane] ?
                                         same_cycle_nb_data[struct_lane] : 32'b0;
            end

            lane_struct[struct_lane] = make_instruction_struct(
                lane_package[struct_lane], lane_sequence[struct_lane],
                rv_commit_pc[struct_lane], rv_commit_insn[struct_lane],
                rv_commit_hart_id[struct_lane], rv_commit_priv_mode[struct_lane],
                lane_event_type[struct_lane], lane_reg_num[struct_lane],
                lane_data[struct_lane]
            );

            alloc_request[struct_lane] = process_valid[struct_lane] &
                rv_commit_is_nonblock[struct_lane] &
                rv_commit_gpr_wen_intent[struct_lane] &
                (rv_commit_gpr_rd[struct_lane] != 5'd0) &
                ~rv_commit_waw_victim[struct_lane] &
                ~same_cycle_nb_return[struct_lane];
            direct_valid[struct_lane] = process_valid[struct_lane] &
                                        ~alloc_request[struct_lane];
        end
    end

    crc64_ecma_pair_160 direct_i0_crc (
        .data(lane_struct[0]), .c0(lane_c0[0]), .c1(lane_c1[0])
    );
    crc64_ecma_pair_160 direct_i1_crc (
        .data(lane_struct[1]), .c0(lane_c0[1]), .c1(lane_c1[1])
    );

    genvar gh;
    genvar gr;
    generate
        for (gh = 0; gh < 2; gh = gh + 1) begin : g_hart_crc
            for (gr = 1; gr <= 31; gr = gr + 1) begin : g_rd_crc
                crc64_ecma_pair_160 nb_crc_i (
                    .data(nb_struct[gh][gr]),
                    .c0  (nb_c0_wire[gh][gr]),
                    .c1  (nb_c1_wire[gh][gr])
                );
            end
        end
    endgenerate

    always_comb begin
        alloc_accept = '0;
        for (integer alloc_lane = 0; alloc_lane < 2;
             alloc_lane = alloc_lane + 1) begin
            if (alloc_request[alloc_lane]) begin
                alloc_accept[alloc_lane] =
                    ~nb_valid[rv_commit_hart_id[alloc_lane]]
                             [rv_commit_gpr_rd[alloc_lane]];
                if ((alloc_lane == 1) && alloc_accept[0] &&
                    (rv_commit_hart_id[0] == rv_commit_hart_id[1]) &&
                    (rv_commit_gpr_rd[0] == rv_commit_gpr_rd[1]))
                    alloc_accept[alloc_lane] = 1'b0;
            end
        end
        conflict_event = (alloc_request[0] & ~alloc_accept[0]) |
                         (alloc_request[1] & ~alloc_accept[1]);
        conflict_hart_event = 2'b0;
        for (integer conflict_lane = 0; conflict_lane < 2;
             conflict_lane = conflict_lane + 1)
            if (alloc_request[conflict_lane] && !alloc_accept[conflict_lane])
                conflict_hart_event[rv_commit_hart_id[conflict_lane]] = 1'b1;
    end

    always_comb begin
        for (integer cancel_hart = 0; cancel_hart < 2;
             cancel_hart = cancel_hart + 1) begin
            for (integer cancel_rd = 0; cancel_rd <= 31;
                 cancel_rd = cancel_rd + 1) begin
                nb_cancel_match[cancel_hart][cancel_rd] = 1'b0;
                for (integer cancel_lane_i = 0; cancel_lane_i < 2;
                     cancel_lane_i = cancel_lane_i + 1) begin
                    nb_cancel_match[cancel_hart][cancel_rd] |=
                        rv_nb_waw_valid[cancel_lane_i] &
                        (rv_nb_waw_victim_hart_id[cancel_lane_i] == cancel_hart) &
                        (rv_nb_waw_victim_gpr_rd[cancel_lane_i] == cancel_rd);
                end
            end
        end
    end

    // Export every instruction whose result is cancelled by WAW.  Slots 0/1
    // are the two commit lanes' same-cycle victims; these are already emitted
    // as direct zero-result structures above.  Slots 2/3 are older pending
    // nonblocking victims identified by EH2's two sideband lanes.  Keeping the
    // classes in four independent slots avoids losing an event if a direct
    // victim and one or two nonblocking victims occur in the same cycle.
    always_comb begin
        waw_cancel_valid    = 4'b0;
        waw_cancel_hart     = 4'b0;
        waw_cancel_package  = '0;
        waw_cancel_sequence = '0;
        for (integer direct_lane = 0; direct_lane < 2;
             direct_lane = direct_lane + 1) begin
            waw_cancel_hart[direct_lane] = rv_commit_hart_id[direct_lane];
            waw_cancel_valid[direct_lane] =
                process_valid[direct_lane] &
                rv_commit_waw_victim[direct_lane] &
                (rv_commit_gpr_rd[direct_lane] != 0);
            waw_cancel_package[direct_lane] = lane_package[direct_lane];
            waw_cancel_sequence[direct_lane] = lane_sequence[direct_lane];
        end
        for (integer waw_lane = 0; waw_lane < 2; waw_lane = waw_lane + 1) begin
            waw_cancel_hart[waw_lane+2] = rv_nb_waw_victim_hart_id[waw_lane];
            if ((rv_nb_waw_victim_gpr_rd[waw_lane] != 0) &&
                nb_valid[rv_nb_waw_victim_hart_id[waw_lane]]
                        [rv_nb_waw_victim_gpr_rd[waw_lane]] &&
                !nb_resolved[rv_nb_waw_victim_hart_id[waw_lane]]
                            [rv_nb_waw_victim_gpr_rd[waw_lane]]) begin
                waw_cancel_valid[waw_lane+2] = rv_nb_waw_valid[waw_lane];
                waw_cancel_package[waw_lane+2] =
                    nb_struct[rv_nb_waw_victim_hart_id[waw_lane]]
                             [rv_nb_waw_victim_gpr_rd[waw_lane]][159:144];
                waw_cancel_sequence[waw_lane+2] =
                    nb_struct[rv_nb_waw_victim_hart_id[waw_lane]]
                             [rv_nb_waw_victim_gpr_rd[waw_lane]][143:128];
            end
        end
        if (waw_cancel_valid[2] && waw_cancel_valid[3] &&
            (rv_nb_waw_victim_hart_id[0] == rv_nb_waw_victim_hart_id[1]) &&
            (rv_nb_waw_victim_gpr_rd[0] == rv_nb_waw_victim_gpr_rd[1]))
            waw_cancel_valid[3] = 1'b0;
    end

    // Find the first four ready nonblocking entries independently for each
    // hart. Isolating the lowest set bit with x & -x maps to a short carry
    // chain. Repeating it four times avoids the former 31-entry loop whose
    // general-purpose integer candidate_count synthesized into a 57-CARRY8
    // serial path.
    always_comb begin
        for (integer pick_hart = 0; pick_hart < 2;
             pick_hart = pick_hart + 1) begin
            nb_pick_mask[pick_hart][0] = 32'b0;
            for (integer ready_rd = 1; ready_rd <= 31;
                 ready_rd = ready_rd + 1)
                nb_pick_mask[pick_hart][0][ready_rd] =
                    nb_crc_valid[pick_hart][ready_rd];

            for (integer pick_slot = 0; pick_slot < 4;
                 pick_slot = pick_slot + 1) begin
                nb_pick_valid[pick_hart][pick_slot] =
                    |nb_pick_mask[pick_hart][pick_slot];
                nb_pick_onehot[pick_hart][pick_slot] =
                    nb_pick_mask[pick_hart][pick_slot] &
                    (~nb_pick_mask[pick_hart][pick_slot] + 32'd1);
                nb_pick_mask[pick_hart][pick_slot + 1] =
                    nb_pick_mask[pick_hart][pick_slot] &
                    ~nb_pick_onehot[pick_hart][pick_slot];

                nb_pick_rd[pick_hart][pick_slot] = 5'b0;
                nb_pick_pair[pick_hart][pick_slot] = 128'b0;
                nb_pick_package[pick_hart][pick_slot] = 16'b0;
                for (integer pick_rd_i = 1; pick_rd_i <= 31;
                     pick_rd_i = pick_rd_i + 1) begin
                    if (nb_pick_onehot[pick_hart][pick_slot][pick_rd_i]) begin
                        nb_pick_rd[pick_hart][pick_slot] = pick_rd_i[4:0];
                        nb_pick_pair[pick_hart][pick_slot] =
                            nb_crc_buffer[pick_hart][pick_rd_i];
                        nb_pick_package[pick_hart][pick_slot] =
                            nb_crc_package[pick_hart][pick_rd_i];
                    end
                end
            end
        end
    end

    // Collect at most four ready CRC pairs per hart. Direct commit lanes have
    // priority; the remaining fixed slots are filled by increasing rd.
    always_comb begin
        candidate_valid = '0;
        candidate_pair = '0;
        candidate_package = '0;
        candidate_is_nb = '0;
        candidate_nb_rd = '0;
        for (integer cand_hart = 0; cand_hart < 2;
             cand_hart = cand_hart + 1) begin
            for (integer cand_slot = 0; cand_slot < 4;
                 cand_slot = cand_slot + 1) begin
                candidate_valid[cand_hart][cand_slot] =
                    nb_pick_valid[cand_hart][cand_slot];
                candidate_pair[cand_hart][cand_slot] =
                    nb_pick_pair[cand_hart][cand_slot];
                candidate_package[cand_hart][cand_slot] =
                    nb_pick_package[cand_hart][cand_slot];
                candidate_is_nb[cand_hart][cand_slot] =
                    nb_pick_valid[cand_hart][cand_slot];
                candidate_nb_rd[cand_hart][cand_slot] =
                    nb_pick_rd[cand_hart][cand_slot];
            end

            if (direct_valid[0] &&
                (rv_commit_hart_id[0] == cand_hart) &&
                direct_valid[1] &&
                (rv_commit_hart_id[1] == cand_hart)) begin
                candidate_valid[cand_hart][0] = 1'b1;
                candidate_pair[cand_hart][0] = {lane_c1[0], lane_c0[0]};
                candidate_package[cand_hart][0] = lane_package[0];
                candidate_is_nb[cand_hart][0] = 1'b0;
                candidate_nb_rd[cand_hart][0] = 5'b0;

                candidate_valid[cand_hart][1] = 1'b1;
                candidate_pair[cand_hart][1] = {lane_c1[1], lane_c0[1]};
                candidate_package[cand_hart][1] = lane_package[1];
                candidate_is_nb[cand_hart][1] = 1'b0;
                candidate_nb_rd[cand_hart][1] = 5'b0;

                for (integer both_slot = 2; both_slot < 4;
                     both_slot = both_slot + 1) begin
                    candidate_valid[cand_hart][both_slot] =
                        nb_pick_valid[cand_hart][both_slot - 2];
                    candidate_pair[cand_hart][both_slot] =
                        nb_pick_pair[cand_hart][both_slot - 2];
                    candidate_package[cand_hart][both_slot] =
                        nb_pick_package[cand_hart][both_slot - 2];
                    candidate_is_nb[cand_hart][both_slot] =
                        nb_pick_valid[cand_hart][both_slot - 2];
                    candidate_nb_rd[cand_hart][both_slot] =
                        nb_pick_rd[cand_hart][both_slot - 2];
                end
            end else if ((direct_valid[0] &&
                          (rv_commit_hart_id[0] == cand_hart)) ||
                         (direct_valid[1] &&
                          (rv_commit_hart_id[1] == cand_hart))) begin
                logic selected_lane;
                selected_lane = !(direct_valid[0] &&
                                  (rv_commit_hart_id[0] == cand_hart));
                candidate_valid[cand_hart][0] = 1'b1;
                candidate_pair[cand_hart][0] =
                    {lane_c1[selected_lane], lane_c0[selected_lane]};
                candidate_package[cand_hart][0] =
                    lane_package[selected_lane];
                candidate_is_nb[cand_hart][0] = 1'b0;
                candidate_nb_rd[cand_hart][0] = 5'b0;

                for (integer one_slot = 1; one_slot < 4;
                     one_slot = one_slot + 1) begin
                    candidate_valid[cand_hart][one_slot] =
                        nb_pick_valid[cand_hart][one_slot - 1];
                    candidate_pair[cand_hart][one_slot] =
                        nb_pick_pair[cand_hart][one_slot - 1];
                    candidate_package[cand_hart][one_slot] =
                        nb_pick_package[cand_hart][one_slot - 1];
                    candidate_is_nb[cand_hart][one_slot] =
                        nb_pick_valid[cand_hart][one_slot - 1];
                    candidate_nb_rd[cand_hart][one_slot] =
                        nb_pick_rd[cand_hart][one_slot - 1];
                end
            end
        end
    end

    always_comb begin
        bank_commit_increment = '0;
        bank_commit_package = '0;
        for (integer commit_lane = 0; commit_lane < 2;
             commit_lane = commit_lane + 1) begin
            if (process_valid[commit_lane]) begin
                bank_commit_increment[rv_commit_hart_id[commit_lane]]
                    [lane_package[commit_lane][0]] =
                    bank_commit_increment[rv_commit_hart_id[commit_lane]]
                    [lane_package[commit_lane][0]] + 2'd1;
                bank_commit_package[rv_commit_hart_id[commit_lane]]
                    [lane_package[commit_lane][0]] = lane_package[commit_lane];
            end
        end
    end

    // A candidate can be retained in the per-bank tail if that ping-pong bank
    // belongs to the same package and has enough FIFO headroom. Requiring four
    // free entries keeps acceptance atomic for the maximum write batch.
    always_comb begin
        candidate_accept = '0;
        candidate_overflow = '0;
        candidate_bank_conflict = '0;
        overflow_hart_event = 2'b0;
        bank_conflict_hart_event = 2'b0;
        for (integer select_hart = 0; select_hart < 2;
             select_hart = select_hart + 1)
            for (integer select_rd = 0; select_rd <= 31;
                 select_rd = select_rd + 1)
                nb_selected[select_hart][select_rd] = 1'b0;
        for (integer accept_hart = 0; accept_hart < 2;
             accept_hart = accept_hart + 1) begin
            for (integer accept_slot = 0; accept_slot < 4;
                 accept_slot = accept_slot + 1) begin
                logic target_bank;
                if (candidate_valid[accept_hart][accept_slot]) begin
                    target_bank = candidate_package[accept_hart][accept_slot][0];
                    if ((!fifo_bank_busy[accept_hart][target_bank] ||
                         fifo_bank_release[accept_hart][target_bank] ||
                         (fifo_bank_package[accept_hart][target_bank] ==
                          candidate_package[accept_hart][accept_slot])) &&
                        (!bank_closed[accept_hart][target_bank] ||
                         fifo_bank_release[accept_hart][target_bank]) &&
                        (fifo_free_count[accept_hart][target_bank] >= 8'd4)) begin
                        candidate_accept[accept_hart][accept_slot] = 1'b1;
                        if (candidate_is_nb[accept_hart][accept_slot])
                            nb_selected[accept_hart]
                                [candidate_nb_rd[accept_hart][accept_slot]] = 1'b1;
                    end else begin
                        if (fifo_bank_busy[accept_hart][target_bank] &&
                            !fifo_bank_release[accept_hart][target_bank] &&
                            (fifo_bank_package[accept_hart][target_bank] !=
                             candidate_package[accept_hart][accept_slot]))
                            candidate_bank_conflict[accept_hart][accept_slot] =
                                1'b1;
                        else
                            candidate_overflow[accept_hart][accept_slot] = 1'b1;
                    end
                end
            end
            if (|candidate_overflow[accept_hart])
                overflow_hart_event[accept_hart] = 1'b1;
            if (|candidate_bank_conflict[accept_hart])
                bank_conflict_hart_event[accept_hart] = 1'b1;
        end
        for (integer conflict_hart = 0; conflict_hart < 2;
             conflict_hart = conflict_hart + 1)
            for (integer conflict_bank = 0; conflict_bank < 2;
                 conflict_bank = conflict_bank + 1)
                if ((bank_commit_increment[conflict_hart][conflict_bank] != 0) &&
                    fifo_bank_busy[conflict_hart][conflict_bank] &&
                    !fifo_bank_release[conflict_hart][conflict_bank] &&
                    (fifo_bank_package[conflict_hart][conflict_bank] !=
                     bank_commit_package[conflict_hart][conflict_bank]))
                    bank_conflict_hart_event[conflict_hart] = 1'b1;
        overflow_event = |candidate_overflow;
        bank_conflict_event = |bank_conflict_hart_event;
    end

    // Tail packetizer. One CRC pair per active package is deliberately held
    // outside the FIFO. On a full 65536-item package, or after the stop marker
    // and all older nonblocking results have arrived, the held pair is written
    // with last=1. Thus last is assigned by FIFO write count, not Sequence.
    always_comb begin
        fifo_wr_valid = '0;
        fifo_wr_data = '0;
        packet_tail_valid = tail_valid;
        packet_tail_pair = tail_pair;
        bank_candidate_count = '0;
        hart_candidate_count = '0;
        bank_close_emit = '0;
        for (integer packet_hart = 0; packet_hart < 2;
             packet_hart = packet_hart + 1) begin
            for (integer packet_bank = 0; packet_bank < 2;
                 packet_bank = packet_bank + 1) begin
                logic [2:0] output_slot;
                output_slot = 3'b0;
                for (integer packet_slot = 0; packet_slot < 4;
                     packet_slot = packet_slot + 1) begin
                    if (candidate_accept[packet_hart][packet_slot] &&
                        (candidate_package[packet_hart][packet_slot][0] ==
                         packet_bank)) begin
                        if (packet_tail_valid[packet_hart][packet_bank]) begin
                            fifo_wr_valid[packet_hart][packet_bank][output_slot] = 1'b1;
                            fifo_wr_data[packet_hart][packet_bank][output_slot] =
                                {1'b0, packet_tail_pair[packet_hart][packet_bank]};
                            output_slot = output_slot + 3'd1;
                        end
                        packet_tail_pair[packet_hart][packet_bank] =
                            candidate_pair[packet_hart][packet_slot];
                        packet_tail_valid[packet_hart][packet_bank] = 1'b1;
                        bank_candidate_count[packet_hart][packet_bank] =
                            bank_candidate_count[packet_hart][packet_bank] + 3'd1;
                        hart_candidate_count[packet_hart] =
                            hart_candidate_count[packet_hart] + 3'd1;
                    end
                end

                // Close only in a cycle without new candidates. This bounds
                // the write batch to four entries even at a package boundary.
                if ((bank_candidate_count[packet_hart][packet_bank] == 0) &&
                    tail_valid[packet_hart][packet_bank] &&
                    !bank_closed[packet_hart][packet_bank] &&
                    ((bank_generated_items[packet_hart][packet_bank] == 17'd65536) ||
                     (stopped[packet_hart] &&
                      (bank_generated_items[packet_hart][packet_bank] ==
                       bank_commit_items[packet_hart][packet_bank]) &&
                      (bank_commit_items[packet_hart][packet_bank] != 0))) &&
                    (fifo_free_count[packet_hart][packet_bank] != 0)) begin
                    fifo_wr_valid[packet_hart][packet_bank][0] = 1'b1;
                    fifo_wr_data[packet_hart][packet_bank][0] =
                        {1'b1, tail_pair[packet_hart][packet_bank]};
                    packet_tail_valid[packet_hart][packet_bank] = 1'b0;
                    bank_close_emit[packet_hart][packet_bank] = 1'b1;
                end
            end
        end
    end

    always_comb begin
        for (integer pending_hart = 0; pending_hart < 2;
             pending_hart = pending_hart + 1) begin
            pending_nonblock_count[pending_hart] = 6'b0;
            for (integer pending_rd = 1; pending_rd <= 31;
                 pending_rd = pending_rd + 1)
                if (nb_valid[pending_hart][pending_rd])
                    pending_nonblock_count[pending_hart] =
                        pending_nonblock_count[pending_hart] + 6'd1;
        end
    end

    always_ff @(posedge clk or negedge rst_l) begin
        if (!rst_l) begin
            stopped <= 2'b0;
            sequence_number <= '0;
            package_number <= '0;
            commit_count <= '0;
            generated_count <= '0;
            buffer_conflict <= 1'b0;
            fifo_overflow <= 1'b0;
            bank_conflict <= 1'b0;
            buffer_conflict_hart <= 2'b0;
            fifo_overflow_hart <= 2'b0;
            bank_conflict_hart <= 2'b0;
            fifo_bank_busy <= '0;
            fifo_bank_package <= '0;
            tail_valid <= '0;
            tail_pair <= '0;
            bank_commit_items <= '0;
            bank_generated_items <= '0;
            bank_closed <= '0;
            for (integer reset_hart = 0; reset_hart < 2;
                 reset_hart = reset_hart + 1) begin
                for (integer reset_rd = 0; reset_rd <= 31;
                     reset_rd = reset_rd + 1) begin
                    nb_struct[reset_hart][reset_rd] <= 160'b0;
                    nb_valid[reset_hart][reset_rd] <= 1'b0;
                    nb_resolved[reset_hart][reset_rd] <= 1'b0;
                    nb_crc_buffer[reset_hart][reset_rd] <= 128'b0;
                    nb_crc_package[reset_hart][reset_rd] <= 16'b0;
                    nb_crc_valid[reset_hart][reset_rd] <= 1'b0;
                end
            end
        end else begin
            stopped <= stopped_next;
            sequence_number <= sequence_next;
            package_number <= package_next;
            buffer_conflict <= conflict_event;
            fifo_overflow <= overflow_event;
            bank_conflict <= bank_conflict_event;
            buffer_conflict_hart <= conflict_hart_event;
            fifo_overflow_hart <= overflow_hart_event;
            bank_conflict_hart <= bank_conflict_hart_event;

            for (integer state_hart = 0; state_hart < 2;
                 state_hart = state_hart + 1) begin
                commit_count[state_hart] <= commit_count[state_hart] +
                    ((process_valid[0] &&
                      (rv_commit_hart_id[0] == state_hart)) ? 32'd1 : 32'd0) +
                    ((process_valid[1] &&
                      (rv_commit_hart_id[1] == state_hart)) ? 32'd1 : 32'd0);
                generated_count[state_hart] <= generated_count[state_hart] +
                    hart_candidate_count[state_hart];

                for (integer state_bank = 0; state_bank < 2;
                     state_bank = state_bank + 1) begin
                    if (fifo_bank_release[state_hart][state_bank]) begin
                        fifo_bank_busy[state_hart][state_bank] <= 1'b0;
                        fifo_bank_package[state_hart][state_bank] <= 16'b0;
                        tail_valid[state_hart][state_bank] <= 1'b0;
                        tail_pair[state_hart][state_bank] <= 128'b0;
                        bank_commit_items[state_hart][state_bank] <= 17'b0;
                        bank_generated_items[state_hart][state_bank] <= 17'b0;
                        bank_closed[state_hart][state_bank] <= 1'b0;
                    end

                    if (bank_commit_increment[state_hart][state_bank] != 0) begin
                        if (!fifo_bank_busy[state_hart][state_bank] ||
                            fifo_bank_release[state_hart][state_bank]) begin
                            fifo_bank_busy[state_hart][state_bank] <= 1'b1;
                            fifo_bank_package[state_hart][state_bank] <=
                                bank_commit_package[state_hart][state_bank];
                            bank_commit_items[state_hart][state_bank] <=
                                bank_commit_increment[state_hart][state_bank];
                            bank_generated_items[state_hart][state_bank] <= 17'b0;
                            bank_closed[state_hart][state_bank] <= 1'b0;
                        end else if (fifo_bank_package[state_hart][state_bank] ==
                                     bank_commit_package[state_hart][state_bank]) begin
                            bank_commit_items[state_hart][state_bank] <=
                                bank_commit_items[state_hart][state_bank] +
                                bank_commit_increment[state_hart][state_bank];
                        end else begin
                            bank_conflict <= 1'b1;
                        end
                    end

                    if (bank_candidate_count[state_hart][state_bank] != 0) begin
                        tail_pair[state_hart][state_bank] <=
                            packet_tail_pair[state_hart][state_bank];
                        tail_valid[state_hart][state_bank] <=
                            packet_tail_valid[state_hart][state_bank];
                        bank_generated_items[state_hart][state_bank] <=
                            bank_generated_items[state_hart][state_bank] +
                            bank_candidate_count[state_hart][state_bank];
                    end

                    if (bank_close_emit[state_hart][state_bank]) begin
                        tail_valid[state_hart][state_bank] <= 1'b0;
                        bank_closed[state_hart][state_bank] <= 1'b1;
                    end
                end
            end

            for (integer nb_hart = 0; nb_hart < 2; nb_hart = nb_hart + 1) begin
                for (integer nb_rd = 1; nb_rd <= 31; nb_rd = nb_rd + 1) begin
                    if (nb_selected[nb_hart][nb_rd])
                        nb_crc_valid[nb_hart][nb_rd] <= 1'b0;

                    if (nb_valid[nb_hart][nb_rd] && nb_resolved[nb_hart][nb_rd] &&
                        (!nb_crc_valid[nb_hart][nb_rd] ||
                         nb_selected[nb_hart][nb_rd])) begin
                        nb_crc_buffer[nb_hart][nb_rd] <=
                            {nb_c1_wire[nb_hart][nb_rd], nb_c0_wire[nb_hart][nb_rd]};
                        nb_crc_package[nb_hart][nb_rd] <=
                            nb_struct[nb_hart][nb_rd][159:144];
                        nb_crc_valid[nb_hart][nb_rd] <= 1'b1;
                        nb_valid[nb_hart][nb_rd] <= 1'b0;
                        nb_resolved[nb_hart][nb_rd] <= 1'b0;
                    end

                    if (nb_valid[nb_hart][nb_rd] && !nb_resolved[nb_hart][nb_rd]) begin
                        if (nb_cancel_match[nb_hart][nb_rd]) begin
                            nb_struct[nb_hart][nb_rd][31:0] <= 32'b0;
                            nb_resolved[nb_hart][nb_rd] <= 1'b1;
                        end else if (rv_nb_load_gpr_wen &&
                                     (rv_nb_load_gpr_hart_id == nb_hart) &&
                                     (rv_nb_load_gpr_rd == nb_rd)) begin
                            nb_struct[nb_hart][nb_rd][31:0] <= rv_nb_load_gpr_wdata;
                            nb_resolved[nb_hart][nb_rd] <= 1'b1;
                        end else if (rv_nb_div_gpr_wen &&
                                     (rv_nb_div_gpr_hart_id == nb_hart) &&
                                     (rv_nb_div_gpr_rd == nb_rd)) begin
                            nb_struct[nb_hart][nb_rd][31:0] <= rv_nb_div_gpr_wdata;
                            nb_resolved[nb_hart][nb_rd] <= 1'b1;
                        end
                    end
                end
            end

            for (integer store_lane = 0; store_lane < 2;
                 store_lane = store_lane + 1) begin
                if (alloc_accept[store_lane]) begin
                    nb_struct[rv_commit_hart_id[store_lane]]
                        [rv_commit_gpr_rd[store_lane]] <=
                            lane_struct[store_lane];
                    nb_resolved[rv_commit_hart_id[store_lane]]
                        [rv_commit_gpr_rd[store_lane]] <= 1'b0;
                    nb_valid[rv_commit_hart_id[store_lane]]
                        [rv_commit_gpr_rd[store_lane]] <= 1'b1;
                end
            end
        end
    end
endmodule
