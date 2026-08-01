`timescale 1ns/1ps

module tb_crc_system_smoke;
    logic wr_clk = 1'b0;
    logic rd_clk = 1'b0;
    logic rst_l = 1'b0;
    always #10 wr_clk = ~wr_clk;  // 50 MHz
    always #4  rd_clk = ~rd_clk;  // 125 MHz

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

    logic [1:0] rv_nb_waw_valid;
    logic [1:0] rv_nb_waw_victim_hart_id;
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

    logic [1:0] got_result;
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

    task automatic normal_gpr(
        input integer slot, input logic hart_id,
        input logic [31:0] pc, input logic [31:0] insn,
        input logic [4:0] rd, input logic [31:0] data
    );
        begin
            rv_commit_valid[slot] = 1'b1;
            rv_commit_hart_id[slot] = hart_id;
            rv_commit_pc[slot] = pc;
            rv_commit_insn[slot] = insn;
            rv_commit_priv_mode[slot] = 2'd3;
            rv_commit_gpr_wen_intent[slot] = 1'b1;
            rv_commit_gpr_wen[slot] = 1'b1;
            rv_commit_gpr_rd[slot] = rd;
            rv_commit_gpr_wdata[slot] = data;
        end
    endtask

    task automatic nonblock_gpr(
        input integer slot, input logic hart_id,
        input logic [31:0] pc, input logic [31:0] insn,
        input logic [4:0] rd
    );
        begin
            rv_commit_valid[slot] = 1'b1;
            rv_commit_hart_id[slot] = hart_id;
            rv_commit_pc[slot] = pc;
            rv_commit_insn[slot] = insn;
            rv_commit_priv_mode[slot] = 2'd3;
            rv_commit_gpr_wen_intent[slot] = 1'b1;
            rv_commit_gpr_rd[slot] = rd;
            rv_commit_is_nonblock[slot] = 1'b1;
            rv_commit_is_nonblock_load[slot] =
                (insn[6:0] == 7'b0000011);
            rv_commit_is_nonblock_div[slot] =
                (insn[6:0] == 7'b0110011) &&
                (insn[31:25] == 7'b0000001) && insn[14];
        end
    endtask

    task automatic marker(input logic hart_id);
        begin
            @(negedge wr_clk);
            clear_inputs();
            lsu_axi_awvalid = 1'b1;
            lsu_axi_awid = hart_id ? 4'h8 : 4'h0;
            lsu_axi_awaddr = 32'hd0580000;
            lsu_axi_wvalid = 1'b1;
            lsu_axi_wdata = 64'h0000000000320525;
            lsu_axi_wstrb = 8'h0f;
            @(negedge wr_clk);
            clear_inputs();
        end
    endtask

    task automatic expect64(
        input string name, input logic [63:0] actual,
        input logic [63:0] expected
    );
        begin
            if (actual !== expected) begin
                $error("%s: actual=%016h expected=%016h", name, actual, expected);
                errors = errors + 1;
            end
        end
    endtask

    always @(posedge rd_clk) begin
        if (rst_l) begin
            if (result_valid[0][0]) begin
                got_result[0] <= 1'b1;
                if (result_package_number[0][0] !== 16'd0 ||
                    result_item_count[0][0] !== 32'd7) begin
                    $error("hart0 header pkg=%0d count=%0d",
                           result_package_number[0][0], result_item_count[0][0]);
                    errors = errors + 1;
                end
                expect64("hart0 xor0", result_xor0[0][0], 64'h7399915b5c85f5ec);
                expect64("hart0 xor1", result_xor1[0][0], 64'h4d151b29f78d7ad9);
                expect64("hart0 sum0", result_sum0[0][0], 64'h0b8679b3a0ba7b38);
                expect64("hart0 sum1", result_sum1[0][0], 64'hd13268e496b5359f);
                expect64("hart0 sum2", result_sum2[0][0], 64'hea55cb376ecc9aa5);
                expect64("hart0 sum3", result_sum3[0][0], 64'hff05b583c547b618);
            end
            if (result_valid[1][0]) begin
                got_result[1] <= 1'b1;
                if (result_package_number[1][0] !== 16'd0 ||
                    result_item_count[1][0] !== 32'd5) begin
                    $error("hart1 header pkg=%0d count=%0d",
                           result_package_number[1][0], result_item_count[1][0]);
                    errors = errors + 1;
                end
                expect64("hart1 xor0", result_xor0[1][0], 64'h74ea2f9549b2a047);
                expect64("hart1 xor1", result_xor1[1][0], 64'h8746fdbaf8869a05);
                expect64("hart1 sum0", result_sum0[1][0], 64'h771ba71c7334c395);
                expect64("hart1 sum1", result_sum1[1][0], 64'hcd5e39441ca49b65);
                expect64("hart1 sum2", result_sum2[1][0], 64'hce37beccb413dea5);
                expect64("hart1 sum3", result_sum3[1][0], 64'hb74ffb9b1dc25f7d);
            end
        end
    end

    always @(posedge wr_clk) begin
        if (rst_l) begin
            if (|dut.fifo_wr_valid[0][0])
                $display("H0B0 full=%b wr_busy=%b rr=%0d wr_count=%p",
                         dut.g_hart[0].g_bank[0].fifo_i.lane_full,
                         dut.g_hart[0].g_bank[0].fifo_i.lane_wr_rst_busy,
                         dut.g_hart[0].g_bank[0].fifo_i.wr_round_robin,
                         dut.g_hart[0].g_bank[0].fifo_i.lane_wr_count);
            for (integer debug_h = 0; debug_h < 2; debug_h = debug_h + 1)
                for (integer debug_b = 0; debug_b < 2; debug_b = debug_b + 1)
                    if (|dut.fifo_wr_valid[debug_h][debug_b])
                        $display("WR t=%0t h=%0d b=%0d valid=%b ready=%b last=%b occ=%0d",
                                 $time, debug_h, debug_b,
                                 dut.fifo_wr_valid[debug_h][debug_b],
                                 dut.fifo_wr_ready[debug_h][debug_b],
                                 {dut.fifo_wr_data[debug_h][debug_b][3][128],
                                  dut.fifo_wr_data[debug_h][debug_b][2][128],
                                  dut.fifo_wr_data[debug_h][debug_b][1][128],
                                  dut.fifo_wr_data[debug_h][debug_b][0][128]},
                                 fifo_occupancy[debug_h][debug_b]);
        end
    end

    always @(posedge rd_clk) begin
        if (rst_l) begin
            for (integer debug_h = 0; debug_h < 2; debug_h = debug_h + 1)
                for (integer debug_b = 0; debug_b < 2; debug_b = debug_b + 1)
                    if (dut.fifo_rd_valid[debug_h][debug_b])
                        $display("RD t=%0t h=%0d b=%0d last=%b occ=%0d",
                                 $time, debug_h, debug_b,
                                 dut.fifo_rd_data[debug_h][debug_b][128],
                                 fifo_occupancy[debug_h][debug_b]);
        end
    end

    initial begin
        errors = 0;
        got_result = '0;
        clear_inputs();
        repeat (8) @(posedge wr_clk);
        rst_l = 1'b1;
        wait (system_ready);
        repeat (2) @(posedge wr_clk);

        // Normal writes on both harts.
        @(negedge wr_clk); clear_inputs();
        normal_gpr(0, 1'b0, 32'h80000000, 32'h00100093, 5'd1, 32'h11);
        normal_gpr(1, 1'b1, 32'h80001000, 32'h10100093, 5'd1, 32'h101);

        // i0 is the same-cycle WAW victim; metadata remains, only data is zero.
        @(negedge wr_clk); clear_inputs();
        normal_gpr(0, 1'b0, 32'h80000004, 32'h00200113, 5'd2, 32'h12);
        rv_commit_gpr_wen[0] = 1'b0;
        rv_commit_waw_victim[0] = 1'b1;
        normal_gpr(1, 1'b0, 32'h80000008, 32'h02200113, 5'd2, 32'h22);

        // Allocate one delayed load/div buffer on each hart.
        @(negedge wr_clk); clear_inputs();
        nonblock_gpr(0, 1'b0, 32'h8000000c, 32'h00002183, 5'd3);
        nonblock_gpr(1, 1'b1, 32'h80001004, 32'h0241c233, 5'd4);

        // Hart0 x3 is canceled before its data return.
        @(negedge wr_clk); clear_inputs();
        normal_gpr(0, 1'b0, 32'h80000010, 32'h05500293, 5'd5, 32'h55);
        normal_gpr(1, 1'b1, 32'h80001008, 32'h06600313, 5'd6, 32'h66);
        rv_nb_waw_valid[0] = 1'b1;
        rv_nb_waw_victim_hart_id[0] = 1'b0;
        rv_nb_waw_victim_gpr_rd[0] = 5'd3;

        // Hart1 x4 is canceled in exactly the same cycle that div returns.
        @(negedge wr_clk); clear_inputs();
        rv_nb_waw_valid[0] = 1'b1;
        rv_nb_waw_victim_hart_id[0] = 1'b1;
        rv_nb_waw_victim_gpr_rd[0] = 5'd4;
        rv_nb_div_gpr_wen = 1'b1;
        rv_nb_div_gpr_hart_id = 1'b1;
        rv_nb_div_gpr_rd = 5'd4;
        rv_nb_div_gpr_wdata = 32'h4444;

        // Delayed operations that return normally.
        @(negedge wr_clk); clear_inputs();
        nonblock_gpr(0, 1'b0, 32'h80000014, 32'h00002383, 5'd7);
        nonblock_gpr(1, 1'b1, 32'h8000100c, 32'h00002403, 5'd8);
        @(negedge wr_clk); clear_inputs();
        rv_nb_load_gpr_wen = 1'b1;
        rv_nb_load_gpr_hart_id = 1'b0;
        rv_nb_load_gpr_rd = 5'd7;
        rv_nb_load_gpr_wdata = 32'h77;
        @(negedge wr_clk); clear_inputs();
        rv_nb_load_gpr_wen = 1'b1;
        rv_nb_load_gpr_hart_id = 1'b1;
        rv_nb_load_gpr_rd = 5'd8;
        rv_nb_load_gpr_wdata = 32'h88;

        // One CSR event and one no-register event.
        @(negedge wr_clk); clear_inputs();
        rv_commit_valid[0] = 1'b1;
        rv_commit_hart_id[0] = 1'b0;
        rv_commit_pc[0] = 32'h80000018;
        rv_commit_insn[0] = 32'h30041073;
        rv_commit_priv_mode[0] = 2'd3;
        rv_commit_csr_wen[0] = 1'b1;
        rv_commit_csr_addr[0] = 12'h300;
        rv_commit_csr_wdata[0] = 32'h8;
        rv_commit_valid[1] = 1'b1;
        rv_commit_hart_id[1] = 1'b1;
        rv_commit_pc[1] = 32'h80001010;
        rv_commit_insn[1] = 32'h00000063;
        rv_commit_priv_mode[1] = 2'd3;

        @(negedge wr_clk); clear_inputs();
        wait (generated_count[0] == 7 && generated_count[1] == 5 &&
              pending_nonblock_count == '0);
        marker(1'b0);
        marker(1'b1);

        fork
            begin
                wait (&got_result);
            end
            begin
                repeat (5000) @(posedge rd_clk);
                $display("STATE stopped=%b commits=%0d/%0d generated=%0d/%0d pending=%0d/%0d",
                         stopped, commit_count[0], commit_count[1],
                         generated_count[0], generated_count[1],
                         pending_nonblock_count[0], pending_nonblock_count[1]);
                $display("H0B0 busy=%b commit=%0d gen=%0d tail=%b closed=%b occ=%0d",
                         dut.hash_i.fifo_bank_busy[0][0],
                         dut.hash_i.bank_commit_items[0][0],
                         dut.hash_i.bank_generated_items[0][0],
                         dut.hash_i.tail_valid[0][0], dut.hash_i.bank_closed[0][0],
                         fifo_occupancy[0][0]);
                $display("H1B0 busy=%b commit=%0d gen=%0d tail=%b closed=%b occ=%0d",
                         dut.hash_i.fifo_bank_busy[1][0],
                         dut.hash_i.bank_commit_items[1][0],
                         dut.hash_i.bank_generated_items[1][0],
                         dut.hash_i.tail_valid[1][0], dut.hash_i.bank_closed[1][0],
                         fifo_occupancy[1][0]);
                $display("FIFO H0B0 lane_en=%b wr_busy=%b rd_busy=%b wr_cnt=%p rd_cnt=%p empty=%b",
                         dut.g_hart[0].g_bank[0].fifo_i.lane_wr_en,
                         dut.g_hart[0].g_bank[0].fifo_i.lane_wr_rst_busy,
                         dut.g_hart[0].g_bank[0].fifo_i.lane_rd_rst_busy,
                         dut.g_hart[0].g_bank[0].fifo_i.lane_wr_count,
                         dut.g_hart[0].g_bank[0].fifo_i.lane_rd_count,
                         dut.g_hart[0].g_bank[0].fifo_i.lane_empty);
                $fatal(1, "timeout waiting for both package results");
            end
        join_any
        disable fork;

        repeat (20) @(posedge rd_clk);
        if (buffer_conflict || fifo_overflow || bank_conflict) begin
            $error("unexpected conflict flags: buffer=%b fifo=%b bank=%b",
                   buffer_conflict, fifo_overflow, bank_conflict);
            errors = errors + 1;
        end
        if (errors != 0)
            $fatal(1, "smoke test failed with %0d errors", errors);
        $display("SMOKE_PASS hart0_count=%0d hart1_count=%0d", commit_count[0], commit_count[1]);
        $finish;
    end
endmodule
