// Cycle-accurate differential regression for the split capture hierarchy.
module capture_diff_adapter #(
    parameter bit USE_REFERENCE = 1'b0
) (
    input  logic clk,
    input  logic rst_l,
    input  logic [1:0] rv_commit_valid,
    input  logic [1:0][31:0] rv_commit_insn,
    input  logic [1:0][31:0] rv_commit_pc,
    input  logic [1:0] rv_commit_hart_id,
    input  logic [1:0][1:0] rv_commit_priv_mode,
    input  logic [1:0] rv_commit_gpr_wen_intent,
    input  logic [1:0] rv_commit_gpr_wen,
    input  logic [1:0][4:0] rv_commit_gpr_rd,
    input  logic [1:0][31:0] rv_commit_gpr_wdata,
    input  logic [1:0] rv_commit_csr_wen,
    input  logic [1:0][11:0] rv_commit_csr_addr,
    input  logic [1:0][31:0] rv_commit_csr_wdata,
    input  logic [1:0] rv_commit_is_nonblock,
    input  logic [1:0] rv_commit_is_nonblock_load,
    input  logic [1:0] rv_commit_is_nonblock_div,
    input  logic [1:0] rv_commit_waw_victim,
    input  logic [1:0] rv_nb_waw_valid,
    input  logic [1:0] rv_nb_waw_victim_hart_id,
    input  logic [1:0][4:0] rv_nb_waw_victim_gpr_rd,
    input  logic [1:0] rv_nb_waw_victim_is_load,
    input  logic [1:0] rv_nb_waw_victim_is_div,
    input  logic rv_nb_load_gpr_wen,
    input  logic rv_nb_load_gpr_hart_id,
    input  logic [4:0] rv_nb_load_gpr_rd,
    input  logic [31:0] rv_nb_load_gpr_wdata,
    input  logic rv_nb_div_gpr_wen,
    input  logic rv_nb_div_gpr_hart_id,
    input  logic [4:0] rv_nb_div_gpr_rd,
    input  logic [31:0] rv_nb_div_gpr_wdata,
    input  logic lsu_axi_awvalid,
    input  logic lsu_axi_awready,
    input  logic [3:0] lsu_axi_awid,
    input  logic [31:0] lsu_axi_awaddr,
    input  logic lsu_axi_wvalid,
    input  logic lsu_axi_wready,
    input  logic [63:0] lsu_axi_wdata,
    input  logic [7:0] lsu_axi_wstrb,
    input  logic [1:0][3:0] record_ready,
    output logic [2268:0] signature
);
  logic [1:0][3:0] record_valid;
  logic [1:0][3:0][255:0] record_data;
  logic [1:0] stopped;
  logic [1:0][31:0] next_sequence;
  logic [1:0][31:0] commit_count;
  logic [1:0][31:0] generated_count;
  logic [1:0][5:0] pending_nonblock_count;
  logic capture_done;
  logic [1:0] nonblock_conflict_hart;
  logic [1:0] record_overflow_hart;
  logic [1:0] waw_cause_error_hart;

  generate
    if (USE_REFERENCE) begin : g_reference
      instr_info_capture_dual_reference dut (.*);
    end else begin : g_production
      instr_info_capture_dual dut (.*);
    end
  endgenerate

  always_comb
    signature = {record_valid,record_data,stopped,next_sequence,
                 commit_count,generated_count,pending_nonblock_count,
                 capture_done,nonblock_conflict_hart,
                 record_overflow_hart,waw_cause_error_hart};
endmodule

