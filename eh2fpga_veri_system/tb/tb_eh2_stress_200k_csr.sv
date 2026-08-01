`timescale 1ns/1ps

module tb_eh2_stress_200k_csr;
    logic core_clk = 1'b0;
    logic crc_rd_clk = 1'b0;
    logic infra_rst_l = 1'b0;
    always #10 core_clk = ~core_clk;
    always #4 crc_rd_clk = ~crc_rd_clk;

    logic core_rst_l, crc_system_ready;
    logic pass_latched, fail_latched, activity_seen, hart1_commit_seen;
    logic [1:0] stopped;
    logic [1:0][31:0] commit_count, generated_count;
    logic [1:0][1:0] result_valid;
    logic [1:0][1:0][15:0] result_package_number;
    logic [1:0][1:0][63:0] result_xor0, result_xor1;
    logic [1:0][1:0][63:0] result_sum0, result_sum1, result_sum2, result_sum3;
    logic [1:0][1:0][31:0] result_item_count;

    bit result_seen [0:1][0:1];
    logic [31:0] seen_count [0:1][0:1];
    logic [63:0] seen_xor0 [0:1][0:1];
    logic [63:0] seen_xor1 [0:1][0:1];
    logic [63:0] seen_sum0 [0:1][0:1];
    logic [63:0] seen_sum1 [0:1][0:1];
    logic [63:0] seen_sum2 [0:1][0:1];
    logic [63:0] seen_sum3 [0:1][0:1];
    integer struct_log;
    integer result_log;
    integer div_timing_log;
    integer dumped_count [0:1][0:1];

    eh2_crc_soc #(
        .MEM_BYTES(1_048_576),
        .MEM_FILE("../../programs/stress_200k_dualhart_system/build/stress_200k_dualhart_system.mem64"),
        .RUN_HART_MASK(2'b11),
        .ENABLE_GOLDEN_CHECK(1'b0)
    ) dut (.*);

    always @(posedge crc_rd_clk) begin : capture_results
        integer h;
        integer b;
        integer p;
        if (infra_rst_l) begin
            for (h = 0; h < 2; h = h + 1) begin
                for (b = 0; b < 2; b = b + 1) begin
                    if (result_valid[h][b]) begin
                        p = result_package_number[h][b];
                        $fwrite(result_log,
                                "hart=%0d bank=%0d package=%0d count=%0d xor0=%016h xor1=%016h sum0=%016h sum1=%016h sum2=%016h sum3=%016h\n",
                                h, b, p, result_item_count[h][b],
                                result_xor0[h][b], result_xor1[h][b],
                                result_sum0[h][b], result_sum1[h][b],
                                result_sum2[h][b], result_sum3[h][b]);
                        if ((p < 2) && !result_seen[h][p]) begin
                            result_seen[h][p] = 1'b1;
                            seen_count[h][p] = result_item_count[h][b];
                            seen_xor0[h][p] = result_xor0[h][b];
                            seen_xor1[h][p] = result_xor1[h][b];
                            seen_sum0[h][p] = result_sum0[h][b];
                            seen_sum1[h][p] = result_sum1[h][b];
                            seen_sum2[h][p] = result_sum2[h][b];
                            seen_sum3[h][p] = result_sum3[h][b];
                        end else begin
                            $fatal(1, "duplicate or unexpected result hart=%0d bank=%0d package=%0d",
                                   h, b, p);
                        end
                    end
                end
            end
        end
    end

    // Capture exactly the 160-bit structures which feed the CRC blocks.  A
    // software model later recomputes both CRCs and every package reduction
    // from this file, independently of the RTL result ports.
    always @(posedge core_clk) begin : capture_structs
        integer lane;
        integer h;
        integer rd;
        integer struct_hart;
        integer struct_package;
        if (infra_rst_l) begin
            if ((commit_count[0] < 32'd120) &&
                ((|dut.rv_commit_is_nonblock_div) ||
                 dut.rv_nb_div_gpr_wen)) begin
                $fwrite(div_timing_log,
                        "t=%0t count=%0d/%0d commit=%b div_commit=%b hart=%b rd=%0d/%0d pc=%08h/%08h insn=%08h/%08h ret=%b ret_h=%0d ret_rd=%0d ret_data=%08h b18=%b/%b/%08h b19=%b/%b/%08h b23=%b/%b/%08h conflict=%b\n",
                        $time, commit_count[0], commit_count[1],
                        dut.rv_commit_valid, dut.rv_commit_is_nonblock_div,
                        dut.rv_commit_hart_id,
                        dut.rv_commit_gpr_rd[0], dut.rv_commit_gpr_rd[1],
                        dut.rv_commit_pc[0], dut.rv_commit_pc[1],
                        dut.rv_commit_insn[0], dut.rv_commit_insn[1],
                        dut.rv_nb_div_gpr_wen,
                        dut.rv_nb_div_gpr_hart_id,
                        dut.rv_nb_div_gpr_rd,
                        dut.rv_nb_div_gpr_wdata,
                        dut.crc_i.hash_i.nb_valid[0][18],
                        dut.crc_i.hash_i.nb_resolved[0][18],
                        dut.crc_i.hash_i.nb_struct[0][18][31:0],
                        dut.crc_i.hash_i.nb_valid[0][19],
                        dut.crc_i.hash_i.nb_resolved[0][19],
                        dut.crc_i.hash_i.nb_struct[0][19][31:0],
                        dut.crc_i.hash_i.nb_valid[0][23],
                        dut.crc_i.hash_i.nb_resolved[0][23],
                        dut.crc_i.hash_i.nb_struct[0][23][31:0],
                        dut.buffer_conflict);
            end
            for (lane = 0; lane < 2; lane = lane + 1) begin
                if (dut.crc_i.hash_i.direct_valid[lane]) begin
                    // Metadata is bits 63:32; hart_id is metadata bit 16.
                    struct_hart = dut.crc_i.hash_i.lane_struct[lane][48];
                    struct_package = dut.crc_i.hash_i.lane_struct[lane][159:144];
                    if ((struct_hart < 2) && (struct_package < 2))
                        dumped_count[struct_hart][struct_package] =
                            dumped_count[struct_hart][struct_package] + 1;
                    $fwrite(struct_log, "%040h\n",
                            dut.crc_i.hash_i.lane_struct[lane]);
                end
            end
            for (h = 0; h < 2; h = h + 1) begin
                for (rd = 1; rd <= 31; rd = rd + 1) begin
                    if (dut.crc_i.hash_i.nb_valid[h][rd] &&
                        dut.crc_i.hash_i.nb_resolved[h][rd] &&
                        (!dut.crc_i.hash_i.nb_crc_valid[h][rd] ||
                         dut.crc_i.hash_i.nb_selected[h][rd])) begin
                        struct_package = dut.crc_i.hash_i.nb_struct[h][rd][159:144];
                        if (struct_package < 2)
                            dumped_count[h][struct_package] =
                                dumped_count[h][struct_package] + 1;
                        $fwrite(struct_log, "%040h\n",
                                dut.crc_i.hash_i.nb_struct[h][rd]);
                    end
                end
            end
        end
    end

    initial begin : run_test
        integer h;
        integer p;
        // Hart1 is not forced by the testbench.  Hart0 executes the
        // proprietary MHARTSTART CSR write from the Ethernet-loaded image.
        struct_log = $fopen("../../artifacts/sim/stress_200k_csr_actual_structs.txt", "w");
        result_log = $fopen("../../artifacts/sim/stress_200k_csr_results.txt", "w");
        div_timing_log = $fopen("../../artifacts/sim/stress_200k_csr_div_timing.txt", "w");
        for (h = 0; h < 2; h = h + 1)
            for (p = 0; p < 2; p = p + 1) begin
                result_seen[h][p] = 1'b0;
                dumped_count[h][p] = 0;
            end

        repeat (12) @(posedge core_clk);
        infra_rst_l = 1'b1;
        wait (core_rst_l);

        fork
            begin
                wait (stopped == 2'b11);
                wait ((dut.pending_nonblock_count[0] == 0) &&
                      (dut.pending_nonblock_count[1] == 0));
                wait (result_seen[0][0] && result_seen[0][1] &&
                      result_seen[1][0] && result_seen[1][1]);
            end
            begin
                repeat (30_000_000) @(posedge core_clk);
                $fatal(1,
                       "timeout ready=%b stopped=%b commit=%0d/%0d generated=%0d/%0d pending=%0d/%0d",
                       crc_system_ready, stopped, commit_count[0], commit_count[1],
                       generated_count[0], generated_count[1],
                       dut.pending_nonblock_count[0], dut.pending_nonblock_count[1]);
            end
        join_any
        disable fork;

        repeat (20) @(posedge crc_rd_clk);
        $fclose(struct_log);
        $fclose(result_log);
        $fclose(div_timing_log);

        if (dut.error_seen || fail_latched)
            $fatal(1, "sticky error detected error_seen=%b fail=%b", dut.error_seen,
                   fail_latched);
        if (!activity_seen || !hart1_commit_seen)
            $fatal(1, "both harts did not execute activity=%b hart1=%b",
                   activity_seen, hart1_commit_seen);
        for (h = 0; h < 2; h = h + 1) begin
            if (commit_count[h] != generated_count[h])
                $fatal(1, "commit/generated mismatch hart=%0d commit=%0d generated=%0d",
                       h, commit_count[h], generated_count[h]);
            if (commit_count[h] < 32'd90_000)
                $fatal(1, "insufficient stress coverage hart=%0d count=%0d",
                       h, commit_count[h]);
            if (seen_count[h][0] != 32'd65_536)
                $fatal(1, "package0 length error hart=%0d count=%0d",
                       h, seen_count[h][0]);
            if ((seen_count[h][0] + seen_count[h][1]) != generated_count[h])
                $fatal(1,
                       "package total mismatch hart=%0d p0=%0d p1=%0d generated=%0d",
                       h, seen_count[h][0], seen_count[h][1], generated_count[h]);
            if ((dumped_count[h][0] != seen_count[h][0]) ||
                (dumped_count[h][1] != seen_count[h][1]))
                $fatal(1,
                       "structure dump mismatch hart=%0d dump=%0d/%0d result=%0d/%0d",
                       h, dumped_count[h][0], dumped_count[h][1],
                       seen_count[h][0], seen_count[h][1]);
        end

        $display("EH2_STRESS_200K_CSR_PASS hart0=%0d hart1=%0d packages=%0d/%0d,%0d/%0d",
                 generated_count[0], generated_count[1],
                 seen_count[0][0], seen_count[0][1],
                 seen_count[1][0], seen_count[1][1]);
        $finish;
    end
endmodule
