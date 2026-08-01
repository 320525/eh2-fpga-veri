`timescale 1ns/1ps

module tb_crc_ten_packages;
    localparam integer PACKAGES = 10;
    localparam integer TOTAL_PER_HART = PACKAGES * 65536;

    logic wr_clk = 1'b0;
    logic rd_clk = 1'b0;
    logic rst_l = 1'b0;
    always #10 wr_clk = ~wr_clk;
    always #4 rd_clk = ~rd_clk;

    logic [1:0] rv_commit_valid;
    logic [1:0][31:0] rv_commit_insn, rv_commit_pc;
    logic [1:0] rv_commit_hart_id;
    logic [1:0][1:0] rv_commit_priv_mode;
    logic [1:0] rv_commit_gpr_wen_intent, rv_commit_gpr_wen;
    logic [1:0][4:0] rv_commit_gpr_rd;
    logic [1:0][31:0] rv_commit_gpr_wdata;
    logic [1:0] rv_commit_csr_wen;
    logic [1:0][11:0] rv_commit_csr_addr;
    logic [1:0][31:0] rv_commit_csr_wdata;
    logic [1:0] rv_commit_is_nonblock;
    logic [1:0] rv_commit_is_nonblock_load;
    logic [1:0] rv_commit_is_nonblock_div;
    logic [1:0] rv_commit_waw_victim;
    logic [1:0] rv_nb_waw_valid, rv_nb_waw_victim_hart_id;
    logic [1:0][4:0] rv_nb_waw_victim_gpr_rd;
    logic rv_nb_load_gpr_wen, rv_nb_load_gpr_hart_id;
    logic [4:0] rv_nb_load_gpr_rd;
    logic [31:0] rv_nb_load_gpr_wdata;
    logic rv_nb_div_gpr_wen, rv_nb_div_gpr_hart_id;
    logic [4:0] rv_nb_div_gpr_rd;
    logic [31:0] rv_nb_div_gpr_wdata;
    logic lsu_axi_awvalid, lsu_axi_awready;
    logic [3:0] lsu_axi_awid;
    logic [31:0] lsu_axi_awaddr;
    logic lsu_axi_wvalid, lsu_axi_wready;
    logic [63:0] lsu_axi_wdata;
    logic [7:0] lsu_axi_wstrb;

    logic buffer_conflict, fifo_overflow, bank_conflict;
    logic [1:0] stopped;
    logic [1:0][15:0] sequence_number, package_number;
    logic [1:0][31:0] commit_count, generated_count;
    logic [1:0][5:0] pending_nonblock_count;
    logic [1:0][1:0] result_valid;
    logic [1:0][1:0][15:0] result_package_number;
    logic [1:0][1:0][63:0] result_xor0, result_xor1;
    logic [1:0][1:0][63:0] result_sum0, result_sum1;
    logic [1:0][1:0][63:0] result_sum2, result_sum3;
    logic [1:0][1:0][31:0] result_item_count;
    logic [1:0][1:0][7:0] fifo_occupancy;
    logic system_ready;

    logic [383:0] golden_h0 [0:PACKAGES-1];
    logic [383:0] golden_h1 [0:PACKAGES-1];
    logic [PACKAGES-1:0] seen_h0, seen_h1;
    logic saw_buffer_conflict, saw_fifo_overflow, saw_bank_conflict;
    integer errors;

    instr_crc_system_dual #(.LSU_TAG_WIDTH(4)) dut (.*);

    task automatic clear_inputs;
        begin
            rv_commit_valid = '0;
            rv_commit_insn = '0;
            rv_commit_pc = '0;
            rv_commit_hart_id = '0;
            rv_commit_priv_mode = '0;
            rv_commit_gpr_wen_intent = '0;
            rv_commit_gpr_wen = '0;
            rv_commit_gpr_rd = '0;
            rv_commit_gpr_wdata = '0;
            rv_commit_csr_wen = '0;
            rv_commit_csr_addr = '0;
            rv_commit_csr_wdata = '0;
            rv_commit_is_nonblock = '0;
            rv_commit_is_nonblock_load = '0;
            rv_commit_is_nonblock_div = '0;
            rv_commit_waw_victim = '0;
            rv_nb_waw_valid = '0;
            rv_nb_waw_victim_hart_id = '0;
            rv_nb_waw_victim_gpr_rd = '0;
            rv_nb_load_gpr_wen = 1'b0;
            rv_nb_load_gpr_hart_id = 1'b0;
            rv_nb_load_gpr_rd = '0;
            rv_nb_load_gpr_wdata = '0;
            rv_nb_div_gpr_wen = 1'b0;
            rv_nb_div_gpr_hart_id = 1'b0;
            rv_nb_div_gpr_rd = '0;
            rv_nb_div_gpr_wdata = '0;
            lsu_axi_awvalid = 1'b0;
            lsu_axi_awready = 1'b1;
            lsu_axi_awid = '0;
            lsu_axi_awaddr = '0;
            lsu_axi_wvalid = 1'b0;
            lsu_axi_wready = 1'b1;
            lsu_axi_wdata = '0;
            lsu_axi_wstrb = '0;
        end
    endtask

    task automatic drive_commit(input integer slot, input integer hart,
                                input integer absolute);
        logic [31:0] index32;
        begin
            index32 = absolute;
            rv_commit_valid[slot] = 1'b1;
            rv_commit_hart_id[slot] = hart[0];
            rv_commit_priv_mode[slot] = 2'd3;
            rv_commit_pc[slot] = 32'h80000000 + (hart << 16) +
                                 ((absolute & 1023) << 2);
            rv_commit_insn[slot] = 32'h00000013 ^ (index32 * 32'h00001021);
            rv_commit_gpr_wen_intent[slot] = 1'b1;
            rv_commit_gpr_wen[slot] = 1'b1;
            rv_commit_gpr_rd[slot] = (absolute % 31) + 1;
            rv_commit_gpr_wdata[slot] =
                (index32 * 32'h9e3779b1) ^
                (hart ? 32'ha5a5a5a5 : 32'h00000000);
        end
    endtask

    task automatic send_marker(input logic hart);
        begin
            @(negedge wr_clk); clear_inputs();
            lsu_axi_awvalid = 1'b1;
            lsu_axi_awid = hart ? 4'h8 : 4'h0;
            lsu_axi_awaddr = 32'hd0580000;
            lsu_axi_wvalid = 1'b1;
            lsu_axi_wdata = 64'h0000000000320525;
            lsu_axi_wstrb = 8'h0f;
            @(negedge wr_clk); clear_inputs();
        end
    endtask

    task automatic compare_result(input integer hart, input integer bank);
        integer pkg;
        logic [383:0] expected;
        begin
            pkg = result_package_number[hart][bank];
            if (pkg < 0 || pkg >= PACKAGES) begin
                $error("unexpected package hart=%0d bank=%0d pkg=%0d", hart, bank, pkg);
                errors = errors + 1;
            end else begin
                expected = hart ? golden_h1[pkg] : golden_h0[pkg];
                if (result_item_count[hart][bank] !== 32'd65536 ||
                    result_xor0[hart][bank] !== expected[383:320] ||
                    result_xor1[hart][bank] !== expected[319:256] ||
                    result_sum0[hart][bank] !== expected[255:192] ||
                    result_sum1[hart][bank] !== expected[191:128] ||
                    result_sum2[hart][bank] !== expected[127:64] ||
                    result_sum3[hart][bank] !== expected[63:0]) begin
                    $error("package mismatch hart=%0d bank=%0d pkg=%0d count=%0d",
                           hart, bank, pkg, result_item_count[hart][bank]);
                    errors = errors + 1;
                end
                if (hart)
                    seen_h1[pkg] = 1'b1;
                else
                    seen_h0[pkg] = 1'b1;
                $display("PACKAGE_PASS hart=%0d bank=%0d package=%0d count=%0d",
                         hart, bank, pkg, result_item_count[hart][bank]);
            end
        end
    endtask

    always @(posedge rd_clk) begin
        if (rst_l) begin
            for (integer h = 0; h < 2; h = h + 1)
                for (integer b = 0; b < 2; b = b + 1)
                    if (result_valid[h][b])
                        compare_result(h, b);
        end
    end

    always @(posedge wr_clk) begin
        if (!rst_l) begin
            saw_buffer_conflict <= 1'b0;
            saw_fifo_overflow <= 1'b0;
            saw_bank_conflict <= 1'b0;
        end else begin
            saw_buffer_conflict <= saw_buffer_conflict | buffer_conflict;
            saw_fifo_overflow <= saw_fifo_overflow | fifo_overflow;
            saw_bank_conflict <= saw_bank_conflict | bank_conflict;
        end
    end

    initial begin
        $readmemh("../sim/wrap_expected_hart0.mem", golden_h0);
        $readmemh("../sim/wrap_expected_hart1.mem", golden_h1);
        errors = 0;
        seen_h0 = '0;
        seen_h1 = '0;
        clear_inputs();
        repeat (8) @(posedge wr_clk);
        rst_l = 1'b1;
        wait (system_ready);
        repeat (2) @(posedge wr_clk);

        for (integer absolute = 0; absolute < TOTAL_PER_HART;
             absolute = absolute + 1) begin
            @(negedge wr_clk);
            clear_inputs();
            drive_commit(0, 0, absolute);
            drive_commit(1, 1, absolute);
        end
        @(negedge wr_clk); clear_inputs();

        wait (generated_count[0] == TOTAL_PER_HART &&
              generated_count[1] == TOTAL_PER_HART);
        send_marker(1'b0);
        send_marker(1'b1);

        fork
            begin
                wait (&seen_h0 && &seen_h1);
            end
            begin
                repeat (200000) @(posedge rd_clk);
                $fatal(1, "timeout: seen_h0=%b seen_h1=%b", seen_h0, seen_h1);
            end
        join_any
        disable fork;
        repeat (20) @(posedge rd_clk);

        if (sequence_number[0] !== 16'd0 || sequence_number[1] !== 16'd0 ||
            package_number[0] !== 16'd10 || package_number[1] !== 16'd10) begin
            $error("counter wrap mismatch seq=%h/%h pkg=%h/%h",
                   sequence_number[0], sequence_number[1],
                   package_number[0], package_number[1]);
            errors = errors + 1;
        end
        if (commit_count[0] !== TOTAL_PER_HART ||
            commit_count[1] !== TOTAL_PER_HART) begin
            $error("commit count mismatch %0d/%0d", commit_count[0], commit_count[1]);
            errors = errors + 1;
        end
        if (saw_buffer_conflict || saw_fifo_overflow || saw_bank_conflict) begin
            $error("unexpected conflict buffer=%b fifo=%b bank=%b",
                   saw_buffer_conflict, saw_fifo_overflow, saw_bank_conflict);
            errors = errors + 1;
        end
        if (errors)
            $fatal(1, "ten-package test failed errors=%0d", errors);
        $display("TEN_PACKAGE_PASS total_per_hart=%0d", TOTAL_PER_HART);
        $finish;
    end
endmodule