module tb_instr_info_capture_differential;
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
  logic [1:0] rv_nb_waw_victim_is_load, rv_nb_waw_victim_is_div;
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
  logic [1:0][3:0] record_ready;
  logic [2268:0] ref_signature, new_signature;

  capture_diff_adapter #(.USE_REFERENCE(1'b1)) ref_i (
    .signature(ref_signature), .*
  );
  capture_diff_adapter #(.USE_REFERENCE(1'b0)) new_i (
    .signature(new_signature), .*
  );

  int cycle;
  int seed;
  int dummy;

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
      rv_nb_waw_victim_is_load = '0;
      rv_nb_waw_victim_is_div = '0;
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
      record_ready = '1;
    end
  endtask

  task automatic check_equal;
    if (ref_signature !== new_signature)
      $fatal(1, "split/reference mismatch at cycle %0d", cycle);
  endtask

  initial begin
    seed = 32'h3205_2525;
    dummy = $urandom(seed);
    clear_inputs();
    repeat (8) @(posedge clk);
    @(negedge clk);
    rst_l = 1'b1;

    for (cycle = 0; cycle < 50000; cycle++) begin
      @(negedge clk);
      check_equal();
      clear_inputs();
      record_ready[0] = {$urandom_range(0,1),$urandom_range(0,1),
                         $urandom_range(0,1),1'b1};
      record_ready[1] = {$urandom_range(0,1),$urandom_range(0,1),
                         $urandom_range(0,1),1'b1};

      for (int lane = 0; lane < 2; lane++) begin
        rv_commit_valid[lane] = $urandom_range(0,99) < 72;
        rv_commit_hart_id[lane] = $urandom_range(0,1);
        rv_commit_pc[lane] = 32'h8000_0000 + cycle*8 + lane*4;
        rv_commit_insn[lane] = $urandom;
        rv_commit_priv_mode[lane] = $urandom_range(0,3);
        rv_commit_gpr_rd[lane] = $urandom_range(0,31);
        rv_commit_gpr_wen_intent[lane] = $urandom_range(0,99) < 65;
        rv_commit_gpr_wen[lane] = rv_commit_gpr_wen_intent[lane] &&
                                  ($urandom_range(0,99) < 65);
        rv_commit_gpr_wdata[lane] = $urandom;
        rv_commit_csr_wen[lane] = $urandom_range(0,99) < 8;
        rv_commit_csr_addr[lane] = $urandom_range(0,4095);
        rv_commit_csr_wdata[lane] = $urandom;
        rv_commit_is_nonblock[lane] = $urandom_range(0,99) < 38;
        rv_commit_is_nonblock_load[lane] =
          rv_commit_is_nonblock[lane] && ($urandom_range(0,1) == 0);
        rv_commit_is_nonblock_div[lane] =
          rv_commit_is_nonblock[lane] && !rv_commit_is_nonblock_load[lane];
      end

      if (($urandom_range(0,99) < 12) && rv_commit_valid[0] &&
          rv_commit_valid[1]) begin
        rv_commit_hart_id[1] = rv_commit_hart_id[0];
        rv_commit_gpr_rd[1] = rv_commit_gpr_rd[0];
        rv_commit_waw_victim[0] = rv_commit_gpr_rd[0] != 0;
      end

      rv_nb_load_gpr_wen = $urandom_range(0,99) < 28;
      rv_nb_load_gpr_hart_id = $urandom_range(0,1);
      rv_nb_load_gpr_rd = $urandom_range(1,31);
      rv_nb_load_gpr_wdata = $urandom;
      rv_nb_div_gpr_wen = $urandom_range(0,99) < 20;
      rv_nb_div_gpr_hart_id = $urandom_range(0,1);
      rv_nb_div_gpr_rd = $urandom_range(1,31);
      rv_nb_div_gpr_wdata = $urandom;

      for (int lane = 0; lane < 2; lane++) begin
        rv_nb_waw_valid[lane] = $urandom_range(0,99) < 14;
        rv_nb_waw_victim_hart_id[lane] = $urandom_range(0,1);
        rv_nb_waw_victim_gpr_rd[lane] = $urandom_range(1,31);
        rv_nb_waw_victim_is_load[lane] = $urandom_range(0,1);
        rv_nb_waw_victim_is_div[lane] =
          !rv_nb_waw_victim_is_load[lane];
      end

      if (cycle == 48000) begin
        clear_inputs();
        lsu_axi_awvalid = 1'b1;
        lsu_axi_awid[3] = 1'b0;
        lsu_axi_awaddr = 32'hD058_0000;
      end
      if (cycle == 48003) begin
        clear_inputs();
        lsu_axi_wvalid = 1'b1;
        lsu_axi_wdata = 64'h0000_0000_0032_0525;
        lsu_axi_wstrb = 8'h0f;
      end
      if (cycle == 48500) begin
        clear_inputs();
        lsu_axi_wvalid = 1'b1;
        lsu_axi_wdata = 64'h0000_0000_0032_0525;
        lsu_axi_wstrb = 8'h0f;
      end
      if (cycle == 48502) begin
        clear_inputs();
        lsu_axi_awvalid = 1'b1;
        lsu_axi_awid[3] = 1'b1;
        lsu_axi_awaddr = 32'hD058_0000;
      end
    end
    @(negedge clk);
    check_equal();
    $display("TB_PASS: split capture matches reference for 50000 cycles");
    $finish;
  end
endmodule
