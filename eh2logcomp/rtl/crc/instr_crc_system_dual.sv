// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module instr_crc_system_dual #(
    parameter integer LSU_TAG_WIDTH = 4
) (
    input  logic                         wr_clk,
    input  logic                         rd_clk,
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
    output logic [1:0][5:0]             pending_nonblock_count,

    output logic [1:0][1:0]             result_valid,
    output logic [1:0][1:0][15:0]       result_package_number,
    output logic [1:0][1:0][63:0]       result_xor0,
    output logic [1:0][1:0][63:0]       result_xor1,
    output logic [1:0][1:0][63:0]       result_sum0,
    output logic [1:0][1:0][63:0]       result_sum1,
    output logic [1:0][1:0][63:0]       result_sum2,
    output logic [1:0][1:0][63:0]       result_sum3,
    output logic [1:0][1:0][31:0]       result_item_count,
    output logic [1:0][1:0][7:0]        fifo_occupancy,
    output logic                         system_ready
);
    logic [1:0][1:0][3:0] fifo_wr_valid;
    logic [1:0][1:0][3:0][128:0] fifo_wr_data;
    logic [1:0][1:0][3:0] fifo_wr_ready;
    logic [1:0][1:0][7:0] fifo_free_count;
    logic [1:0][1:0] fifo_lane_overflow;
    logic [1:0][1:0] fifo_init_done;
    logic hash_fifo_overflow;
    logic [1:0] hash_fifo_overflow_hart;
    logic [1:0][1:0] fifo_rd_valid;
    logic [1:0][1:0][128:0] fifo_rd_data;
    logic [1:0][1:0] fifo_rd_empty;

    logic [1:0][1:0][15:0] fifo_bank_package_wr;
    logic [1:0][1:0] fifo_bank_busy;
    logic [1:0][1:0][15:0] package_sync1;
    logic [1:0][1:0][15:0] package_sync2;

    logic [1:0][1:0] release_toggle_rd;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0][1:0][2:0] release_toggle_sync;
    logic [1:0][1:0] fifo_bank_release_wr;

    integer release_rd_hart;
    integer release_rd_bank;
    integer release_wr_hart;
    integer release_wr_bank;
    integer release_comb_hart;
    integer release_comb_bank;

    instr_crc_hash_dual #(
        .LSU_TAG_WIDTH(LSU_TAG_WIDTH)
    ) hash_i (
        .clk(wr_clk),
        .rst_l(rst_l),
        .rv_commit_valid(rv_commit_valid),
        .rv_commit_insn(rv_commit_insn),
        .rv_commit_pc(rv_commit_pc),
        .rv_commit_hart_id(rv_commit_hart_id),
        .rv_commit_priv_mode(rv_commit_priv_mode),
        .rv_commit_gpr_wen_intent(rv_commit_gpr_wen_intent),
        .rv_commit_gpr_wen(rv_commit_gpr_wen),
        .rv_commit_gpr_rd(rv_commit_gpr_rd),
        .rv_commit_gpr_wdata(rv_commit_gpr_wdata),
        .rv_commit_csr_wen(rv_commit_csr_wen),
        .rv_commit_csr_addr(rv_commit_csr_addr),
        .rv_commit_csr_wdata(rv_commit_csr_wdata),
        .rv_commit_is_nonblock(rv_commit_is_nonblock),
        .rv_commit_is_nonblock_load(rv_commit_is_nonblock_load),
        .rv_commit_is_nonblock_div(rv_commit_is_nonblock_div),
        .rv_commit_waw_victim(rv_commit_waw_victim),
        .rv_nb_waw_valid(rv_nb_waw_valid),
        .rv_nb_waw_victim_hart_id(rv_nb_waw_victim_hart_id),
        .rv_nb_waw_victim_gpr_rd(rv_nb_waw_victim_gpr_rd),
        .rv_nb_load_gpr_wen(rv_nb_load_gpr_wen),
        .rv_nb_load_gpr_hart_id(rv_nb_load_gpr_hart_id),
        .rv_nb_load_gpr_rd(rv_nb_load_gpr_rd),
        .rv_nb_load_gpr_wdata(rv_nb_load_gpr_wdata),
        .rv_nb_div_gpr_wen(rv_nb_div_gpr_wen),
        .rv_nb_div_gpr_hart_id(rv_nb_div_gpr_hart_id),
        .rv_nb_div_gpr_rd(rv_nb_div_gpr_rd),
        .rv_nb_div_gpr_wdata(rv_nb_div_gpr_wdata),
        .lsu_axi_awvalid(lsu_axi_awvalid),
        .lsu_axi_awready(lsu_axi_awready),
        .lsu_axi_awid(lsu_axi_awid),
        .lsu_axi_awaddr(lsu_axi_awaddr),
        .lsu_axi_wvalid(lsu_axi_wvalid),
        .lsu_axi_wready(lsu_axi_wready),
        .lsu_axi_wdata(lsu_axi_wdata),
        .lsu_axi_wstrb(lsu_axi_wstrb),
        .fifo_free_count(fifo_free_count),
        .fifo_bank_release(fifo_bank_release_wr),
        .fifo_wr_valid(fifo_wr_valid),
        .fifo_wr_data(fifo_wr_data),
        .fifo_bank_package(fifo_bank_package_wr),
        .fifo_bank_busy(fifo_bank_busy),
        .buffer_conflict(buffer_conflict),
        .fifo_overflow(hash_fifo_overflow),
        .bank_conflict(bank_conflict),
        .buffer_conflict_hart(buffer_conflict_hart),
        .fifo_overflow_hart(hash_fifo_overflow_hart),
        .bank_conflict_hart(bank_conflict_hart),
        .waw_cancel_valid(waw_cancel_valid),
        .waw_cancel_hart(waw_cancel_hart),
        .waw_cancel_package(waw_cancel_package),
        .waw_cancel_sequence(waw_cancel_sequence),
        .stopped(stopped),
        .sequence_number(sequence_number),
        .package_number(package_number),
        .commit_count(commit_count),
        .generated_count(generated_count),
        .pending_nonblock_count(pending_nonblock_count)
    );

    always_comb begin
        fifo_overflow = hash_fifo_overflow |
                        |fifo_lane_overflow[0] |
                        |fifo_lane_overflow[1];
        fifo_overflow_hart[0] = hash_fifo_overflow_hart[0] |
                                |fifo_lane_overflow[0];
        fifo_overflow_hart[1] = hash_fifo_overflow_hart[1] |
                                |fifo_lane_overflow[1];
    end

    // The package number is static while a bank is occupied. Two flops are
    // sufficient to carry that status into the 125 MHz result domain.
    always_ff @(posedge rd_clk or negedge rst_l) begin
        if (!rst_l) begin
            package_sync1 <= '0;
            package_sync2 <= '0;
        end else begin
            package_sync1 <= fifo_bank_package_wr;
            package_sync2 <= package_sync1;
        end
    end

    always_ff @(posedge rd_clk or negedge rst_l) begin
        if (!rst_l)
            release_toggle_rd <= '0;
        else begin
            for (release_rd_hart = 0; release_rd_hart < 2;
                 release_rd_hart = release_rd_hart + 1)
                for (release_rd_bank = 0; release_rd_bank < 2;
                     release_rd_bank = release_rd_bank + 1)
                    if (result_valid[release_rd_hart][release_rd_bank])
                        release_toggle_rd[release_rd_hart][release_rd_bank] <=
                            ~release_toggle_rd[release_rd_hart][release_rd_bank];
        end
    end

    always_ff @(posedge wr_clk or negedge rst_l) begin
        if (!rst_l)
            release_toggle_sync <= '0;
        else begin
            for (release_wr_hart = 0; release_wr_hart < 2;
                 release_wr_hart = release_wr_hart + 1)
                for (release_wr_bank = 0; release_wr_bank < 2;
                     release_wr_bank = release_wr_bank + 1)
                    release_toggle_sync[release_wr_hart][release_wr_bank] <= {
                        release_toggle_sync[release_wr_hart][release_wr_bank][1:0],
                        release_toggle_rd[release_wr_hart][release_wr_bank]
                    };
        end
    end

    always_comb begin
        for (release_comb_hart = 0; release_comb_hart < 2;
             release_comb_hart = release_comb_hart + 1)
            for (release_comb_bank = 0; release_comb_bank < 2;
                 release_comb_bank = release_comb_bank + 1)
                fifo_bank_release_wr[release_comb_hart][release_comb_bank] =
                    release_toggle_sync[release_comb_hart][release_comb_bank][2] ^
                    release_toggle_sync[release_comb_hart][release_comb_bank][1];
    end

    genvar gh;
    genvar gb;
    generate
        for (gh = 0; gh < 2; gh = gh + 1) begin : g_hart
            for (gb = 0; gb < 2; gb = gb + 1) begin : g_bank
                crc_pair_fifo_async_4w1r fifo_i (
                    .wr_clk        (wr_clk),
                    .rd_clk        (rd_clk),
                    .rst_l         (rst_l),
                    .wr_valid      (fifo_wr_valid[gh][gb]),
                    .wr_data       (fifo_wr_data[gh][gb]),
                    .wr_ready      (fifo_wr_ready[gh][gb]),
                    .wr_free_count (fifo_free_count[gh][gb]),
                    .wr_overflow   (fifo_lane_overflow[gh][gb]),
                    .wr_init_done  (fifo_init_done[gh][gb]),
                    .rd_valid      (fifo_rd_valid[gh][gb]),
                    .rd_data       (fifo_rd_data[gh][gb]),
                    .rd_occupancy  (fifo_occupancy[gh][gb]),
                    .rd_empty      (fifo_rd_empty[gh][gb])
                );

                crc_mix_accumulator accumulator_i (
                    .clk                   (rd_clk),
                    .rst_l                 (rst_l),
                    .in_valid              (fifo_rd_valid[gh][gb]),
                    .in_last               (fifo_rd_data[gh][gb][128]),
                    .in_c0                 (fifo_rd_data[gh][gb][63:0]),
                    .in_c1                 (fifo_rd_data[gh][gb][127:64]),
                    .bank_package_number   (package_sync2[gh][gb]),
                    .result_valid          (result_valid[gh][gb]),
                    .result_package_number (result_package_number[gh][gb]),
                    .result_xor0           (result_xor0[gh][gb]),
                    .result_xor1           (result_xor1[gh][gb]),
                    .result_sum0           (result_sum0[gh][gb]),
                    .result_sum1           (result_sum1[gh][gb]),
                    .result_sum2           (result_sum2[gh][gb]),
                    .result_sum3           (result_sum3[gh][gb]),
                    .result_item_count     (result_item_count[gh][gb])
                );
            end
        end
    endgenerate

    always_comb
        system_ready = &fifo_init_done;
endmodule
