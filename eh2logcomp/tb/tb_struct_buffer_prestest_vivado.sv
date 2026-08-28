`timescale 1ns/1ps

// EH2-only Vivado/XSim stress bench for the Struct Info buffer.  The program
// image is replaced between XSim invocations, so the same elaborated snapshot
// runs all ten directed programs without involving the Ethernet/system top.
module tb_struct_buffer_prestest_vivado;
    logic core_clk = 1'b0;
    logic crc_rd_clk = 1'b0;
    logic infra_rst_l = 1'b0;
    always #10 core_clk = ~core_clk;       // EH2: 50 MHz
    always #4  crc_rd_clk = ~crc_rd_clk;  // CRC consumer: 125 MHz

    logic core_rst_l;
    logic crc_system_ready;
    logic pass_latched;
    logic fail_latched;
    logic activity_seen;
    logic hart1_commit_seen;
    logic [1:0] stopped;
    logic [1:0][31:0] commit_count;
    logic [1:0][31:0] generated_count;
    logic [1:0][1:0] result_valid;
    logic [1:0][1:0][15:0] result_package_number;
    logic [1:0][1:0][63:0] result_xor0;
    logic [1:0][1:0][63:0] result_xor1;
    logic [1:0][1:0][63:0] result_sum0;
    logic [1:0][1:0][63:0] result_sum1;
    logic [1:0][1:0][63:0] result_sum2;
    logic [1:0][1:0][63:0] result_sum3;
    logic [1:0][1:0][31:0] result_item_count;

    integer struct_log;
    integer interface_log;
    integer struct_count;
    integer direct_count;
    integer resolved_count;
    integer handoff_count;
    integer nonblock_commit_count;
    integer waw_event_count;
    string case_id;
    string struct_path;
    string interface_path;

    eh2_crc_soc #(
        .MEM_BYTES(131072),
        .MEM_FILE("program.mem64"),
        .RUN_HART_MASK(2'b01),
        .ENABLE_GOLDEN_CHECK(1'b0)
    ) dut (.*);

    task automatic write_struct(
        input string source_name,
        input logic [159:0] value
    );
        begin
            $fwrite(struct_log,
                    "STRUCT source=%s hart=%0d package=%0d sequence=%0d value=%040h\n",
                    source_name, value[48], value[159:144],
                    value[143:128], value);
            struct_count = struct_count + 1;
        end
    endtask

    // Capture the exact 160-bit value at the last point before CRC generation.
    // The atomic path must be sampled in the handoff cycle, before the NBA
    // allocation replaces nb_struct[hart][rd] with the younger instruction.
    always @(posedge core_clk) begin : capture_pre_crc
        integer lane;
        integer hart;
        integer rd;
        if (infra_rst_l) begin
            for (lane = 0; lane < 2; lane = lane + 1) begin
                if (dut.crc_i.hash_i.direct_valid[lane]) begin
                    write_struct("direct", dut.crc_i.hash_i.lane_struct[lane]);
                    direct_count = direct_count + 1;
                end
            end
            for (hart = 0; hart < 2; hart = hart + 1) begin
                for (rd = 1; rd <= 31; rd = rd + 1) begin
                    if (dut.crc_i.hash_i.nb_atomic_handoff[hart][rd]) begin
                        write_struct("atomic_waw_victim",
                                     dut.crc_i.hash_i.nb_struct[hart][rd]);
                        handoff_count = handoff_count + 1;
                    end else if (dut.crc_i.hash_i.nb_valid[hart][rd] &&
                                 dut.crc_i.hash_i.nb_resolved[hart][rd] &&
                                 (!dut.crc_i.hash_i.nb_crc_valid[hart][rd] ||
                                  dut.crc_i.hash_i.nb_selected[hart][rd])) begin
                        write_struct("resolved_nonblock",
                                     dut.crc_i.hash_i.nb_struct[hart][rd]);
                        resolved_count = resolved_count + 1;
                    end
                end
            end

            for (lane = 0; lane < 2; lane = lane + 1) begin
                if (dut.rv_commit_valid[lane]) begin
                    $fwrite(interface_log,
                            "COMMIT t=%0t lane=%0d hart=%0d pc=%08h insn=%08h rd=%0d intent=%0d wen=%0d data=%08h nb=%0d load=%0d div=%0d direct_waw=%0d\n",
                            $time, lane, dut.rv_commit_hart_id[lane],
                            dut.rv_commit_pc[lane], dut.rv_commit_insn[lane],
                            dut.rv_commit_gpr_rd[lane],
                            dut.rv_commit_gpr_wen_intent[lane],
                            dut.rv_commit_gpr_wen[lane],
                            dut.rv_commit_gpr_wdata[lane],
                            dut.rv_commit_is_nonblock[lane],
                            dut.rv_commit_is_nonblock_load[lane],
                            dut.rv_commit_is_nonblock_div[lane],
                            dut.rv_commit_waw_victim[lane]);
                    if (dut.rv_commit_is_nonblock[lane])
                        nonblock_commit_count = nonblock_commit_count + 1;
                end
                if (dut.rv_nb_waw_valid[lane]) begin
                    $fwrite(interface_log,
                            "NB_WAW t=%0t lane=%0d hart=%0d rd=%0d\n",
                            $time, lane,
                            dut.rv_nb_waw_victim_hart_id[lane],
                            dut.rv_nb_waw_victim_gpr_rd[lane]);
                    waw_event_count = waw_event_count + 1;
                end
            end
            if (dut.rv_nb_load_gpr_wen)
                $fwrite(interface_log,
                        "LOAD_RETURN t=%0t hart=%0d rd=%0d data=%08h\n",
                        $time, dut.rv_nb_load_gpr_hart_id,
                        dut.rv_nb_load_gpr_rd, dut.rv_nb_load_gpr_wdata);
            if (dut.rv_nb_div_gpr_wen)
                $fwrite(interface_log,
                        "DIV_RETURN t=%0t hart=%0d rd=%0d data=%08h\n",
                        $time, dut.rv_nb_div_gpr_hart_id,
                        dut.rv_nb_div_gpr_rd, dut.rv_nb_div_gpr_wdata);
        end
    end

    initial begin : run_test
        case_id = "unknown";
        if ($test$plusargs("CASE00")) case_id = "00";
        if ($test$plusargs("CASE01")) case_id = "01";
        if ($test$plusargs("CASE02")) case_id = "02";
        if ($test$plusargs("CASE03")) case_id = "03";
        if ($test$plusargs("CASE04")) case_id = "04";
        if ($test$plusargs("CASE05")) case_id = "05";
        if ($test$plusargs("CASE06")) case_id = "06";
        if ($test$plusargs("CASE07")) case_id = "07";
        if ($test$plusargs("CASE08")) case_id = "08";
        if ($test$plusargs("CASE09")) case_id = "09";
        struct_path = {"../../verification_log/struct_buffer_prestest/case_",
                       case_id, "/vivado_structs_unsorted.log"};
        interface_path = {"../../verification_log/struct_buffer_prestest/case_",
                          case_id, "/vivado_interface.log"};
        struct_log = $fopen(struct_path, "w");
        interface_log = $fopen(interface_path, "w");
        if ((struct_log == 0) || (interface_log == 0))
            $fatal(1, "cannot open case logs case=%s", case_id);

        struct_count = 0;
        direct_count = 0;
        resolved_count = 0;
        handoff_count = 0;
        nonblock_commit_count = 0;
        waw_event_count = 0;

        repeat (12) @(posedge core_clk);
        infra_rst_l = 1'b1;
        wait (core_rst_l);

        fork
            begin
                wait (stopped[0]);
                wait (dut.pending_nonblock_count[0] == 0);
                wait (generated_count[0] == commit_count[0]);
            end
            begin
                repeat (1_000_000) @(posedge core_clk);
                $fatal(1,
                       "timeout case=%s stopped=%b commit=%0d generated=%0d pending=%0d",
                       case_id, stopped, commit_count[0], generated_count[0],
                       dut.pending_nonblock_count[0]);
            end
        join_any
        disable fork;
        repeat (40) @(posedge crc_rd_clk);

        $fwrite(interface_log,
                "SUMMARY case=%s commits=%0d generated=%0d structs=%0d direct=%0d resolved=%0d atomic_handoff=%0d nonblock_commits=%0d waw_events=%0d conflict=%0d fifo_overflow=%0d bank_conflict=%0d\n",
                case_id, commit_count[0], generated_count[0], struct_count,
                direct_count, resolved_count, handoff_count,
                nonblock_commit_count, waw_event_count,
                dut.buffer_conflict, dut.fifo_overflow, dut.bank_conflict);
        $fclose(struct_log);
        $fclose(interface_log);

        if (dut.error_seen || dut.buffer_conflict || dut.fifo_overflow ||
            dut.bank_conflict)
            $fatal(1, "CRC/buffer error in case %s", case_id);
        if ((commit_count[0] < 32'd430) || (commit_count[0] > 32'd550))
            $fatal(1, "case %s is not approximately 500 instructions: %0d",
                   case_id, commit_count[0]);
        if (nonblock_commit_count < 250)
            $fatal(1, "insufficient nonblocking pressure case=%s count=%0d",
                   case_id, nonblock_commit_count);
        if ((waw_event_count == 0) || (handoff_count == 0))
            $fatal(1, "WAW/atomic handoff not exercised case=%s waw=%0d handoff=%0d",
                   case_id, waw_event_count, handoff_count);
        if (struct_count != generated_count[0])
            $fatal(1, "pre-CRC capture mismatch case=%s structs=%0d generated=%0d",
                   case_id, struct_count, generated_count[0]);

        $display("STRUCT_BUFFER_PRETEST_VIVADO_PASS case=%s commits=%0d nonblock=%0d waw=%0d handoff=%0d structs=%0d",
                 case_id, commit_count[0], nonblock_commit_count,
                 waw_event_count, handoff_count, struct_count);
        $finish;
    end
endmodule
