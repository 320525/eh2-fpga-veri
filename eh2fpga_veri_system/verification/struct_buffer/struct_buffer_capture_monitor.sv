`timescale 1ns/1ps

module struct_buffer_capture_monitor (
    input logic clk,
    input logic rst_l,
    input logic [31:0] cycle_count,
    input logic [1:0] rv_commit_valid,
    input logic [1:0][31:0] rv_commit_insn,
    input logic [1:0][31:0] rv_commit_pc,
    input logic [1:0] rv_commit_hart_id,
    input logic [1:0][1:0] rv_commit_priv_mode,
    input logic [1:0] rv_commit_gpr_wen_intent,
    input logic [1:0] rv_commit_gpr_wen,
    input logic [1:0][4:0] rv_commit_gpr_rd,
    input logic [1:0][31:0] rv_commit_gpr_wdata,
    input logic [1:0] rv_commit_csr_wen,
    input logic [1:0][11:0] rv_commit_csr_addr,
    input logic [1:0][31:0] rv_commit_csr_wdata,
    input logic [1:0] rv_commit_is_nonblock,
    input logic [1:0] rv_commit_is_nonblock_load,
    input logic [1:0] rv_commit_is_nonblock_div,
    input logic [1:0] rv_commit_waw_victim,
    input logic [1:0] rv_nb_waw_valid,
    input logic [1:0] rv_nb_waw_victim_hart_id,
    input logic [1:0][4:0] rv_nb_waw_victim_gpr_rd,
    input logic rv_nb_load_gpr_wen,
    input logic rv_nb_load_gpr_hart_id,
    input logic [4:0] rv_nb_load_gpr_rd,
    input logic [31:0] rv_nb_load_gpr_wdata,
    input logic rv_nb_div_gpr_wen,
    input logic rv_nb_div_gpr_hart_id,
    input logic [4:0] rv_nb_div_gpr_rd,
    input logic [31:0] rv_nb_div_gpr_wdata,
    input logic lsu_axi_awvalid,
    input logic lsu_axi_awready,
    input logic [3:0] lsu_axi_awid,
    input logic [31:0] lsu_axi_awaddr,
    input logic lsu_axi_wvalid,
    input logic lsu_axi_wready,
    input logic [63:0] lsu_axi_wdata,
    input logic [7:0] lsu_axi_wstrb
);
    logic [1:0][1:0][7:0] fifo_free_count;
    logic [1:0][1:0] fifo_bank_release;
    logic [1:0][1:0][3:0] fifo_wr_valid;
    logic [1:0][1:0][3:0][128:0] fifo_wr_data;
    logic [1:0][1:0][15:0] fifo_bank_package;
    logic [1:0][1:0] fifo_bank_busy;
    logic buffer_conflict, fifo_overflow, bank_conflict;
    logic [1:0] buffer_conflict_hart, fifo_overflow_hart;
    logic [1:0] bank_conflict_hart;
    logic [3:0] waw_cancel_valid, waw_cancel_hart;
    logic [3:0][15:0] waw_cancel_package, waw_cancel_sequence;
    logic [1:0] stopped;
    logic [1:0][15:0] sequence_number, package_number;
    logic [1:0][31:0] commit_count, generated_count;
    logic [1:0][5:0] pending_nonblock_count;

    integer interface_fd;
    integer struct_fd;
    integer direct_count;
    integer resolved_count;
    integer handoff_count;
    integer conflict_count;

    assign fifo_free_count = '{default:8'hff};
    assign fifo_bank_release = '0;

    instr_crc_hash_dual hash_dut (
        .clk(clk), .rst_l(rst_l),
        .rv_commit_valid(rv_commit_valid), .rv_commit_insn(rv_commit_insn),
        .rv_commit_pc(rv_commit_pc), .rv_commit_hart_id(rv_commit_hart_id),
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
        .lsu_axi_awvalid(lsu_axi_awvalid), .lsu_axi_awready(lsu_axi_awready),
        .lsu_axi_awid(lsu_axi_awid), .lsu_axi_awaddr(lsu_axi_awaddr),
        .lsu_axi_wvalid(lsu_axi_wvalid), .lsu_axi_wready(lsu_axi_wready),
        .lsu_axi_wdata(lsu_axi_wdata), .lsu_axi_wstrb(lsu_axi_wstrb),
        .fifo_free_count(fifo_free_count),
        .fifo_bank_release(fifo_bank_release),
        .fifo_wr_valid(fifo_wr_valid), .fifo_wr_data(fifo_wr_data),
        .fifo_bank_package(fifo_bank_package),
        .fifo_bank_busy(fifo_bank_busy),
        .buffer_conflict(buffer_conflict), .fifo_overflow(fifo_overflow),
        .bank_conflict(bank_conflict),
        .buffer_conflict_hart(buffer_conflict_hart),
        .fifo_overflow_hart(fifo_overflow_hart),
        .bank_conflict_hart(bank_conflict_hart),
        .waw_cancel_valid(waw_cancel_valid),
        .waw_cancel_hart(waw_cancel_hart),
        .waw_cancel_package(waw_cancel_package),
        .waw_cancel_sequence(waw_cancel_sequence),
        .stopped(stopped), .sequence_number(sequence_number),
        .package_number(package_number), .commit_count(commit_count),
        .generated_count(generated_count),
        .pending_nonblock_count(pending_nonblock_count)
    );

    initial begin
        interface_fd = $fopen("eh2_interface_raw.log", "w");
        struct_fd = $fopen("rtl_structs_unsorted.log", "w");
        direct_count = 0;
        resolved_count = 0;
        handoff_count = 0;
        conflict_count = 0;
    end

    always @(posedge clk) begin : capture_pre_crc
        integer lane;
        integer hart;
        integer rd;
        integer struct_hart;
        integer struct_package;
        integer struct_sequence;
        if (rst_l) begin
            if ((|rv_commit_valid) || (|rv_nb_waw_valid) ||
                rv_nb_load_gpr_wen || rv_nb_div_gpr_wen) begin
                $fwrite(interface_fd,
                  "IF cycle=%0d cv=%02x c0_insn=%08x c0_pc=%08x c0_h=%0d c0_priv=%0d c0_gint=%0d c0_gwen=%0d c0_rd=%0d c0_wdata=%08x c0_csrwen=%0d c0_csr=%03x c0_csrdata=%08x c0_nb=%0d c0_nbl=%0d c0_nbd=%0d c0_wawv=%0d c1_insn=%08x c1_pc=%08x c1_h=%0d c1_priv=%0d c1_gint=%0d c1_gwen=%0d c1_rd=%0d c1_wdata=%08x c1_csrwen=%0d c1_csr=%03x c1_csrdata=%08x c1_nb=%0d c1_nbl=%0d c1_nbd=%0d c1_wawv=%0d nw=%02x nw0_h=%0d nw0_rd=%0d nw1_h=%0d nw1_rd=%0d lr=%0d lr_h=%0d lr_rd=%0d lr_data=%08x dr=%0d dr_h=%0d dr_rd=%0d dr_data=%08x\n",
                  cycle_count, rv_commit_valid,
                  rv_commit_insn[0], rv_commit_pc[0], rv_commit_hart_id[0],
                  rv_commit_priv_mode[0], rv_commit_gpr_wen_intent[0],
                  rv_commit_gpr_wen[0], rv_commit_gpr_rd[0],
                  rv_commit_gpr_wdata[0], rv_commit_csr_wen[0],
                  rv_commit_csr_addr[0], rv_commit_csr_wdata[0],
                  rv_commit_is_nonblock[0], rv_commit_is_nonblock_load[0],
                  rv_commit_is_nonblock_div[0], rv_commit_waw_victim[0],
                  rv_commit_insn[1], rv_commit_pc[1], rv_commit_hart_id[1],
                  rv_commit_priv_mode[1], rv_commit_gpr_wen_intent[1],
                  rv_commit_gpr_wen[1], rv_commit_gpr_rd[1],
                  rv_commit_gpr_wdata[1], rv_commit_csr_wen[1],
                  rv_commit_csr_addr[1], rv_commit_csr_wdata[1],
                  rv_commit_is_nonblock[1], rv_commit_is_nonblock_load[1],
                  rv_commit_is_nonblock_div[1], rv_commit_waw_victim[1],
                  rv_nb_waw_valid,
                  rv_nb_waw_victim_hart_id[0], rv_nb_waw_victim_gpr_rd[0],
                  rv_nb_waw_victim_hart_id[1], rv_nb_waw_victim_gpr_rd[1],
                  rv_nb_load_gpr_wen, rv_nb_load_gpr_hart_id,
                  rv_nb_load_gpr_rd, rv_nb_load_gpr_wdata,
                  rv_nb_div_gpr_wen, rv_nb_div_gpr_hart_id,
                  rv_nb_div_gpr_rd, rv_nb_div_gpr_wdata);
            end

            for (lane = 0; lane < 2; lane = lane + 1) begin
                if (hash_dut.direct_valid[lane]) begin
                    struct_hart = hash_dut.lane_struct[lane][48];
                    struct_package = hash_dut.lane_struct[lane][159:144];
                    struct_sequence = hash_dut.lane_struct[lane][143:128];
                    $fwrite(struct_fd,
                      "RTL cycle=%0d source=direct lane=%0d hart=%0d package=%0d sequence=%0d struct=%040x\n",
                      cycle_count, lane, struct_hart, struct_package,
                      struct_sequence, hash_dut.lane_struct[lane]);
                    direct_count = direct_count + 1;
                end
            end

            for (hart = 0; hart < 2; hart = hart + 1) begin
                for (rd = 1; rd <= 31; rd = rd + 1) begin
                    if (hash_dut.nb_atomic_handoff[hart][rd]) begin
                        struct_package = hash_dut.nb_struct[hart][rd][159:144];
                        struct_sequence = hash_dut.nb_struct[hart][rd][143:128];
                        $fwrite(struct_fd,
                          "RTL cycle=%0d source=handoff rd=%0d hart=%0d package=%0d sequence=%0d struct=%040x\n",
                          cycle_count, rd, hart, struct_package,
                          struct_sequence, hash_dut.nb_struct[hart][rd]);
                        handoff_count = handoff_count + 1;
                    end else if (hash_dut.nb_valid[hart][rd] &&
                                 hash_dut.nb_resolved[hart][rd] &&
                                 (!hash_dut.nb_crc_valid[hart][rd] ||
                                  hash_dut.nb_selected[hart][rd])) begin
                        struct_package = hash_dut.nb_struct[hart][rd][159:144];
                        struct_sequence = hash_dut.nb_struct[hart][rd][143:128];
                        $fwrite(struct_fd,
                          "RTL cycle=%0d source=resolved rd=%0d hart=%0d package=%0d sequence=%0d struct=%040x\n",
                          cycle_count, rd, hart, struct_package,
                          struct_sequence, hash_dut.nb_struct[hart][rd]);
                        resolved_count = resolved_count + 1;
                    end
                end
            end

            if (buffer_conflict)
                conflict_count = conflict_count + 1;
        end
    end

    final begin
        $fwrite(struct_fd,
          "SUMMARY direct=%0d resolved=%0d handoff=%0d conflicts=%0d commits=%0d/%0d generated=%0d/%0d pending=%0d/%0d\n",
          direct_count, resolved_count, handoff_count, conflict_count,
          commit_count[0], commit_count[1], generated_count[0],
          generated_count[1], pending_nonblock_count[0],
          pending_nonblock_count[1]);
        $fclose(interface_fd);
        $fclose(struct_fd);
    end
endmodule

bind tb_top struct_buffer_capture_monitor u_struct_buffer_capture_monitor (
    .clk(core_clk), .rst_l(rst_l), .cycle_count(cycleCnt),
    .rv_commit_valid(rvtop.rv_commit_valid),
    .rv_commit_insn(rvtop.rv_commit_insn),
    .rv_commit_pc(rvtop.rv_commit_pc),
    .rv_commit_hart_id(rvtop.rv_commit_hart_id),
    .rv_commit_priv_mode(rvtop.rv_commit_priv_mode),
    .rv_commit_gpr_wen_intent(rvtop.rv_commit_gpr_wen_intent),
    .rv_commit_gpr_wen(rvtop.rv_commit_gpr_wen),
    .rv_commit_gpr_rd(rvtop.rv_commit_gpr_rd),
    .rv_commit_gpr_wdata(rvtop.rv_commit_gpr_wdata),
    .rv_commit_csr_wen(rvtop.rv_commit_csr_wen),
    .rv_commit_csr_addr(rvtop.rv_commit_csr_addr),
    .rv_commit_csr_wdata(rvtop.rv_commit_csr_wdata),
    .rv_commit_is_nonblock(rvtop.rv_commit_is_nonblock),
    .rv_commit_is_nonblock_load(rvtop.rv_commit_is_nonblock_load),
    .rv_commit_is_nonblock_div(rvtop.rv_commit_is_nonblock_div),
    .rv_commit_waw_victim(rvtop.rv_commit_waw_victim),
    .rv_nb_waw_valid(rvtop.rv_nb_waw_valid),
    .rv_nb_waw_victim_hart_id(rvtop.rv_nb_waw_victim_hart_id),
    .rv_nb_waw_victim_gpr_rd(rvtop.rv_nb_waw_victim_gpr_rd),
    .rv_nb_load_gpr_wen(rvtop.rv_nb_load_gpr_wen),
    .rv_nb_load_gpr_hart_id(rvtop.rv_nb_load_gpr_hart_id),
    .rv_nb_load_gpr_rd(rvtop.rv_nb_load_gpr_rd),
    .rv_nb_load_gpr_wdata(rvtop.rv_nb_load_gpr_wdata),
    .rv_nb_div_gpr_wen(rvtop.rv_nb_div_gpr_wen),
    .rv_nb_div_gpr_hart_id(rvtop.rv_nb_div_gpr_hart_id),
    .rv_nb_div_gpr_rd(rvtop.rv_nb_div_gpr_rd),
    .rv_nb_div_gpr_wdata(rvtop.rv_nb_div_gpr_wdata),
    .lsu_axi_awvalid(lsu_axi_awvalid), .lsu_axi_awready(lsu_axi_awready),
    .lsu_axi_awid(lsu_axi_awid), .lsu_axi_awaddr(lsu_axi_awaddr),
    .lsu_axi_wvalid(lsu_axi_wvalid), .lsu_axi_wready(lsu_axi_wready),
    .lsu_axi_wdata(lsu_axi_wdata), .lsu_axi_wstrb(lsu_axi_wstrb)
);
