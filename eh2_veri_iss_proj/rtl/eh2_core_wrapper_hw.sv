`timescale 1ns/1ps

module eh2_core_wrapper_hw #(
  parameter logic [31:0] HW_INIT_DCCM_LAST = 32'hf004_fff8,
  parameter logic [31:0] HW_INIT_ICCM_LAST = 32'hee00_fff8
) (
  input  logic   clk,
  input  logic   rst_l,
  input  logic   dbg_rst_l,
  output logic   hw_init_busy,
  output logic   hw_init_done,
  output logic   hw_init_error,
  output logic   any_lsu_write_seen,
  output logic   terminal_write_complete,
  output logic   terminal_write_error,
  axi4_if.master ifu_axi,
  axi4_if.master lsu_axi
);
  logic       terminal_resp_pending;
  logic [3:0] last_awid;
  logic [31:0] last_awaddr;
  logic [3:0] terminal_bid;

  logic       dma_axi_awvalid;
  logic       dma_axi_awready;
  logic [0:0] dma_axi_awid;
  logic [31:0] dma_axi_awaddr;
  logic [2:0] dma_axi_awsize;
  logic [2:0] dma_axi_awprot;
  logic [7:0] dma_axi_awlen;
  logic [1:0] dma_axi_awburst;
  logic       dma_axi_wvalid;
  logic       dma_axi_wready;
  logic [63:0] dma_axi_wdata;
  logic [7:0] dma_axi_wstrb;
  logic       dma_axi_wlast;
  logic       dma_axi_bvalid;
  logic       dma_axi_bready;
  logic [1:0] dma_axi_bresp;
  logic [0:0] dma_axi_bid;
  logic       hw_run_req;
  logic       hw_run_ack;
  logic       debug_mode_status;

  eh2_hw_init #(
    .DCCM_LAST(HW_INIT_DCCM_LAST), .ICCM_LAST(HW_INIT_ICCM_LAST)
  ) hw_init_i (
    .clk(clk), .resetn(rst_l), .debug_halted(debug_mode_status),
    .run_ack(hw_run_ack), .run_req(hw_run_req),
    .init_busy(hw_init_busy), .init_done(hw_init_done),
    .init_error(hw_init_error),
    .dma_awvalid(dma_axi_awvalid), .dma_awready(dma_axi_awready),
    .dma_awid(dma_axi_awid), .dma_awaddr(dma_axi_awaddr),
    .dma_awsize(dma_axi_awsize), .dma_awprot(dma_axi_awprot),
    .dma_awlen(dma_axi_awlen), .dma_awburst(dma_axi_awburst),
    .dma_wvalid(dma_axi_wvalid), .dma_wready(dma_axi_wready),
    .dma_wdata(dma_axi_wdata), .dma_wstrb(dma_axi_wstrb),
    .dma_wlast(dma_axi_wlast), .dma_bvalid(dma_axi_bvalid),
    .dma_bready(dma_axi_bready), .dma_bresp(dma_axi_bresp),
    .dma_bid(dma_axi_bid)
  );

  wire lsu_aw_hs = lsu_axi.awvalid && lsu_axi.awready;
  wire terminal_w_hs = lsu_axi.wvalid && lsu_axi.wready &&
    lsu_axi.wlast && (lsu_axi.wstrb[7:4] == 4'hf) &&
    (lsu_axi.wdata[63:32] == 32'h0000_01bc) &&
    (((lsu_aw_hs ? lsu_axi.awaddr[31:0] : last_awaddr) & 32'hffff_fff8) ==
     32'h0001_0008);

  always_ff @(posedge clk) begin
    if (!rst_l) begin
      any_lsu_write_seen     <= 1'b0;
      terminal_write_complete <= 1'b0;
      terminal_write_error  <= 1'b0;
      terminal_resp_pending  <= 1'b0;
      last_awid              <= 4'd0;
      last_awaddr            <= 32'd0;
      terminal_bid           <= 4'd0;
    end else begin
      if (lsu_aw_hs) begin
        any_lsu_write_seen <= 1'b1;
        last_awid   <= lsu_axi.awid;
        last_awaddr <= lsu_axi.awaddr[31:0];
      end

      // EH2 aligns a 32-bit store at 0x1000c to the 64-bit AXI address
      // 0x10008 and selects the upper word with WSTRB[7:4]. Detect that data
      // beat, then wait for its tagged write response. The independent DDR
      // checker still reads the memory back before declaring success.
      if (terminal_w_hs) begin
        terminal_resp_pending <= 1'b1;
        terminal_bid <= lsu_aw_hs ? lsu_axi.awid : last_awid;
      end

      if (terminal_resp_pending && lsu_axi.bvalid && lsu_axi.bready &&
          (lsu_axi.bid == terminal_bid)) begin
        terminal_write_complete <= (lsu_axi.bresp == 2'b00);
        terminal_write_error <= (lsu_axi.bresp != 2'b00);
        terminal_resp_pending <= 1'b0;
      end
    end
  end

  assign ifu_axi.awaddr[32] = 1'b0;
  assign ifu_axi.araddr[32] = 1'b0;
  assign lsu_axi.awaddr[32] = 1'b0;
  assign lsu_axi.araddr[32] = 1'b0;

  eh2_veer_wrapper core_i (
    .rst_l(rst_l),
    .dbg_rst_l(dbg_rst_l),
    .clk(clk),
    .rst_vec(31'd0),
    .nmi_int(1'b0),
    .nmi_vec(31'h7700_0000),
    .jtag_id({4'b0001, 16'd0, 11'h045}),

    .trace_rv_i_insn_ip(),
    .trace_rv_i_address_ip(),
    .trace_rv_i_valid_ip(),
    .trace_rv_i_exception_ip(),
    .trace_rv_i_ecause_ip(),
    .trace_rv_i_interrupt_ip(),
    .trace_rv_i_tval_ip(),

    .lsu_axi_awvalid(lsu_axi.awvalid),
    .lsu_axi_awready(lsu_axi.awready),
    .lsu_axi_awid(lsu_axi.awid),
    .lsu_axi_awaddr(lsu_axi.awaddr[31:0]),
    .lsu_axi_awregion(lsu_axi.awregion),
    .lsu_axi_awlen(lsu_axi.awlen),
    .lsu_axi_awsize(lsu_axi.awsize),
    .lsu_axi_awburst(lsu_axi.awburst),
    .lsu_axi_awlock(lsu_axi.awlock),
    .lsu_axi_awcache(lsu_axi.awcache),
    .lsu_axi_awprot(lsu_axi.awprot),
    .lsu_axi_awqos(lsu_axi.awqos),
    .lsu_axi_wvalid(lsu_axi.wvalid),
    .lsu_axi_wready(lsu_axi.wready),
    .lsu_axi_wdata(lsu_axi.wdata),
    .lsu_axi_wstrb(lsu_axi.wstrb),
    .lsu_axi_wlast(lsu_axi.wlast),
    .lsu_axi_bvalid(lsu_axi.bvalid),
    .lsu_axi_bready(lsu_axi.bready),
    .lsu_axi_bresp(lsu_axi.bresp),
    .lsu_axi_bid(lsu_axi.bid),
    .lsu_axi_arvalid(lsu_axi.arvalid),
    .lsu_axi_arready(lsu_axi.arready),
    .lsu_axi_arid(lsu_axi.arid),
    .lsu_axi_araddr(lsu_axi.araddr[31:0]),
    .lsu_axi_arregion(lsu_axi.arregion),
    .lsu_axi_arlen(lsu_axi.arlen),
    .lsu_axi_arsize(lsu_axi.arsize),
    .lsu_axi_arburst(lsu_axi.arburst),
    .lsu_axi_arlock(lsu_axi.arlock),
    .lsu_axi_arcache(lsu_axi.arcache),
    .lsu_axi_arprot(lsu_axi.arprot),
    .lsu_axi_arqos(lsu_axi.arqos),
    .lsu_axi_rvalid(lsu_axi.rvalid),
    .lsu_axi_rready(lsu_axi.rready),
    .lsu_axi_rid(lsu_axi.rid),
    .lsu_axi_rdata(lsu_axi.rdata),
    .lsu_axi_rresp(lsu_axi.rresp),
    .lsu_axi_rlast(lsu_axi.rlast),

    .ifu_axi_awvalid(ifu_axi.awvalid),
    .ifu_axi_awready(ifu_axi.awready),
    .ifu_axi_awid(ifu_axi.awid),
    .ifu_axi_awaddr(ifu_axi.awaddr[31:0]),
    .ifu_axi_awregion(ifu_axi.awregion),
    .ifu_axi_awlen(ifu_axi.awlen),
    .ifu_axi_awsize(ifu_axi.awsize),
    .ifu_axi_awburst(ifu_axi.awburst),
    .ifu_axi_awlock(ifu_axi.awlock),
    .ifu_axi_awcache(ifu_axi.awcache),
    .ifu_axi_awprot(ifu_axi.awprot),
    .ifu_axi_awqos(ifu_axi.awqos),
    .ifu_axi_wvalid(ifu_axi.wvalid),
    .ifu_axi_wready(ifu_axi.wready),
    .ifu_axi_wdata(ifu_axi.wdata),
    .ifu_axi_wstrb(ifu_axi.wstrb),
    .ifu_axi_wlast(ifu_axi.wlast),
    .ifu_axi_bvalid(ifu_axi.bvalid),
    .ifu_axi_bready(ifu_axi.bready),
    .ifu_axi_bresp(ifu_axi.bresp),
    .ifu_axi_bid(ifu_axi.bid),
    .ifu_axi_arvalid(ifu_axi.arvalid),
    .ifu_axi_arready(ifu_axi.arready),
    .ifu_axi_arid(ifu_axi.arid),
    .ifu_axi_araddr(ifu_axi.araddr[31:0]),
    .ifu_axi_arregion(ifu_axi.arregion),
    .ifu_axi_arlen(ifu_axi.arlen),
    .ifu_axi_arsize(ifu_axi.arsize),
    .ifu_axi_arburst(ifu_axi.arburst),
    .ifu_axi_arlock(ifu_axi.arlock),
    .ifu_axi_arcache(ifu_axi.arcache),
    .ifu_axi_arprot(ifu_axi.arprot),
    .ifu_axi_arqos(ifu_axi.arqos),
    .ifu_axi_rvalid(ifu_axi.rvalid),
    .ifu_axi_rready(ifu_axi.rready),
    .ifu_axi_rid(ifu_axi.rid),
    .ifu_axi_rdata(ifu_axi.rdata),
    .ifu_axi_rresp(ifu_axi.rresp),
    .ifu_axi_rlast(ifu_axi.rlast),

    .sb_axi_awvalid(), .sb_axi_awready(1'b0), .sb_axi_awid(),
    .sb_axi_awaddr(), .sb_axi_awregion(), .sb_axi_awlen(),
    .sb_axi_awsize(), .sb_axi_awburst(), .sb_axi_awlock(),
    .sb_axi_awcache(), .sb_axi_awprot(), .sb_axi_awqos(),
    .sb_axi_wvalid(), .sb_axi_wready(1'b0), .sb_axi_wdata(),
    .sb_axi_wstrb(), .sb_axi_wlast(), .sb_axi_bvalid(1'b0),
    .sb_axi_bready(), .sb_axi_bresp(2'b00), .sb_axi_bid('0),
    .sb_axi_arvalid(), .sb_axi_arready(1'b0), .sb_axi_arid(),
    .sb_axi_araddr(), .sb_axi_arregion(), .sb_axi_arlen(),
    .sb_axi_arsize(), .sb_axi_arburst(), .sb_axi_arlock(),
    .sb_axi_arcache(), .sb_axi_arprot(), .sb_axi_arqos(),
    .sb_axi_rvalid(1'b0), .sb_axi_rready(), .sb_axi_rid('0),
    .sb_axi_rdata('0), .sb_axi_rresp(2'b00), .sb_axi_rlast(1'b0),

    .dma_axi_awvalid(dma_axi_awvalid), .dma_axi_awready(dma_axi_awready),
    .dma_axi_awid(dma_axi_awid), .dma_axi_awaddr(dma_axi_awaddr),
    .dma_axi_awsize(dma_axi_awsize), .dma_axi_awprot(dma_axi_awprot),
    .dma_axi_awlen(dma_axi_awlen), .dma_axi_awburst(dma_axi_awburst),
    .dma_axi_wvalid(dma_axi_wvalid), .dma_axi_wready(dma_axi_wready),
    .dma_axi_wdata(dma_axi_wdata), .dma_axi_wstrb(dma_axi_wstrb),
    .dma_axi_wlast(dma_axi_wlast), .dma_axi_bvalid(dma_axi_bvalid),
    .dma_axi_bready(dma_axi_bready), .dma_axi_bresp(dma_axi_bresp),
    .dma_axi_bid(dma_axi_bid), .dma_axi_arvalid(1'b0),
    .dma_axi_arready(), .dma_axi_arid('0), .dma_axi_araddr('0),
    .dma_axi_arsize('0), .dma_axi_arprot('0), .dma_axi_arlen('0),
    .dma_axi_arburst('0), .dma_axi_rvalid(), .dma_axi_rready(1'b1),
    .dma_axi_rid(), .dma_axi_rdata(), .dma_axi_rresp(), .dma_axi_rlast(),

    .timer_int('0), .soft_int('0), .extintsrc_req('0),
    .lsu_bus_clk_en(1'b1), .ifu_bus_clk_en(1'b1),
    .dbg_bus_clk_en(1'b1), .dma_bus_clk_en(1'b1),
    .dccm_ext_in_pkt('{default:'0}),
    .iccm_ext_in_pkt('{default:'0}),
    .ic_data_ext_in_pkt('{default:'0}),
    .ic_tag_ext_in_pkt('{default:'0}),
    .btb_ext_in_pkt('{default:'0}),
    .dec_tlu_perfcnt0(), .dec_tlu_perfcnt1(),
    .dec_tlu_perfcnt2(), .dec_tlu_perfcnt3(),
    .jtag_tck(1'b0), .jtag_tms(1'b1), .jtag_tdi(1'b0),
    .jtag_trst_n(1'b0), .jtag_tdo(),
    .core_id('0),
    .mpc_debug_halt_req('0), .mpc_debug_run_req(hw_run_req),
    .mpc_reset_run_req('0), .mpc_debug_halt_ack(),
    .mpc_debug_run_ack(hw_run_ack), .debug_brkpt_status(),
    .dec_tlu_mhartstart(), .i_cpu_halt_req('0),
    .o_cpu_halt_ack(), .o_cpu_halt_status(), .i_cpu_run_req('0),
    .o_cpu_run_ack(), .o_debug_mode_status(debug_mode_status),
    .scan_mode(1'b0), .mbist_mode(1'b0)
  );
endmodule
