`timescale 1ns/1ps

module eh2_dual_ddr_pre_tb;
  integer ifu_ar_count = 0;
  integer ifu_r_count = 0;
  integer retire_count = 0;
  integer lsu_ar_count = 0;
  integer lsu_aw_count = 0;
  integer lsu_b_count = 0;
  logic sw3_1 = 1'b0;
  logic sw4_1 = 1'b0;
  logic core_clk_p = 1'b0;
  logic atg_clk_p  = 1'b0;
  logic c0_sys_clk_p = 1'b0;
  logic c1_sys_clk_p = 1'b0;
  wire core_clk_n = ~core_clk_p;
  wire atg_clk_n  = ~atg_clk_p;
  wire c0_sys_clk_n = ~c0_sys_clk_p;
  wire c1_sys_clk_n = ~c1_sys_clk_p;
  wire [7:0] led;

  wire c0_ddr4_act_n;
  wire [16:0] c0_ddr4_adr;
  wire [1:0] c0_ddr4_ba;
  wire [1:0] c0_ddr4_bg;
  wire [0:0] c0_ddr4_cke;
  wire [0:0] c0_ddr4_odt;
  wire [0:0] c0_ddr4_cs_n;
  wire [0:0] c0_ddr4_ck_t;
  wire [0:0] c0_ddr4_ck_c;
  wire c0_ddr4_reset_n;
  wire [8:0] c0_ddr4_dm_dbi_n;
  wire [71:0] c0_ddr4_dq;
  wire [8:0] c0_ddr4_dqs_c;
  wire [8:0] c0_ddr4_dqs_t;

  wire c1_ddr4_act_n;
  wire [16:0] c1_ddr4_adr;
  wire [1:0] c1_ddr4_ba;
  wire [1:0] c1_ddr4_bg;
  wire [0:0] c1_ddr4_cke;
  wire [0:0] c1_ddr4_odt;
  wire [0:0] c1_ddr4_cs_n;
  wire [0:0] c1_ddr4_ck_t;
  wire [0:0] c1_ddr4_ck_c;
  wire c1_ddr4_reset_n;
  wire [8:0] c1_ddr4_dm_dbi_n;
  wire [71:0] c1_ddr4_dq;
  wire [8:0] c1_ddr4_dqs_c;
  wire [8:0] c1_ddr4_dqs_t;

  // User-requested clocking: EH2 50 MHz, ATG management 100 MHz and two
  // independent GCLK3 DDR reference clocks at 76.15 MHz.
  always #10.000 core_clk_p = ~core_clk_p;
  always #5.000  atg_clk_p  = ~atg_clk_p;
  always #6.566  c0_sys_clk_p = ~c0_sys_clk_p;
  always #6.566  c1_sys_clk_p = ~c1_sys_clk_p;

  // Use the production TCM ranges here as well: the real EH2 DMA slave and
  // ECC-generation path must complete all 16384 ordered 64-bit scrub writes
  // before the core is allowed to fetch from external DDR.
  eh2_dual_ddr_top dut (
    .sw3_1, .sw4_1, .core_clk_p, .core_clk_n, .atg_clk_p, .atg_clk_n,
    .led, .c0_sys_clk_p, .c0_sys_clk_n,
    .c0_ddr4_act_n, .c0_ddr4_adr, .c0_ddr4_ba, .c0_ddr4_bg,
    .c0_ddr4_cke, .c0_ddr4_odt, .c0_ddr4_cs_n, .c0_ddr4_ck_t,
    .c0_ddr4_ck_c, .c0_ddr4_reset_n, .c0_ddr4_dm_dbi_n,
    .c0_ddr4_dq, .c0_ddr4_dqs_c, .c0_ddr4_dqs_t,
    .c1_sys_clk_p, .c1_sys_clk_n,
    .c1_ddr4_act_n, .c1_ddr4_adr, .c1_ddr4_ba, .c1_ddr4_bg,
    .c1_ddr4_cke, .c1_ddr4_odt, .c1_ddr4_cs_n, .c1_ddr4_ck_t,
    .c1_ddr4_ck_c, .c1_ddr4_reset_n, .c1_ddr4_dm_dbi_n,
    .c1_ddr4_dq, .c1_ddr4_dqs_c, .c1_ddr4_dqs_t
  );

  initial begin : watchdog
    #5_000_000;
    $fatal(1, "TIMEOUT at 5 ms: led=%b atg_done=%b%b core_rst_l=%b debug=%b mhartstart=%b hw_busy/done/error=%b%b%b counts ifu_ar/r/retire=%0d/%0d/%0d lsu_ar/aw/b=%0d/%0d/%0d mem[10008]=%h mem[1000c]=%h",
           led, dut.atg1_done_latched, dut.atg0_done_latched,
           dut.core_rst_l, dut.eh2_i.debug_mode_status,
           dut.eh2_i.core_i.dec_tlu_mhartstart,
           dut.eh2_hw_init_busy, dut.eh2_hw_init_done, dut.eh2_hw_init_error,
           ifu_ar_count, ifu_r_count, retire_count,
           lsu_ar_count, lsu_aw_count, lsu_b_count,
           dut.ddr1_i.ram_i.mem[1024][95:64],
           dut.ddr1_i.ram_i.mem[1024][127:96]);
  end

  initial begin : stimulus_and_checks
    $display("STAGE %0t: test started", $time);
    #1;
    if (led !== 8'b0000_0000)
      $fatal(1, "LEDs must all be off during board reset: %b", led);
    repeat (20) @(posedge atg_clk_p);
    sw3_1 <= 1'b1;
    sw4_1 <= 1'b1;
    $display("STAGE %0t: board reset released", $time);
    #1;
    if (led !== 8'b0000_0000)
      $fatal(1, "LEDs must remain off immediately after reset release: %b", led);

    wait (led[1:0] === 2'b11);
    $display("STAGE %0t: both ATGs completed, both DDR images read back, and buses handed over", $time);
    repeat (10) @(posedge atg_clk_p);

    if (dut.atg0_resetn !== 1'b0 || dut.atg1_resetn !== 1'b0)
      $fatal(1, "ATG reset was not asserted after initialization completion");
    if (dut.atg0_done_ui_sync[1] !== 1'b1 || dut.atg1_done_ui_sync[1] !== 1'b1)
      $fatal(1, "DDR bus ownership was not handed to EH2");
    if (dut.init0_verify_done !== 1'b1 || dut.init0_verify_pass !== 1'b1 ||
        dut.init0_verify_error !== 1'b0 ||
        dut.init1_verify_done !== 1'b1 || dut.init1_verify_pass !== 1'b1 ||
        dut.init1_verify_error !== 1'b0)
      $fatal(1, "ATG DDR initialization readback did not pass");

    if (dut.ddr0_i.ram_i.mem[0][31:0] !== 32'h0001_0297)
      $fatal(1, "DDR4-1 program load mismatch at address 0");
    if (dut.ddr0_i.ram_i.mem[0][479:448] !== 32'h0007_a803 ||
        dut.ddr0_i.ram_i.mem[0][511:480] !== 32'h00b8_08b3 ||
        dut.ddr0_i.ram_i.mem[1][31:0] !== 32'h0117_a023 ||
        dut.ddr0_i.ram_i.mem[1][63:32] !== 32'h00d7_a023 ||
        dut.ddr0_i.ram_i.mem[1][223:192] !== 32'h00a9_a023)
      $fatal(1, "DDR4-1 AMO-compatible program patch/load mismatch");
    if (dut.ddr1_i.ram_i.mem[1024][31:0] !== 32'd25 ||
        dut.ddr1_i.ram_i.mem[1024][63:32] !== 32'd4 ||
        dut.ddr1_i.ram_i.mem[1024][95:64] !== 32'd100 ||
        dut.ddr1_i.ram_i.mem[1024][127:96] !== 32'd0)
      $fatal(1, "DDR4-2 data initialization mismatch");

    wait (dut.core_rst_l === 1'b1);
    $display("STAGE %0t: EH2 reset released into debug halt", $time);
    wait (dut.eh2_hw_init_done === 1'b1);
    $display("STAGE %0t: EH2 DCCM/ICCM DMA scrub completed", $time);
    if (dut.eh2_hw_init_error !== 1'b0)
      $fatal(1, "EH2 DCCM/ICCM hardware initialization failed");
    wait (led[7] === 1'b1);
    $display("STAGE %0t: DDR4-2 terminal result accepted", $time);
    repeat (20) @(posedge core_clk_p);

    if (led !== 8'b1111_1111)
      $fatal(1, "Unexpected LED result: %b", led);
    if (dut.ddr1_i.ram_i.mem[1024][127:96] !== 32'h0000_01bc)
      $fatal(1, "EH2 final DDR4-2 result mismatch: %h",
             dut.ddr1_i.ram_i.mem[1024][127:96]);
    // The original AMOSWAP source is a3. Instruction 0x028346b3 is DIV,
    // therefore a3 = 25 / 4 = 6 and the final word at 0x10008 must be 6.
    if (dut.ddr1_i.ram_i.mem[1024][95:64] !== 32'd6)
      $fatal(1, "DDR-compatible replacement mismatch at 0x10008: %h",
             dut.ddr1_i.ram_i.mem[1024][95:64]);

    // Prove that the initializers cannot regain the buses after handover.
    repeat (100) begin
      @(posedge atg_clk_p);
      if (dut.atg0_resetn !== 1'b0 || dut.atg1_resetn !== 1'b0 ||
          dut.atg0_done_latched !== 1'b1 || dut.atg1_done_latched !== 1'b1)
        $fatal(1, "One-shot ATG state changed after permanent handover");
    end

    $display("PASS: dual ATG write/readback, permanent EH2 handover, 50 MHz execution, DDR4-2 result 0x000001BC, LED=11111111");
    $finish;
  end

  // Halt-on-reset must prevent any instruction fetch until the synthesizable
  // DCCM/ICCM ECC scrub has completed and the hardware run request is acked.
  always @(posedge core_clk_p) begin
    if (dut.core_rst_l && !dut.eh2_hw_init_done && dut.ifu_axi.arvalid)
      $fatal(1, "EH2 issued an IFU request before hardware initialization completed");

    if (dut.ifu_axi.arvalid && dut.ifu_axi.arready) begin
      ifu_ar_count <= ifu_ar_count + 1;
      if (ifu_ar_count < 8)
        $display("IFU_AR %0t: id=%h addr=%h len=%0d size=%0d", $time,
                 dut.ifu_axi.arid, dut.ifu_axi.araddr,
                 dut.ifu_axi.arlen, dut.ifu_axi.arsize);
    end
    if (dut.ifu_axi.rvalid && dut.ifu_axi.rready) begin
      ifu_r_count <= ifu_r_count + 1;
      if (ifu_r_count < 8)
        $display("IFU_R  %0t: id=%h data=%h resp=%b last=%b", $time,
                 dut.ifu_axi.rid, dut.ifu_axi.rdata,
                 dut.ifu_axi.rresp, dut.ifu_axi.rlast);
    end
    if (|dut.eh2_i.core_i.trace_rv_i_valid_ip) begin
      retire_count <= retire_count + 1;
      if ((retire_count < 32) ||
          (|dut.eh2_i.core_i.trace_rv_i_exception_ip))
        $display("RETIRE %0t: valid=%b pc=%h insn=%h exc=%b cause=%h", $time,
                 dut.eh2_i.core_i.trace_rv_i_valid_ip,
                 dut.eh2_i.core_i.trace_rv_i_address_ip,
                 dut.eh2_i.core_i.trace_rv_i_insn_ip,
                 dut.eh2_i.core_i.trace_rv_i_exception_ip,
                 dut.eh2_i.core_i.trace_rv_i_ecause_ip);
    end
    if (dut.lsu_axi.arvalid && dut.lsu_axi.arready) begin
      lsu_ar_count <= lsu_ar_count + 1;
      if (lsu_ar_count < 8)
        $display("LSU_AR %0t: addr=%h len=%0d size=%0d", $time,
                 dut.lsu_axi.araddr, dut.lsu_axi.arlen, dut.lsu_axi.arsize);
    end
    if (dut.lsu_axi.awvalid && dut.lsu_axi.awready) begin
      lsu_aw_count <= lsu_aw_count + 1;
      if (lsu_aw_count < 8)
        $display("LSU_AW %0t: addr=%h len=%0d size=%0d", $time,
                 dut.lsu_axi.awaddr, dut.lsu_axi.awlen, dut.lsu_axi.awsize);
    end
    if (dut.lsu_axi.bvalid && dut.lsu_axi.bready) begin
      lsu_b_count <= lsu_b_count + 1;
      if (lsu_b_count < 16)
        $display("LSU_B  %0t: id=%h resp=%b", $time,
                 dut.lsu_axi.bid, dut.lsu_axi.bresp);
    end
  end
endmodule
