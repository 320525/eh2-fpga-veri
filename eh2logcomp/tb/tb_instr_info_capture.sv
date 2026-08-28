`timescale 1ns/1ps
module tb_instr_info_capture;
  logic clk=0,rst_l=0;
  logic [1:0] cv,ch,priv0;
  logic [1:0][31:0] insn,pc,gdata,cdata;
  logic [1:0][1:0] priv;
  logic [1:0] gi,gw,cw,isnb,isload,isdiv,direct_waw;
  logic [1:0][4:0] rd;
  logic [1:0][11:0] ca;
  logic [1:0] nbw,nbwh,nbwl,nbwd;
  logic [1:0][4:0] nbwrd;
  logic nbl,nblh; logic [4:0] nblrd; logic [31:0] nbld;
  logic nbd,nbdh; logic [4:0] nbdrd; logic [31:0] nbdd;
  logic [1:0][3:0] ov,ready='1;
  logic [1:0][3:0][255:0] od;
  logic [1:0] stopped,nbconf,overflow,wawerr;
  logic [1:0][31:0] nextseq,cc,gc;
  logic [1:0][5:0] pending;
  logic capture_done;
  always #10 clk=~clk;

  instr_info_capture_dual dut(
    .clk,.rst_l,.rv_commit_valid(cv),.rv_commit_insn(insn),.rv_commit_pc(pc),
    .rv_commit_hart_id(ch),.rv_commit_priv_mode(priv),
    .rv_commit_gpr_wen_intent(gi),.rv_commit_gpr_wen(gw),
    .rv_commit_gpr_rd(rd),.rv_commit_gpr_wdata(gdata),
    .rv_commit_csr_wen(cw),.rv_commit_csr_addr(ca),.rv_commit_csr_wdata(cdata),
    .rv_commit_is_nonblock(isnb),.rv_commit_is_nonblock_load(isload),
    .rv_commit_is_nonblock_div(isdiv),.rv_commit_waw_victim(direct_waw),
    .rv_nb_waw_valid(nbw),.rv_nb_waw_victim_hart_id(nbwh),
    .rv_nb_waw_victim_gpr_rd(nbwrd),.rv_nb_waw_victim_is_load(nbwl),
    .rv_nb_waw_victim_is_div(nbwd),.rv_nb_load_gpr_wen(nbl),
    .rv_nb_load_gpr_hart_id(nblh),.rv_nb_load_gpr_rd(nblrd),
    .rv_nb_load_gpr_wdata(nbld),.rv_nb_div_gpr_wen(nbd),
    .rv_nb_div_gpr_hart_id(nbdh),.rv_nb_div_gpr_rd(nbdrd),
    .rv_nb_div_gpr_wdata(nbdd),.lsu_axi_awvalid(1'b0),.lsu_axi_awready(1'b0),
    .lsu_axi_awid('0),.lsu_axi_awaddr('0),.lsu_axi_wvalid(1'b0),
    .lsu_axi_wready(1'b0),.lsu_axi_wdata('0),.lsu_axi_wstrb('0),
    .record_valid(ov),.record_data(od),.record_ready(ready),.stopped,
    .next_sequence(nextseq),.commit_count(cc),.generated_count(gc),
    .pending_nonblock_count(pending),.capture_done,
    .nonblock_conflict_hart(nbconf),.record_overflow_hart(overflow),
    .waw_cause_error_hart(wawerr));

  task clear_inputs;
    begin cv=0;ch=0;insn=0;pc=0;priv='{default:2'b11};gi=0;gw=0;rd=0;
      gdata=0;cw=0;ca=0;cdata=0;isnb=0;isload=0;isdiv=0;direct_waw=0;
      nbw=0;nbwh=0;nbwrd=0;nbwl=0;nbwd=0;nbl=0;nblh=0;nblrd=0;nbld=0;
      nbd=0;nbdh=0;nbdrd=0;nbdd=0; end
  endtask

  initial begin
    clear_inputs(); repeat(3) @(posedge clk); rst_l=1;
    // Hart0 lane0 sequence 0 is killed by younger lane1 sequence 1.
    @(negedge clk); cv=2'b11; ch=2'b00; gi=2'b11; gw=2'b10;
    rd[0]=5; rd[1]=5; pc[0]=32'h100; pc[1]=32'h104;
    insn[0]=32'h111; insn[1]=32'h222; gdata[1]=32'h55;
    direct_waw=2'b01;
    #1;
    if (ov[0][1:0] != 2'b11) $fatal(1,"missing direct records");
    if (od[0][0][255:224] != 0 || od[0][0][159:158] != 2'b01 ||
        od[0][0][95:64] != 1) $fatal(1,"direct WAW fields wrong");
    if (od[0][1][255:224] != 1) $fatal(1,"younger sequence wrong");
    @(posedge clk);

    // Same cycle demonstrates independent per-hart counters.
    @(negedge clk); clear_inputs(); cv=2'b11; ch=2'b10; gw=2'b11;gi=2'b11;
    rd[0]=6;rd[1]=6;
    #1;
    if (od[0][0][255:224] != 2 || od[1][0][255:224] != 0)
      $fatal(1,"per-hart sequences not independent");
    @(posedge clk);

    // Hart1 deferred load sequence1, then sequence2 cancels it.
    @(negedge clk); clear_inputs(); cv=2'b01; ch=2'b01; gi=2'b01;
    rd[0]=7;isnb=2'b01;isload=2'b01;
    #1;
    if (ov != 0) $fatal(1,"unresolved NB emitted early");
    @(posedge clk);
    @(negedge clk); clear_inputs(); cv=2'b01;ch=2'b01;gi=2'b01;gw=2'b01;
    rd[0]=7;nbw=2'b01;nbwh=2'b01;nbwrd[0]=7;nbwl=2'b01;
    #1;
    if (!ov[1][0] || od[1][0][255:224] != 2) $fatal(1,"canceller missing");
    @(posedge clk); @(negedge clk); clear_inputs();
    repeat(2) begin @(posedge clk); #1;
      if (ov[1][0] && od[1][0][255:224] == 1) begin
        if (od[1][0][159:158] != 2'b10 || od[1][0][95:64] != 2 ||
            od[1][0][127:96] != 0) $fatal(1,"NB WAW fields wrong");
        if (wawerr != 0 || nbconf != 0 || overflow != 0) $fatal(1,"unexpected error");
        $display("PASS tb_instr_info_capture h0next=%0d h1next=%0d",nextseq[0],nextseq[1]);
        $finish;
      end
    end
    $fatal(1,"NB victim not emitted");
  end
  initial begin repeat(200) @(posedge clk); $fatal(1,"timeout"); end
endmodule
