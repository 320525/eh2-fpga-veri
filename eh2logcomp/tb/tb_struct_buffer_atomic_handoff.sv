`timescale 1ns/1ps

module tb_struct_buffer_atomic_handoff;
    logic clk = 1'b0;
    logic rst_l = 1'b0;
    always #10 clk = ~clk;

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

    instr_crc_hash_dual dut (.*);

    task automatic clear_inputs;
        begin
            rv_commit_valid = '0;
            rv_commit_insn = '0;
            rv_commit_pc = '0;
            rv_commit_hart_id = '0;
            rv_commit_priv_mode = '{default:2'b11};
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
            fifo_free_count = '{default:8'd128};
            fifo_bank_release = '0;
        end
    endtask

    task automatic commit_delayed_load(
        input logic hart,
        input logic [4:0] rd,
        input logic [31:0] pc,
        input logic [31:0] insn
    );
        begin
            clear_inputs();
            rv_commit_valid[0] = 1'b1;
            rv_commit_hart_id[0] = hart;
            rv_commit_pc[0] = pc;
            rv_commit_insn[0] = insn;
            rv_commit_gpr_wen_intent[0] = 1'b1;
            rv_commit_gpr_rd[0] = rd;
            rv_commit_is_nonblock[0] = 1'b1;
            rv_commit_is_nonblock_load[0] = 1'b1;
        end
    endtask

    initial begin : run_test
        logic [63:0] victim_c0;
        logic [63:0] victim_c1;

        clear_inputs();
        repeat (4) @(posedge clk);
        rst_l = 1'b1;

        // Old delayed load occupies hart0/x10.
        @(negedge clk);
        commit_delayed_load(1'b0, 5'd10, 32'h8000_0100, 32'h0005_2503);
        @(posedge clk);
        #1;
        if (!dut.nb_valid[0][10] || dut.nb_resolved[0][10])
            $fatal(1, "victim load was not allocated");
        if (dut.nb_struct[0][10][143:128] != 16'd0)
            $fatal(1, "victim sequence mismatch");

        // The younger delayed load commits to the same rd while EH2 reports
        // the old load as a WAW victim. The old CRC must be captured and the
        // new structure must own the slot after this one edge.
        @(negedge clk);
        commit_delayed_load(1'b0, 5'd10, 32'h8000_0104, 32'h0045_2503);
        rv_nb_waw_valid[0] = 1'b1;
        rv_nb_waw_victim_hart_id[0] = 1'b0;
        rv_nb_waw_victim_gpr_rd[0] = 5'd10;
        #1;
        victim_c0 = dut.nb_c0_wire[0][10];
        victim_c1 = dut.nb_c1_wire[0][10];
        if (!dut.alloc_atomic_handoff[0] || !dut.alloc_accept[0])
            $fatal(1, "atomic handoff was not accepted");
        if (!waw_cancel_valid[2] || waw_cancel_sequence[2] != 16'd0)
            $fatal(1, "victim WAW identity was not exported");
        @(posedge clk);
        #1;
        if (buffer_conflict)
            $fatal(1, "atomic handoff incorrectly reported a conflict");
        if (!dut.nb_crc_valid[0][10] ||
            dut.nb_crc_buffer[0][10] != {victim_c1, victim_c0})
            $fatal(1, "victim CRC was not captured atomically");
        if (!dut.nb_valid[0][10] || dut.nb_resolved[0][10] ||
            dut.nb_struct[0][10][127:96] != 32'h8000_0104 ||
            dut.nb_struct[0][10][143:128] != 16'd1)
            $fatal(1, "younger load did not take ownership atomically");

        // Let the victim CRC drain, then complete the younger load.
        @(negedge clk);
        clear_inputs();
        @(negedge clk);
        clear_inputs();
        rv_nb_load_gpr_wen = 1'b1;
        rv_nb_load_gpr_hart_id = 1'b0;
        rv_nb_load_gpr_rd = 5'd10;
        rv_nb_load_gpr_wdata = 32'h1234_5678;
        @(posedge clk);
        #1;
        if (!dut.nb_resolved[0][10] ||
            dut.nb_struct[0][10][31:0] != 32'h1234_5678)
            $fatal(1, "younger load return was not attached to the new owner");
        @(negedge clk);
        clear_inputs();
        wait (generated_count[0] == 32'd2);

        // Busy handling: keep a previous CRC resident, allocate another load
        // into the now-free Struct slot, then attempt a second WAW handoff.
        // The new writer must be rejected without overwriting either old item.
        fifo_free_count = '0;
        @(negedge clk);
        commit_delayed_load(1'b0, 5'd11, 32'h8000_0200, 32'h0006_2583);
        fifo_free_count = '0;
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        fifo_free_count = '0;
        rv_nb_load_gpr_wen = 1'b1;
        rv_nb_load_gpr_hart_id = 1'b0;
        rv_nb_load_gpr_rd = 5'd11;
        rv_nb_load_gpr_wdata = 32'ha5a5_0001;
        @(posedge clk);
        @(negedge clk);
        clear_inputs();
        fifo_free_count = '0;
        @(posedge clk);
        #1;
        if (!dut.nb_crc_valid[0][11])
            $fatal(1, "failed to create the deliberately busy CRC slot");

        @(negedge clk);
        commit_delayed_load(1'b0, 5'd11, 32'h8000_0204, 32'h0046_2583);
        fifo_free_count = '0;
        @(posedge clk);
        #1;
        if (!dut.nb_valid[0][11] || dut.nb_resolved[0][11])
            $fatal(1, "second pending load was not allocated behind busy CRC");

        @(negedge clk);
        commit_delayed_load(1'b0, 5'd11, 32'h8000_0208, 32'h0086_2583);
        rv_nb_waw_valid[0] = 1'b1;
        rv_nb_waw_victim_hart_id[0] = 1'b0;
        rv_nb_waw_victim_gpr_rd[0] = 5'd11;
        fifo_free_count = '0;
        #1;
        if (dut.alloc_atomic_handoff[0] || dut.alloc_accept[0])
            $fatal(1, "handoff was accepted while the CRC slot was busy");
        @(posedge clk);
        #1;
        if (!buffer_conflict || !buffer_conflict_hart[0])
            $fatal(1, "busy handoff did not raise the hart conflict pulse");
        if (!dut.nb_valid[0][11] || !dut.nb_resolved[0][11] ||
            dut.nb_struct[0][11][127:96] != 32'h8000_0204 ||
            dut.nb_struct[0][11][31:0] != 32'b0)
            $fatal(1, "busy handling overwrote the canceled victim");

        $display("STRUCT_BUFFER_ATOMIC_HANDOFF_PASS normal_handoff=1 busy_conflict=1");
        $finish;
    end
endmodule
