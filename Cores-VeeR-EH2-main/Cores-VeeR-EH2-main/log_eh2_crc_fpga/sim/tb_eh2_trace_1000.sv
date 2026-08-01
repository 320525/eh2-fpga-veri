`timescale 1ns/1ps

module tb_eh2_trace_1000;
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
    integer struct_log;
    integer event_log;

    eh2_crc_soc #(
        .MEM_FILE("../programs/trace_1000_jump/trace_1000_jump.mem64"),
        .MEM_BYTES(8192),
        .SPARSE_AUX_ENABLE(1'b1),
        .SPARSE_AUX_ADDR(32'h8001_0000),
        .SPARSE_AUX_INIT(64'h2468_ace0_1357_9bdf),
        .RUN_HART_MASK(2'b01), .ENABLE_GOLDEN_CHECK(1'b1)
    ) dut (.*);

    always @(posedge crc_rd_clk)
        if (result_valid[0][0])
            $display("RESULT hart=0 package=%0d count=%0d xor0=%016h xor1=%016h sum0=%016h sum1=%016h sum2=%016h sum3=%016h",
                     result_package_number[0][0], result_item_count[0][0],
                     result_xor0[0][0], result_xor1[0][0],
                     result_sum0[0][0], result_sum1[0][0],
                     result_sum2[0][0], result_sum3[0][0]);

    always @(posedge core_clk) begin
        if (infra_rst_l) begin
            if ((commit_count[0] >= 32'd35 && commit_count[0] <= 32'd70) ||
                (|dut.rv_nb_waw_valid) || dut.rv_nb_load_gpr_wen ||
                dut.rv_nb_div_gpr_wen ||
                (|dut.core_i.veer.dec.decode.cam_i0_nb_waw) ||
                (|dut.core_i.veer.dec.decode.cam_i1_nb_waw) ||
                (|dut.core_i.veer.dec.decode.commit_monitor_wb.nb_waw_valid)) begin
                $fwrite(event_log,
                        "cycle=%0t count=%0d commit_v=%b insn0=%08h insn1=%08h rd0=%0d rd1=%0d nb=%b waw=%b waw_rd0=%0d waw_rd1=%0d raw_mon_waw=%b raw_cam0=%b raw_cam1=%b raw_div=%b/%b load_ret=%b/%0d/%08h div_ret=%b/%0d/%08h buf22=%b/%b/%08h buf23=%b/%b/%08h\n",
                        $time, commit_count[0], dut.rv_commit_valid,
                        dut.rv_commit_insn[0], dut.rv_commit_insn[1],
                        dut.rv_commit_gpr_rd[0], dut.rv_commit_gpr_rd[1],
                        dut.rv_commit_is_nonblock,
                        dut.rv_nb_waw_valid,
                        dut.rv_nb_waw_victim_gpr_rd[0],
                        dut.rv_nb_waw_victim_gpr_rd[1],
                        dut.core_i.veer.dec.decode.commit_monitor_wb.nb_waw_valid,
                        dut.core_i.veer.dec.decode.cam_i0_nb_waw,
                        dut.core_i.veer.dec.decode.cam_i1_nb_waw,
                        dut.core_i.veer.dec.decode.i0_nbdiv_waw_wb,
                        dut.core_i.veer.dec.decode.i1_nbdiv_waw_wb,
                        dut.rv_nb_load_gpr_wen, dut.rv_nb_load_gpr_rd,
                        dut.rv_nb_load_gpr_wdata,
                        dut.rv_nb_div_gpr_wen, dut.rv_nb_div_gpr_rd,
                        dut.rv_nb_div_gpr_wdata,
                        dut.crc_i.hash_i.nb_valid[0][22],
                        dut.crc_i.hash_i.nb_resolved[0][22],
                        dut.crc_i.hash_i.nb_struct[0][22][31:0],
                        dut.crc_i.hash_i.nb_valid[0][23],
                        dut.crc_i.hash_i.nb_resolved[0][23],
                        dut.crc_i.hash_i.nb_struct[0][23][31:0]);
            end
            for (integer dump_lane = 0; dump_lane < 2;
                 dump_lane = dump_lane + 1)
                if (dut.crc_i.hash_i.direct_valid[dump_lane])
                    $fwrite(struct_log, "%040h\n",
                            dut.crc_i.hash_i.lane_struct[dump_lane]);
            for (integer dump_hart = 0; dump_hart < 2;
                 dump_hart = dump_hart + 1)
                for (integer dump_rd = 1; dump_rd <= 31;
                     dump_rd = dump_rd + 1)
                    if (dut.crc_i.hash_i.nb_valid[dump_hart][dump_rd] &&
                        dut.crc_i.hash_i.nb_resolved[dump_hart][dump_rd] &&
                        (!dut.crc_i.hash_i.nb_crc_valid[dump_hart][dump_rd] ||
                         dut.crc_i.hash_i.nb_selected[dump_hart][dump_rd]))
                        $fwrite(struct_log, "%040h\n",
                                dut.crc_i.hash_i.nb_struct[dump_hart][dump_rd]);
        end
    end

    initial begin
        struct_log = $fopen("../sim/eh2_trace_1000_actual_structs.txt", "w");
        event_log = $fopen("../sim/eh2_trace_1000_events.txt", "w");
        repeat (12) @(posedge core_clk);
        infra_rst_l = 1'b1;
        fork
            begin
                wait (pass_latched || fail_latched);
            end
            begin
                repeat (2_000_000) @(posedge core_clk);
                $fatal(1, "timeout core_rst=%b ready=%b stopped=%b commit=%0d generated=%0d",
                       core_rst_l, crc_system_ready, stopped,
                       commit_count[0], generated_count[0]);
            end
        join_any
        disable fork;
        repeat (20) @(posedge crc_rd_clk);
        if (!pass_latched || fail_latched)
            $fatal(1, "EH2 trace failed pass=%b fail=%b commits=%0d/%0d generated=%0d/%0d hart1=%b",
                   pass_latched, fail_latched, commit_count[0], commit_count[1],
                   generated_count[0], generated_count[1], hart1_commit_seen);
        $display("EH2_TRACE_1000_PASS commits=%0d generated=%0d", commit_count[0], generated_count[0]);
        $finish;
    end
endmodule
