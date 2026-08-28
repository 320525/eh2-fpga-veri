`timescale 1ns/1ps

module eh2_core_info_subsystem #(
  parameter logic [31:0] HW_INIT_DCCM_LAST = 32'hf004_fff8,
  parameter logic [31:0] HW_INIT_ICCM_LAST = 32'hee00_fff8
) (
  input  logic                         clk,
  input  logic                         resetn,
  input  logic                         info_system_ready,
  output logic                         core_rst_l,
  output logic                         hw_init_busy,
  output logic                         hw_init_done,
  output logic                         hw_init_error,
  output logic [1:0]                   started,
  output logic [1:0]                   stopped,
  output logic [1:0][3:0]             record_valid,
  output logic [1:0][3:0][255:0]      record_data,
  input  logic [1:0][3:0]             record_ready,
  output logic                         capture_done,
  output logic [1:0][31:0]            next_sequence,
  output logic [1:0][31:0]            commit_count,
  output logic [1:0][31:0]            generated_count,
  output logic [1:0][5:0]             pending_nonblock_count,
  output logic [1:0]                   nb_conflict_hart,
  output logic [1:0]                   info_fifo_overflow_hart,
  output logic [1:0]                   waw_cause_error_hart,
  output logic                         ifu_axi_error,
  output logic                         lsu_axi_error,
  axi4_if.master ifu_axi,
  axi4_if.master lsu_axi
);
  logic dbg_rst_l;
  logic [3:0] reset_release_count;

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
  logic [1:0] hw_run_ack;
  logic [1:0] debug_mode_status;

  logic [1:0] rv_commit_valid;
  logic [1:0][31:0] rv_commit_insn;
  logic [1:0][31:0] rv_commit_pc;
  logic [1:0] rv_commit_hart_id;
  logic [1:0][1:0] rv_commit_priv_mode;
  logic [1:0] rv_commit_gpr_wen_intent;
  logic [1:0] rv_commit_gpr_wen;
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
  logic [1:0] rv_nb_waw_victim_is_load;
  logic [1:0] rv_nb_waw_victim_is_div;
  logic rv_nb_load_gpr_wen;
  logic rv_nb_load_gpr_hart_id;
  logic [4:0] rv_nb_load_gpr_rd;
  logic [31:0] rv_nb_load_gpr_wdata;
  logic rv_nb_div_gpr_wen;
  logic rv_nb_div_gpr_hart_id;
  logic [4:0] rv_nb_div_gpr_rd;
  logic [31:0] rv_nb_div_gpr_wdata;

  // Coherent capture-input timing stage.  Every signal participating in a
  // same-cycle commit/nonblocking/WAW decision is delayed by exactly one core
  // clock.  This preserves event relationships while cutting the physical
  // path from deep EH2 state into the wide capture banks.
  (* KEEP = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] rv_commit_valid_cap;
  logic [1:0][31:0] rv_commit_insn_cap;
  logic [1:0][31:0] rv_commit_pc_cap;
  logic [1:0] rv_commit_hart_id_cap;
  logic [1:0][1:0] rv_commit_priv_mode_cap;
  logic [1:0] rv_commit_gpr_wen_intent_cap;
  logic [1:0] rv_commit_gpr_wen_cap;
  logic [1:0][4:0] rv_commit_gpr_rd_cap;
  logic [1:0][31:0] rv_commit_gpr_wdata_cap;
  logic [1:0] rv_commit_csr_wen_cap;
  logic [1:0][11:0] rv_commit_csr_addr_cap;
  logic [1:0][31:0] rv_commit_csr_wdata_cap;
  logic [1:0] rv_commit_is_nonblock_cap;
  logic [1:0] rv_commit_is_nonblock_load_cap;
  logic [1:0] rv_commit_is_nonblock_div_cap;
  logic [1:0] rv_commit_waw_victim_cap;
  logic [1:0] rv_nb_waw_valid_cap;
  logic [1:0] rv_nb_waw_victim_hart_id_cap;
  logic [1:0][4:0] rv_nb_waw_victim_gpr_rd_cap;
  logic [1:0] rv_nb_waw_victim_is_load_cap;
  logic [1:0] rv_nb_waw_victim_is_div_cap;
  logic rv_nb_load_gpr_wen_cap;
  logic rv_nb_load_gpr_hart_id_cap;
  logic [4:0] rv_nb_load_gpr_rd_cap;
  logic [31:0] rv_nb_load_gpr_wdata_cap;
  logic rv_nb_div_gpr_wen_cap;
  logic rv_nb_div_gpr_hart_id_cap;
  logic [4:0] rv_nb_div_gpr_rd_cap;
  logic [31:0] rv_nb_div_gpr_wdata_cap;
  logic lsu_axi_awvalid_cap;
  logic lsu_axi_awready_cap;
  logic [3:0] lsu_axi_awid_cap;
  logic [31:0] lsu_axi_awaddr_cap;
  logic lsu_axi_wvalid_cap;
  logic lsu_axi_wready_cap;
  logic [63:0] lsu_axi_wdata_cap;
  logic [7:0] lsu_axi_wstrb_cap;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      rv_commit_valid_cap <= '0;
      rv_commit_insn_cap <= '0;
      rv_commit_pc_cap <= '0;
      rv_commit_hart_id_cap <= '0;
      rv_commit_priv_mode_cap <= '0;
      rv_commit_gpr_wen_intent_cap <= '0;
      rv_commit_gpr_wen_cap <= '0;
      rv_commit_gpr_rd_cap <= '0;
      rv_commit_gpr_wdata_cap <= '0;
      rv_commit_csr_wen_cap <= '0;
      rv_commit_csr_addr_cap <= '0;
      rv_commit_csr_wdata_cap <= '0;
      rv_commit_is_nonblock_cap <= '0;
      rv_commit_is_nonblock_load_cap <= '0;
      rv_commit_is_nonblock_div_cap <= '0;
      rv_commit_waw_victim_cap <= '0;
      rv_nb_waw_valid_cap <= '0;
      rv_nb_waw_victim_hart_id_cap <= '0;
      rv_nb_waw_victim_gpr_rd_cap <= '0;
      rv_nb_waw_victim_is_load_cap <= '0;
      rv_nb_waw_victim_is_div_cap <= '0;
      rv_nb_load_gpr_wen_cap <= 1'b0;
      rv_nb_load_gpr_hart_id_cap <= 1'b0;
      rv_nb_load_gpr_rd_cap <= '0;
      rv_nb_load_gpr_wdata_cap <= '0;
      rv_nb_div_gpr_wen_cap <= 1'b0;
      rv_nb_div_gpr_hart_id_cap <= 1'b0;
      rv_nb_div_gpr_rd_cap <= '0;
      rv_nb_div_gpr_wdata_cap <= '0;
      lsu_axi_awvalid_cap <= 1'b0;
      lsu_axi_awready_cap <= 1'b0;
      lsu_axi_awid_cap <= '0;
      lsu_axi_awaddr_cap <= '0;
      lsu_axi_wvalid_cap <= 1'b0;
      lsu_axi_wready_cap <= 1'b0;
      lsu_axi_wdata_cap <= '0;
      lsu_axi_wstrb_cap <= '0;
    end else begin
      rv_commit_valid_cap <= rv_commit_valid;
      rv_commit_insn_cap <= rv_commit_insn;
      rv_commit_pc_cap <= rv_commit_pc;
      rv_commit_hart_id_cap <= rv_commit_hart_id;
      rv_commit_priv_mode_cap <= rv_commit_priv_mode;
      rv_commit_gpr_wen_intent_cap <= rv_commit_gpr_wen_intent;
      rv_commit_gpr_wen_cap <= rv_commit_gpr_wen;
      rv_commit_gpr_rd_cap <= rv_commit_gpr_rd;
      rv_commit_gpr_wdata_cap <= rv_commit_gpr_wdata;
      rv_commit_csr_wen_cap <= rv_commit_csr_wen;
      rv_commit_csr_addr_cap <= rv_commit_csr_addr;
      rv_commit_csr_wdata_cap <= rv_commit_csr_wdata;
      rv_commit_is_nonblock_cap <= rv_commit_is_nonblock;
      rv_commit_is_nonblock_load_cap <= rv_commit_is_nonblock_load;
      rv_commit_is_nonblock_div_cap <= rv_commit_is_nonblock_div;
      rv_commit_waw_victim_cap <= rv_commit_waw_victim;
      rv_nb_waw_valid_cap <= rv_nb_waw_valid;
      rv_nb_waw_victim_hart_id_cap <= rv_nb_waw_victim_hart_id;
      rv_nb_waw_victim_gpr_rd_cap <= rv_nb_waw_victim_gpr_rd;
      rv_nb_waw_victim_is_load_cap <= rv_nb_waw_victim_is_load;
      rv_nb_waw_victim_is_div_cap <= rv_nb_waw_victim_is_div;
      rv_nb_load_gpr_wen_cap <= rv_nb_load_gpr_wen;
      rv_nb_load_gpr_hart_id_cap <= rv_nb_load_gpr_hart_id;
      rv_nb_load_gpr_rd_cap <= rv_nb_load_gpr_rd;
      rv_nb_load_gpr_wdata_cap <= rv_nb_load_gpr_wdata;
      rv_nb_div_gpr_wen_cap <= rv_nb_div_gpr_wen;
      rv_nb_div_gpr_hart_id_cap <= rv_nb_div_gpr_hart_id;
      rv_nb_div_gpr_rd_cap <= rv_nb_div_gpr_rd;
      rv_nb_div_gpr_wdata_cap <= rv_nb_div_gpr_wdata;
      lsu_axi_awvalid_cap <= lsu_axi.awvalid;
      lsu_axi_awready_cap <= lsu_axi.awready;
      lsu_axi_awid_cap <= lsu_axi.awid;
      lsu_axi_awaddr_cap <= lsu_axi.awaddr[31:0];
      lsu_axi_wvalid_cap <= lsu_axi.wvalid;
      lsu_axi_wready_cap <= lsu_axi.wready;
      lsu_axi_wdata_cap <= lsu_axi.wdata;
      lsu_axi_wstrb_cap <= lsu_axi.wstrb;
    end
  end

  // Halt the processor from the undelayed stop-store handshake.  The capture
  // instance receives the coherently delayed copy above, so it reproduces the
  // original rule that commits coincident with the stop marker are suppressed,
  // while EH2 itself is not permitted to retire an extra instruction merely
  // because a timing register was inserted in the logging path.
  localparam logic [31:0] INFO_STOP_ADDR = 32'hD058_0000;
  localparam logic [31:0] INFO_STOP_DATA = 32'h0032_0525;
  logic raw_marker_addr_pending;
  logic raw_marker_data_pending;
  logic raw_marker_addr_hart;
  logic [1:0] core_halt_request;
  wire raw_marker_addr_hs = lsu_axi.awvalid && lsu_axi.awready &&
                            (lsu_axi.awaddr[31:0] == INFO_STOP_ADDR);
  wire raw_marker_data_hs = lsu_axi.wvalid && lsu_axi.wready &&
                            (&lsu_axi.wstrb[3:0]) &&
                            (lsu_axi.wdata[31:0] == INFO_STOP_DATA);
  wire raw_marker_store_event =
    (raw_marker_addr_pending || raw_marker_addr_hs) &&
    (raw_marker_data_pending || raw_marker_data_hs);
  wire raw_marker_store_hart = raw_marker_addr_hs ?
                               lsu_axi.awid[3] : raw_marker_addr_hart;

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      raw_marker_addr_pending <= 1'b0;
      raw_marker_data_pending <= 1'b0;
      raw_marker_addr_hart <= 1'b0;
      core_halt_request <= 2'b00;
    end else if (raw_marker_store_event) begin
      raw_marker_addr_pending <= 1'b0;
      raw_marker_data_pending <= 1'b0;
      core_halt_request[raw_marker_store_hart] <= 1'b1;
    end else begin
      if (raw_marker_addr_hs) begin
        raw_marker_addr_pending <= 1'b1;
        raw_marker_addr_hart <= lsu_axi.awid[3];
      end
      if (raw_marker_data_hs)
        raw_marker_data_pending <= 1'b1;
    end
  end

  // A hart is considered started only after it actually retires its first
  // instruction.  This distinguishes hart1's real MHARTSTART response from
  // merely releasing the shared core reset.
  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      started <= 2'b00;
    end else begin
      for (integer lane = 0; lane < 2; lane = lane + 1)
        if (rv_commit_valid[lane])
          started[rv_commit_hart_id[lane]] <= 1'b1;
    end
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      reset_release_count <= 4'd0;
      dbg_rst_l <= 1'b0;
      core_rst_l <= 1'b0;
    end else if (!info_system_ready) begin
      reset_release_count <= 4'd0;
      dbg_rst_l <= 1'b0;
      core_rst_l <= 1'b0;
    end else begin
      if (reset_release_count != 4'hf)
        reset_release_count <= reset_release_count + 4'd1;
      if (reset_release_count >= 4'd2)
        dbg_rst_l <= 1'b1;
      if (reset_release_count >= 4'd5)
        core_rst_l <= 1'b1;
    end
  end

  eh2_hw_init #(
    .DCCM_LAST(HW_INIT_DCCM_LAST), .ICCM_LAST(HW_INIT_ICCM_LAST)
  ) hw_init_i (
    .clk(clk), .resetn(core_rst_l), .debug_halted(debug_mode_status[0]),
    .run_ack(hw_run_ack[0]), .run_req(hw_run_req),
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

  always_ff @(posedge clk or negedge core_rst_l) begin
    if (!core_rst_l) begin
      ifu_axi_error <= 1'b0;
      lsu_axi_error <= 1'b0;
    end else begin
      if ((ifu_axi.bvalid && ifu_axi.bready && (ifu_axi.bresp != 2'b00)) ||
          (ifu_axi.rvalid && ifu_axi.rready && (ifu_axi.rresp != 2'b00)))
        ifu_axi_error <= 1'b1;
      if ((lsu_axi.bvalid && lsu_axi.bready && (lsu_axi.bresp != 2'b00)) ||
          (lsu_axi.rvalid && lsu_axi.rready && (lsu_axi.rresp != 2'b00)))
        lsu_axi_error <= 1'b1;
    end
  end

  assign ifu_axi.awaddr[32] = 1'b0;
  assign ifu_axi.araddr[32] = 1'b0;
  assign lsu_axi.awaddr[32] = 1'b0;
  assign lsu_axi.araddr[32] = 1'b0;

  eh2_veer_wrapper core_i (
    .rst_l(core_rst_l),
    .dbg_rst_l(dbg_rst_l),
    .clk(clk),
    // EH2 exposes reset vector bits [31:1].  0x8000_0000 >> 1.
    .rst_vec(31'h4000_0000),
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
    .rv_commit_valid(rv_commit_valid),
    .rv_commit_insn(rv_commit_insn),
    .rv_commit_pc(rv_commit_pc),
    .rv_commit_hart_id(rv_commit_hart_id),
    .rv_commit_priv_mode(rv_commit_priv_mode),
    .rv_commit_gpr_wen_intent(rv_commit_gpr_wen_intent),
    .rv_commit_gpr_wen(rv_commit_gpr_wen),
    .rv_commit_gpr_rd(rv_commit_gpr_rd),
    .rv_commit_gpr_wdata(rv_commit_gpr_wdata),
    .rv_commit_csr_wen(rv_commit_csr_wen),
    .rv_commit_csr_addr(rv_commit_csr_addr),
    .rv_commit_csr_wdata(rv_commit_csr_wdata),
    .rv_commit_is_nonblock(rv_commit_is_nonblock),
    .rv_commit_is_nonblock_load(rv_commit_is_nonblock_load),
    .rv_commit_is_nonblock_div(rv_commit_is_nonblock_div),
    .rv_commit_waw_victim(rv_commit_waw_victim),
    .rv_nb_waw_valid(rv_nb_waw_valid),
    .rv_nb_waw_victim_insn(),
    .rv_nb_waw_victim_pc(),
    .rv_nb_waw_victim_hart_id(rv_nb_waw_victim_hart_id),
    .rv_nb_waw_victim_gpr_rd(rv_nb_waw_victim_gpr_rd),
    .rv_nb_waw_victim_is_load(rv_nb_waw_victim_is_load),
    .rv_nb_waw_victim_is_div(rv_nb_waw_victim_is_div),
    .rv_nb_load_gpr_wen(rv_nb_load_gpr_wen),
    .rv_nb_load_gpr_hart_id(rv_nb_load_gpr_hart_id),
    .rv_nb_load_gpr_rd(rv_nb_load_gpr_rd),
    .rv_nb_load_gpr_wdata(rv_nb_load_gpr_wdata),
    .rv_nb_div_gpr_wen(rv_nb_div_gpr_wen),
    .rv_nb_div_gpr_hart_id(rv_nb_div_gpr_hart_id),
    .rv_nb_div_gpr_rd(rv_nb_div_gpr_rd),
    .rv_nb_div_gpr_wdata(rv_nb_div_gpr_wdata),

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
    .mpc_debug_halt_req(2'b0),
    .mpc_debug_run_req({1'b0,hw_run_req}),
    // Hart0 is deliberately halted on reset so eh2_hw_init can initialize
    // DCCM/ICCM through the debug DMA path before issuing its debug-run.
    // Hart1 is initially held by MHARTSTART; once hart0 writes CSR 0x7FC[1],
    // bit 1 below makes hart1 take the reset vector and run instead of
    // entering an MPC debug-halt that has no corresponding run request.
    .mpc_reset_run_req(2'b10), .mpc_debug_halt_ack(),
    .mpc_debug_run_ack(hw_run_ack), .debug_brkpt_status(),
    .dec_tlu_mhartstart(), .i_cpu_halt_req(core_halt_request),
    .o_cpu_halt_ack(), .o_cpu_halt_status(), .i_cpu_run_req('0),
    .o_cpu_run_ack(), .o_debug_mode_status(debug_mode_status),
    .scan_mode(1'b0), .mbist_mode(1'b0)
  );

  instr_info_capture_dual #(.LSU_TAG_WIDTH(4)) info_capture_i (
    .clk(clk), .rst_l(resetn),
    .rv_commit_valid(rv_commit_valid_cap),
    .rv_commit_insn(rv_commit_insn_cap),
    .rv_commit_pc(rv_commit_pc_cap),
    .rv_commit_hart_id(rv_commit_hart_id_cap),
    .rv_commit_priv_mode(rv_commit_priv_mode_cap),
    .rv_commit_gpr_wen_intent(rv_commit_gpr_wen_intent_cap),
    .rv_commit_gpr_wen(rv_commit_gpr_wen_cap),
    .rv_commit_gpr_rd(rv_commit_gpr_rd_cap),
    .rv_commit_gpr_wdata(rv_commit_gpr_wdata_cap),
    .rv_commit_csr_wen(rv_commit_csr_wen_cap),
    .rv_commit_csr_addr(rv_commit_csr_addr_cap),
    .rv_commit_csr_wdata(rv_commit_csr_wdata_cap),
    .rv_commit_is_nonblock(rv_commit_is_nonblock_cap),
    .rv_commit_is_nonblock_load(rv_commit_is_nonblock_load_cap),
    .rv_commit_is_nonblock_div(rv_commit_is_nonblock_div_cap),
    .rv_commit_waw_victim(rv_commit_waw_victim_cap),
    .rv_nb_waw_valid(rv_nb_waw_valid_cap),
    .rv_nb_waw_victim_hart_id(rv_nb_waw_victim_hart_id_cap),
    .rv_nb_waw_victim_gpr_rd(rv_nb_waw_victim_gpr_rd_cap),
    .rv_nb_waw_victim_is_load(rv_nb_waw_victim_is_load_cap),
    .rv_nb_waw_victim_is_div(rv_nb_waw_victim_is_div_cap),
    .rv_nb_load_gpr_wen(rv_nb_load_gpr_wen_cap),
    .rv_nb_load_gpr_hart_id(rv_nb_load_gpr_hart_id_cap),
    .rv_nb_load_gpr_rd(rv_nb_load_gpr_rd_cap),
    .rv_nb_load_gpr_wdata(rv_nb_load_gpr_wdata_cap),
    .rv_nb_div_gpr_wen(rv_nb_div_gpr_wen_cap),
    .rv_nb_div_gpr_hart_id(rv_nb_div_gpr_hart_id_cap),
    .rv_nb_div_gpr_rd(rv_nb_div_gpr_rd_cap),
    .rv_nb_div_gpr_wdata(rv_nb_div_gpr_wdata_cap),
    .lsu_axi_awvalid(lsu_axi_awvalid_cap),
    .lsu_axi_awready(lsu_axi_awready_cap), .lsu_axi_awid(lsu_axi_awid_cap),
    .lsu_axi_awaddr(lsu_axi_awaddr_cap),
    .lsu_axi_wvalid(lsu_axi_wvalid_cap), .lsu_axi_wready(lsu_axi_wready_cap),
    .lsu_axi_wdata(lsu_axi_wdata_cap), .lsu_axi_wstrb(lsu_axi_wstrb_cap),
    .record_valid, .record_data, .record_ready,
    .stopped, .next_sequence, .commit_count, .generated_count,
    .pending_nonblock_count, .capture_done,
    .nonblock_conflict_hart(nb_conflict_hart),
    .record_overflow_hart(info_fifo_overflow_hart),
    .waw_cause_error_hart
  );
endmodule
