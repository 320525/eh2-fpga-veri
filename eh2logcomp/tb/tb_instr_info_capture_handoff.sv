`timescale 1ns/1ps

// Legal same-rd nonblocking lifetimes must hand off without reporting the
// single per-rd holding entry as an overflow.  This regression covers an old
// result already resolved, an old result returning in the allocation cycle,
// and a WAW cancellation arriving after resolution but before emission.
module tb_instr_info_capture_handoff;
  logic clk = 1'b0;
  logic rst_l = 1'b0;
  always #10 clk = ~clk;

  logic [1:0] cv, ch, gi, gw, cw, isnb, isload, isdiv, direct_waw;
  logic [1:0][31:0] insn, pc, gdata, cdata;
  logic [1:0][1:0] priv;
  logic [1:0][4:0] rd;
  logic [1:0][11:0] ca;
  logic [1:0] nbw, nbwh, nbwl, nbwd;
  logic [1:0][4:0] nbwrd;
  logic nbl, nblh;
  logic [4:0] nblrd;
  logic [31:0] nbld;
  logic nbd, nbdh;
  logic [4:0] nbdrd;
  logic [31:0] nbdd;
  logic [1:0][3:0] ov, ready;
  logic [1:0][3:0][255:0] od;
  logic [1:0] stopped, nbconf, overflow, wawerr;
  logic [1:0][31:0] nextseq, cc, gc;
  logic [1:0][5:0] pending;
  logic capture_done;

  instr_info_capture_dual dut (
    .clk, .rst_l, .rv_commit_valid(cv), .rv_commit_insn(insn),
    .rv_commit_pc(pc), .rv_commit_hart_id(ch),
    .rv_commit_priv_mode(priv), .rv_commit_gpr_wen_intent(gi),
    .rv_commit_gpr_wen(gw), .rv_commit_gpr_rd(rd),
    .rv_commit_gpr_wdata(gdata), .rv_commit_csr_wen(cw),
    .rv_commit_csr_addr(ca), .rv_commit_csr_wdata(cdata),
    .rv_commit_is_nonblock(isnb), .rv_commit_is_nonblock_load(isload),
    .rv_commit_is_nonblock_div(isdiv), .rv_commit_waw_victim(direct_waw),
    .rv_nb_waw_valid(nbw), .rv_nb_waw_victim_hart_id(nbwh),
    .rv_nb_waw_victim_gpr_rd(nbwrd), .rv_nb_waw_victim_is_load(nbwl),
    .rv_nb_waw_victim_is_div(nbwd), .rv_nb_load_gpr_wen(nbl),
    .rv_nb_load_gpr_hart_id(nblh), .rv_nb_load_gpr_rd(nblrd),
    .rv_nb_load_gpr_wdata(nbld), .rv_nb_div_gpr_wen(nbd),
    .rv_nb_div_gpr_hart_id(nbdh), .rv_nb_div_gpr_rd(nbdrd),
    .rv_nb_div_gpr_wdata(nbdd), .lsu_axi_awvalid(1'b0),
    .lsu_axi_awready(1'b0), .lsu_axi_awid('0), .lsu_axi_awaddr('0),
    .lsu_axi_wvalid(1'b0), .lsu_axi_wready(1'b0), .lsu_axi_wdata('0),
    .lsu_axi_wstrb('0), .record_valid(ov), .record_data(od),
    .record_ready(ready), .stopped, .next_sequence(nextseq),
    .commit_count(cc), .generated_count(gc),
    .pending_nonblock_count(pending), .capture_done,
    .nonblock_conflict_hart(nbconf), .record_overflow_hart(overflow),
    .waw_cause_error_hart(wawerr)
  );

  task automatic clear_inputs;
    begin
      cv='0; ch='0; insn='0; pc='0; priv='{default:2'b11};
      gi='0; gw='0; rd='0; gdata='0; cw='0; ca='0; cdata='0;
      isnb='0; isload='0; isdiv='0; direct_waw='0;
      nbw='0; nbwh='0; nbwrd='0; nbwl='0; nbwd='0;
      nbl=1'b0; nblh=1'b0; nblrd='0; nbld='0;
      nbd=1'b0; nbdh=1'b0; nbdrd='0; nbdd='0;
    end
  endtask

  task automatic commit_nb(input logic [4:0] target_rd,
                           input logic load_kind,
                           input logic [31:0] instruction);
    begin
      clear_inputs();
      cv[0]=1'b1; gi[0]=1'b1; isnb[0]=1'b1;
      isload[0]=load_kind; isdiv[0]=!load_kind;
      rd[0]=target_rd; insn[0]=instruction;
    end
  endtask

  task automatic require_record(input logic [31:0] expected_sequence,
                                input logic [31:0] result,
                                input logic [1:0] cancel_kind);
    begin
      #1;
      if (!ov[0][0] || od[0][0][255:224] != expected_sequence ||
          od[0][0][127:96] != result ||
          od[0][0][159:158] != cancel_kind)
        $fatal(1, "record mismatch valid=%b seq=%0d data=%h kind=%0d",
               ov[0][0], od[0][0][255:224], od[0][0][127:96],
               od[0][0][159:158]);
    end
  endtask

  initial begin
    ready = '1;
    clear_inputs();
    repeat (3) @(posedge clk);
    rst_l = 1'b1;

    // seq0 load resolves, then seq1 div takes the same rd while the resolved
    // record is transferred into the emit holding register.
    @(negedge clk); commit_nb(5, 1'b1, 32'h0000_2003);
    @(posedge clk);
    @(negedge clk); clear_inputs(); nbl=1'b1; nblrd=5; nbld=32'h1111_0000;
    @(posedge clk);
    @(negedge clk); commit_nb(5, 1'b0, 32'h0200_4033);
    @(posedge clk);
    @(negedge clk); clear_inputs(); require_record(0, 32'h1111_0000, 2'b00);
    if (nbconf != 0) $fatal(1, "resolved handoff raised conflict");
    @(posedge clk);

    // Complete seq1 so its record also proves that the younger owner was not
    // overwritten while seq0 was emitted.
    @(negedge clk); clear_inputs(); nbd=1'b1; nbdrd=5; nbdd=32'h2222_0000;
    @(posedge clk);
    @(negedge clk); clear_inputs();
    @(posedge clk);
    @(negedge clk); clear_inputs(); require_record(1, 32'h2222_0000, 2'b00);
    @(posedge clk);

    // seq2 load returns in the exact cycle seq3 div claims rd6.
    @(negedge clk); commit_nb(6, 1'b1, 32'h0000_2103);
    @(posedge clk);
    @(negedge clk); commit_nb(6, 1'b0, 32'h0200_4133);
    nbl=1'b1; nblrd=6; nbld=32'h3333_0000;
    @(posedge clk);
    @(negedge clk); clear_inputs(); require_record(2, 32'h3333_0000, 2'b00);
    if (nbconf != 0) $fatal(1, "same-cycle return handoff raised conflict");
    @(posedge clk);

    // Resolve seq3, then cancel it after nb_resolved is already set.  The
    // cancellation must replace the result, not emit stale architectural data.
    @(negedge clk); clear_inputs(); nbd=1'b1; nbdrd=6; nbdd=32'h4444_0000;
    @(posedge clk);
    @(negedge clk); clear_inputs();
    cv[0]=1'b1; gi[0]=1'b1; gw[0]=1'b1; rd[0]=6; insn[0]=32'h0000_0313;
    nbw[0]=1'b1; nbwrd[0]=6; nbwd[0]=1'b1;
    // The direct cancelling instruction is visible in its commit cycle.
    require_record(4, 32'b0, 2'b00);
    @(posedge clk);
    @(negedge clk); clear_inputs();
    @(posedge clk);
    @(negedge clk); clear_inputs();
    require_record(3, 32'b0, 2'b11);
    if (od[0][0][95:64] != 4)
      $fatal(1, "late WAW cancel number=%0d expected=4", od[0][0][95:64]);
    if (nbconf != 0 || overflow != 0 || wawerr != 0)
      $fatal(1, "unexpected errors nb=%b overflow=%b waw=%b",
             nbconf, overflow, wawerr);

    $display("TB_PASS: nonblock same-rd atomic handoff and late WAW cancel");
    $finish;
  end

  initial begin
    repeat (200) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
