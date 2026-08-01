`timescale 1ns/1ps

module tb_nonblock_same_cycle_return;
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
            fifo_free_count = '{default:8'd128};
            fifo_bank_release = '0;
        end
    endtask

    initial begin
        clear_inputs();
        repeat (4) @(posedge clk);
        rst_l = 1'b1;
        @(negedge clk);
        clear_inputs();

        // Both records are allocated on EH2 commit.  The divide result is
        // returned in that same cycle, while the load remains outstanding.
        rv_commit_valid = 2'b11;
        rv_commit_insn[0] = 32'h027f5933;
        rv_commit_insn[1] = 32'h0004a503;
        rv_commit_pc[0] = 32'h80000050;
        rv_commit_pc[1] = 32'h80001050;
        rv_commit_hart_id = 2'b10;
        rv_commit_priv_mode = '{default:2'b11};
        rv_commit_gpr_wen_intent = 2'b11;
        rv_commit_gpr_rd[0] = 5'd9;
        rv_commit_gpr_rd[1] = 5'd10;
        rv_commit_is_nonblock = 2'b11;
        rv_commit_is_nonblock_div = 2'b01;
        rv_commit_is_nonblock_load = 2'b10;

        rv_nb_div_gpr_wen = 1'b1;
        rv_nb_div_gpr_hart_id = 1'b0;
        rv_nb_div_gpr_rd = 5'd9;
        rv_nb_div_gpr_wdata = 32'h11223344;

        @(posedge clk);
        #1;
        if (dut.nb_valid[0][9])
            $fatal(1, "same-cycle div incorrectly entered nonblocking buffer");
        if (dut.lane_struct[0][31:0] != 32'h11223344)
            $fatal(1, "same-cycle div data was not placed in the direct structure");
        if (generated_count[0] != 1)
            $fatal(1, "same-cycle div did not use the direct CRC path");
        if (!dut.nb_valid[1][10] || dut.nb_resolved[1][10])
            $fatal(1, "delayed load did not remain pending after commit");

        @(negedge clk);
        clear_inputs();
        @(negedge clk);
        clear_inputs();
        rv_nb_load_gpr_wen = 1'b1;
        rv_nb_load_gpr_hart_id = 1'b1;
        rv_nb_load_gpr_rd = 5'd10;
        rv_nb_load_gpr_wdata = 32'h55667788;
        @(posedge clk);
        #1;
        if (!dut.nb_valid[1][10] || !dut.nb_resolved[1][10] ||
            (dut.nb_struct[1][10][31:0] != 32'h55667788))
            $fatal(1, "delayed load return was not captured");

        @(negedge clk);
        clear_inputs();
        wait ((generated_count[0] == 1) && (generated_count[1] == 1));
        if (buffer_conflict || fifo_overflow || bank_conflict)
            $fatal(1, "unexpected conflict after same-cycle returns");

        // EH2 has one nonblocking-load return port and one divide return
        // port. Allocate two different destinations on the same hart, then
        // return both values in one cycle. Both independent rd-indexed
        // entries must resolve in parallel.
        @(negedge clk);
        clear_inputs();
        rv_commit_valid = 2'b11;
        rv_commit_insn[0] = 32'h0005a583;
        rv_commit_insn[1] = 32'h02d64633;
        rv_commit_pc[0] = 32'h80000060;
        rv_commit_pc[1] = 32'h80000064;
        rv_commit_hart_id = 2'b00;
        rv_commit_priv_mode = '{default:2'b11};
        rv_commit_gpr_wen_intent = 2'b11;
        rv_commit_gpr_rd[0] = 5'd11;
        rv_commit_gpr_rd[1] = 5'd12;
        rv_commit_is_nonblock = 2'b11;
        rv_commit_is_nonblock_load = 2'b01;
        rv_commit_is_nonblock_div = 2'b10;
        @(posedge clk);
        #1;
        if (!dut.nb_valid[0][11] || dut.nb_resolved[0][11] ||
            !dut.nb_valid[0][12] || dut.nb_resolved[0][12])
            $fatal(1, "parallel load/div buffers were not allocated");

        @(negedge clk);
        clear_inputs();
        rv_nb_load_gpr_wen = 1'b1;
        rv_nb_load_gpr_hart_id = 1'b0;
        rv_nb_load_gpr_rd = 5'd11;
        rv_nb_load_gpr_wdata = 32'ha1b2c3d4;
        rv_nb_div_gpr_wen = 1'b1;
        rv_nb_div_gpr_hart_id = 1'b0;
        rv_nb_div_gpr_rd = 5'd12;
        rv_nb_div_gpr_wdata = 32'h5a6b7c8d;
        @(posedge clk);
        #1;
        if (!dut.nb_resolved[0][11] ||
            (dut.nb_struct[0][11][31:0] != 32'ha1b2c3d4))
            $fatal(1, "parallel load return was not captured");
        if (!dut.nb_resolved[0][12] ||
            (dut.nb_struct[0][12][31:0] != 32'h5a6b7c8d))
            $fatal(1, "parallel divide return was not captured");

        @(negedge clk);
        clear_inputs();
        wait ((generated_count[0] == 3) && (generated_count[1] == 1));
        if (buffer_conflict || fifo_overflow || bank_conflict)
            $fatal(1, "unexpected conflict after parallel load/div return");
        $display("NONBLOCK_RETURN_PASS same_cycle_div=%08h delayed_load=%08h parallel_load=%08h parallel_div=%08h",
                 32'h11223344, 32'h55667788, 32'ha1b2c3d4, 32'h5a6b7c8d);
        $finish;
    end
endmodule
