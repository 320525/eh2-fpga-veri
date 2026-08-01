// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module eh2_crc_soc #(
    parameter string MEM_FILE = "",
    parameter integer MEM_BYTES = 131072,
    parameter logic SPARSE_AUX_ENABLE = 1'b0,
    parameter logic [31:0] SPARSE_AUX_ADDR = 32'h8001_0000,
    parameter logic [63:0] SPARSE_AUX_INIT = 64'b0,
    parameter logic [1:0] RUN_HART_MASK = 2'b01,
    parameter logic ENABLE_GOLDEN_CHECK = 1'b1,
    parameter logic [31:0] EXPECTED_COUNT = 32'd899,
    // Golden for the supplied FPGA ELF with the dual-hart EH2 configuration.
    // Its 24 statically tagged load/div pairs complete before the younger
    // writer reaches EH2's real WAW-cancel point, so their returned data is
    // included. Only an asserted EH2 WAW event is allowed to zero data.
    parameter logic [63:0] EXPECTED_XOR0 = 64'h0f679f9999355134,
    parameter logic [63:0] EXPECTED_XOR1 = 64'h9909e9725ab66071,
    parameter logic [63:0] EXPECTED_SUM0 = 64'hcbf08f5dd8aeb6b6,
    parameter logic [63:0] EXPECTED_SUM1 = 64'h44ab72f45137c99f,
    parameter logic [63:0] EXPECTED_SUM2 = 64'h4763eb0bc0cdf491,
    parameter logic [63:0] EXPECTED_SUM3 = 64'hcf8ccff5b2143cd9
) (
    input  logic                         core_clk,
    input  logic                         crc_rd_clk,
    input  logic                         infra_rst_l,
    output logic                         core_rst_l,
    output logic                         crc_system_ready,
    output logic                         pass_latched,
    output logic                         fail_latched,
    output logic                         activity_seen,
    output logic                         hart1_commit_seen,
    output logic [1:0]                   stopped,
    output logic [1:0][31:0]             commit_count,
    output logic [1:0][31:0]             generated_count,
    output logic [1:0][1:0]              result_valid,
    output logic [1:0][1:0][15:0]        result_package_number,
    output logic [1:0][1:0][63:0]        result_xor0,
    output logic [1:0][1:0][63:0]        result_xor1,
    output logic [1:0][1:0][63:0]        result_sum0,
    output logic [1:0][1:0][63:0]        result_sum1,
    output logic [1:0][1:0][63:0]        result_sum2,
    output logic [1:0][1:0][63:0]        result_sum3,
    output logic [1:0][1:0][31:0]        result_item_count
);
    logic [3:0] reset_release_count;
    logic dbg_rst_l;

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
    logic rv_nb_load_gpr_wen;
    logic rv_nb_load_gpr_hart_id;
    logic [4:0] rv_nb_load_gpr_rd;
    logic [31:0] rv_nb_load_gpr_wdata;
    logic rv_nb_div_gpr_wen;
    logic rv_nb_div_gpr_hart_id;
    logic [4:0] rv_nb_div_gpr_rd;
    logic [31:0] rv_nb_div_gpr_wdata;

    logic lsu_axi_awvalid, lsu_axi_awready;
    logic [3:0] lsu_axi_awid;
    logic [31:0] lsu_axi_awaddr;
    logic [7:0] lsu_axi_awlen;
    logic [2:0] lsu_axi_awsize;
    logic [1:0] lsu_axi_awburst;
    logic lsu_axi_wvalid, lsu_axi_wready;
    logic [63:0] lsu_axi_wdata;
    logic [7:0] lsu_axi_wstrb;
    logic lsu_axi_wlast;
    logic lsu_axi_bvalid, lsu_axi_bready;
    logic [1:0] lsu_axi_bresp;
    logic [3:0] lsu_axi_bid;
    logic lsu_axi_arvalid, lsu_axi_arready;
    logic [3:0] lsu_axi_arid;
    logic [31:0] lsu_axi_araddr;
    logic [7:0] lsu_axi_arlen;
    logic [2:0] lsu_axi_arsize;
    logic [1:0] lsu_axi_arburst;
    logic lsu_axi_rvalid, lsu_axi_rready;
    logic [3:0] lsu_axi_rid;
    logic [63:0] lsu_axi_rdata;
    logic [1:0] lsu_axi_rresp;
    logic lsu_axi_rlast;

    logic ifu_axi_arvalid, ifu_axi_arready;
    logic [3:0] ifu_axi_arid;
    logic [31:0] ifu_axi_araddr;
    logic [7:0] ifu_axi_arlen;
    logic [2:0] ifu_axi_arsize;
    logic [1:0] ifu_axi_arburst;
    logic ifu_axi_rvalid, ifu_axi_rready;
    logic [3:0] ifu_axi_rid;
    logic [63:0] ifu_axi_rdata;
    logic [1:0] ifu_axi_rresp;
    logic ifu_axi_rlast;

    logic buffer_conflict, fifo_overflow, bank_conflict;
    logic [1:0][15:0] sequence_number, package_number;
    logic [1:0][5:0] pending_nonblock_count;
    logic [1:0][1:0][7:0] fifo_occupancy;
    logic error_seen;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] error_seen_rd_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [1:0] hart1_seen_rd_sync;

    always_ff @(posedge core_clk or negedge infra_rst_l) begin
        if (!infra_rst_l) begin
            reset_release_count <= 4'd0;
            dbg_rst_l <= 1'b0;
            core_rst_l <= 1'b0;
        end else if (!crc_system_ready) begin
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

    eh2_veer_wrapper core_i (
        .clk(core_clk),
        .rst_l(core_rst_l),
        .dbg_rst_l(dbg_rst_l),
        .rst_vec(31'h4000_0000),
        .nmi_int(1'b0),
        .nmi_vec(31'h6800_0000),
        .jtag_id({4'b0001, 16'd0, 11'h045}),

        .trace_rv_i_insn_ip(), .trace_rv_i_address_ip(),
        .trace_rv_i_valid_ip(), .trace_rv_i_exception_ip(),
        .trace_rv_i_ecause_ip(), .trace_rv_i_interrupt_ip(),
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
        .rv_nb_waw_victim_is_load(),
        .rv_nb_waw_victim_is_div(),
        .rv_nb_load_gpr_wen(rv_nb_load_gpr_wen),
        .rv_nb_load_gpr_hart_id(rv_nb_load_gpr_hart_id),
        .rv_nb_load_gpr_rd(rv_nb_load_gpr_rd),
        .rv_nb_load_gpr_wdata(rv_nb_load_gpr_wdata),
        .rv_nb_div_gpr_wen(rv_nb_div_gpr_wen),
        .rv_nb_div_gpr_hart_id(rv_nb_div_gpr_hart_id),
        .rv_nb_div_gpr_rd(rv_nb_div_gpr_rd),
        .rv_nb_div_gpr_wdata(rv_nb_div_gpr_wdata),

        .lsu_axi_awvalid(lsu_axi_awvalid),
        .lsu_axi_awready(lsu_axi_awready),
        .lsu_axi_awid(lsu_axi_awid),
        .lsu_axi_awaddr(lsu_axi_awaddr),
        .lsu_axi_awregion(), .lsu_axi_awlen(lsu_axi_awlen),
        .lsu_axi_awsize(lsu_axi_awsize),
        .lsu_axi_awburst(lsu_axi_awburst),
        .lsu_axi_awlock(), .lsu_axi_awcache(), .lsu_axi_awprot(),
        .lsu_axi_awqos(),
        .lsu_axi_wvalid(lsu_axi_wvalid),
        .lsu_axi_wready(lsu_axi_wready),
        .lsu_axi_wdata(lsu_axi_wdata),
        .lsu_axi_wstrb(lsu_axi_wstrb),
        .lsu_axi_wlast(lsu_axi_wlast),
        .lsu_axi_bvalid(lsu_axi_bvalid),
        .lsu_axi_bready(lsu_axi_bready),
        .lsu_axi_bresp(lsu_axi_bresp),
        .lsu_axi_bid(lsu_axi_bid),
        .lsu_axi_arvalid(lsu_axi_arvalid),
        .lsu_axi_arready(lsu_axi_arready),
        .lsu_axi_arid(lsu_axi_arid),
        .lsu_axi_araddr(lsu_axi_araddr),
        .lsu_axi_arregion(), .lsu_axi_arlen(lsu_axi_arlen),
        .lsu_axi_arsize(lsu_axi_arsize),
        .lsu_axi_arburst(lsu_axi_arburst),
        .lsu_axi_arlock(), .lsu_axi_arcache(), .lsu_axi_arprot(),
        .lsu_axi_arqos(),
        .lsu_axi_rvalid(lsu_axi_rvalid),
        .lsu_axi_rready(lsu_axi_rready),
        .lsu_axi_rid(lsu_axi_rid),
        .lsu_axi_rdata(lsu_axi_rdata),
        .lsu_axi_rresp(lsu_axi_rresp),
        .lsu_axi_rlast(lsu_axi_rlast),

        .ifu_axi_awvalid(), .ifu_axi_awready(1'b0), .ifu_axi_awid(),
        .ifu_axi_awaddr(), .ifu_axi_awregion(), .ifu_axi_awlen(),
        .ifu_axi_awsize(), .ifu_axi_awburst(), .ifu_axi_awlock(),
        .ifu_axi_awcache(), .ifu_axi_awprot(), .ifu_axi_awqos(),
        .ifu_axi_wvalid(), .ifu_axi_wready(1'b0), .ifu_axi_wdata(),
        .ifu_axi_wstrb(), .ifu_axi_wlast(), .ifu_axi_bvalid(1'b0),
        .ifu_axi_bready(), .ifu_axi_bresp(2'b00), .ifu_axi_bid(4'b0),
        .ifu_axi_arvalid(ifu_axi_arvalid),
        .ifu_axi_arready(ifu_axi_arready),
        .ifu_axi_arid(ifu_axi_arid),
        .ifu_axi_araddr(ifu_axi_araddr),
        .ifu_axi_arregion(), .ifu_axi_arlen(ifu_axi_arlen),
        .ifu_axi_arsize(ifu_axi_arsize),
        .ifu_axi_arburst(ifu_axi_arburst),
        .ifu_axi_arlock(), .ifu_axi_arcache(), .ifu_axi_arprot(),
        .ifu_axi_arqos(),
        .ifu_axi_rvalid(ifu_axi_rvalid),
        .ifu_axi_rready(ifu_axi_rready),
        .ifu_axi_rid(ifu_axi_rid),
        .ifu_axi_rdata(ifu_axi_rdata),
        .ifu_axi_rresp(ifu_axi_rresp),
        .ifu_axi_rlast(ifu_axi_rlast),

        .sb_axi_awvalid(), .sb_axi_awready(1'b0), .sb_axi_awid(),
        .sb_axi_awaddr(), .sb_axi_awregion(), .sb_axi_awlen(),
        .sb_axi_awsize(), .sb_axi_awburst(), .sb_axi_awlock(),
        .sb_axi_awcache(), .sb_axi_awprot(), .sb_axi_awqos(),
        .sb_axi_wvalid(), .sb_axi_wready(1'b0), .sb_axi_wdata(),
        .sb_axi_wstrb(), .sb_axi_wlast(), .sb_axi_bvalid(1'b0),
        .sb_axi_bready(), .sb_axi_bresp(2'b00), .sb_axi_bid(1'b0),
        .sb_axi_arvalid(), .sb_axi_arready(1'b0), .sb_axi_arid(),
        .sb_axi_araddr(), .sb_axi_arregion(), .sb_axi_arlen(),
        .sb_axi_arsize(), .sb_axi_arburst(), .sb_axi_arlock(),
        .sb_axi_arcache(), .sb_axi_arprot(), .sb_axi_arqos(),
        .sb_axi_rvalid(1'b0), .sb_axi_rready(), .sb_axi_rid(1'b0),
        .sb_axi_rdata(64'b0), .sb_axi_rresp(2'b00), .sb_axi_rlast(1'b0),

        .dma_axi_awvalid(1'b0), .dma_axi_awready(), .dma_axi_awid(1'b0),
        .dma_axi_awaddr(32'b0), .dma_axi_awsize(3'b0),
        .dma_axi_awprot(3'b0), .dma_axi_awlen(8'b0),
        .dma_axi_awburst(2'b0), .dma_axi_wvalid(1'b0),
        .dma_axi_wready(), .dma_axi_wdata(64'b0), .dma_axi_wstrb(8'b0),
        .dma_axi_wlast(1'b0), .dma_axi_bvalid(), .dma_axi_bready(1'b1),
        .dma_axi_bresp(), .dma_axi_bid(), .dma_axi_arvalid(1'b0),
        .dma_axi_arready(), .dma_axi_arid(1'b0), .dma_axi_araddr(32'b0),
        .dma_axi_arsize(3'b0), .dma_axi_arprot(3'b0),
        .dma_axi_arlen(8'b0), .dma_axi_arburst(2'b0),
        .dma_axi_rvalid(), .dma_axi_rready(1'b1), .dma_axi_rid(),
        .dma_axi_rdata(), .dma_axi_rresp(), .dma_axi_rlast(),

        .lsu_bus_clk_en(1'b1), .ifu_bus_clk_en(1'b1),
        .dbg_bus_clk_en(1'b1), .dma_bus_clk_en(1'b1),
        .dccm_ext_in_pkt(96'b0), .iccm_ext_in_pkt(48'b0),
        .btb_ext_in_pkt(24'b0), .ic_data_ext_in_pkt(96'b0),
        .ic_tag_ext_in_pkt(48'b0),
        .timer_int(2'b0), .soft_int(2'b0), .extintsrc_req(127'b0),
        .dec_tlu_perfcnt0(), .dec_tlu_perfcnt1(),
        .dec_tlu_perfcnt2(), .dec_tlu_perfcnt3(),
        .jtag_tck(1'b0), .jtag_tms(1'b1), .jtag_tdi(1'b0),
        .jtag_trst_n(1'b0), .jtag_tdo(), .core_id(28'b0),
        .mpc_debug_halt_req(2'b0), .mpc_debug_run_req(2'b0),
        .mpc_reset_run_req(RUN_HART_MASK),
        .mpc_debug_halt_ack(), .mpc_debug_run_ack(),
        .debug_brkpt_status(), .dec_tlu_mhartstart(),
        // Stop each hardware thread independently after that hart has issued
        // the end-of-program marker store.  This is equivalent to the old
        // hart0-only connection for the FPGA image, and also lets the dual-
        // hart RTL stress test drain and terminate cleanly.
        .i_cpu_halt_req(stopped),
        .o_cpu_halt_ack(), .o_cpu_halt_status(),
        .o_debug_mode_status(), .i_cpu_run_req(2'b0),
        .o_cpu_run_ack(), .scan_mode(1'b0), .mbist_mode(1'b0)
    );

    eh2_unified_axi_bram #(
        .MEM_BYTES(MEM_BYTES), .BASE_ADDR(32'h8000_0000),
        .IFU_TAG_WIDTH(4), .LSU_TAG_WIDTH(4), .MEM_FILE(MEM_FILE),
        .SPARSE_AUX_ENABLE(SPARSE_AUX_ENABLE),
        .SPARSE_AUX_ADDR(SPARSE_AUX_ADDR),
        .SPARSE_AUX_INIT(SPARSE_AUX_INIT)
    ) memory_i (
        .clk(core_clk), .rst_l(core_rst_l),
        .ifu_arvalid(ifu_axi_arvalid), .ifu_arready(ifu_axi_arready),
        .ifu_araddr(ifu_axi_araddr), .ifu_arid(ifu_axi_arid),
        .ifu_arlen(ifu_axi_arlen), .ifu_arburst(ifu_axi_arburst),
        .ifu_arsize(ifu_axi_arsize), .ifu_rvalid(ifu_axi_rvalid),
        .ifu_rready(ifu_axi_rready), .ifu_rdata(ifu_axi_rdata),
        .ifu_rresp(ifu_axi_rresp), .ifu_rid(ifu_axi_rid),
        .ifu_rlast(ifu_axi_rlast),
        .lsu_arvalid(lsu_axi_arvalid), .lsu_arready(lsu_axi_arready),
        .lsu_araddr(lsu_axi_araddr), .lsu_arid(lsu_axi_arid),
        .lsu_arlen(lsu_axi_arlen), .lsu_arburst(lsu_axi_arburst),
        .lsu_arsize(lsu_axi_arsize), .lsu_rvalid(lsu_axi_rvalid),
        .lsu_rready(lsu_axi_rready), .lsu_rdata(lsu_axi_rdata),
        .lsu_rresp(lsu_axi_rresp), .lsu_rid(lsu_axi_rid),
        .lsu_rlast(lsu_axi_rlast),
        .lsu_awvalid(lsu_axi_awvalid), .lsu_awready(lsu_axi_awready),
        .lsu_awaddr(lsu_axi_awaddr), .lsu_awid(lsu_axi_awid),
        .lsu_awlen(lsu_axi_awlen), .lsu_awburst(lsu_axi_awburst),
        .lsu_awsize(lsu_axi_awsize), .lsu_wvalid(lsu_axi_wvalid),
        .lsu_wready(lsu_axi_wready), .lsu_wdata(lsu_axi_wdata),
        .lsu_wstrb(lsu_axi_wstrb), .lsu_wlast(lsu_axi_wlast),
        .lsu_bvalid(lsu_axi_bvalid), .lsu_bready(lsu_axi_bready),
        .lsu_bresp(lsu_axi_bresp), .lsu_bid(lsu_axi_bid)
    );

    instr_crc_system_dual #(.LSU_TAG_WIDTH(4)) crc_i (
        .wr_clk(core_clk), .rd_clk(crc_rd_clk), .rst_l(infra_rst_l),
        .rv_commit_valid(rv_commit_valid), .rv_commit_insn(rv_commit_insn),
        .rv_commit_pc(rv_commit_pc), .rv_commit_hart_id(rv_commit_hart_id),
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
        .rv_nb_waw_victim_hart_id(rv_nb_waw_victim_hart_id),
        .rv_nb_waw_victim_gpr_rd(rv_nb_waw_victim_gpr_rd),
        .rv_nb_load_gpr_wen(rv_nb_load_gpr_wen),
        .rv_nb_load_gpr_hart_id(rv_nb_load_gpr_hart_id),
        .rv_nb_load_gpr_rd(rv_nb_load_gpr_rd),
        .rv_nb_load_gpr_wdata(rv_nb_load_gpr_wdata),
        .rv_nb_div_gpr_wen(rv_nb_div_gpr_wen),
        .rv_nb_div_gpr_hart_id(rv_nb_div_gpr_hart_id),
        .rv_nb_div_gpr_rd(rv_nb_div_gpr_rd),
        .rv_nb_div_gpr_wdata(rv_nb_div_gpr_wdata),
        .lsu_axi_awvalid(lsu_axi_awvalid),
        .lsu_axi_awready(lsu_axi_awready), .lsu_axi_awid(lsu_axi_awid),
        .lsu_axi_awaddr(lsu_axi_awaddr), .lsu_axi_wvalid(lsu_axi_wvalid),
        .lsu_axi_wready(lsu_axi_wready), .lsu_axi_wdata(lsu_axi_wdata),
        .lsu_axi_wstrb(lsu_axi_wstrb),
        .buffer_conflict(buffer_conflict), .fifo_overflow(fifo_overflow),
        .bank_conflict(bank_conflict), .stopped(stopped),
        .sequence_number(sequence_number), .package_number(package_number),
        .commit_count(commit_count), .generated_count(generated_count),
        .pending_nonblock_count(pending_nonblock_count),
        .result_valid(result_valid),
        .result_package_number(result_package_number),
        .result_xor0(result_xor0), .result_xor1(result_xor1),
        .result_sum0(result_sum0), .result_sum1(result_sum1),
        .result_sum2(result_sum2), .result_sum3(result_sum3),
        .result_item_count(result_item_count),
        .fifo_occupancy(fifo_occupancy), .system_ready(crc_system_ready)
    );

    always_ff @(posedge core_clk or negedge infra_rst_l) begin
        if (!infra_rst_l) begin
            activity_seen <= 1'b0;
            hart1_commit_seen <= 1'b0;
            error_seen <= 1'b0;
        end else begin
            if (|rv_commit_valid)
                activity_seen <= 1'b1;
            if ((rv_commit_valid[0] && rv_commit_hart_id[0]) ||
                (rv_commit_valid[1] && rv_commit_hart_id[1]))
                hart1_commit_seen <= 1'b1;
            error_seen <= error_seen | buffer_conflict | fifo_overflow |
                          bank_conflict;
        end
    end

    always_ff @(posedge crc_rd_clk or negedge infra_rst_l) begin
        if (!infra_rst_l) begin
            pass_latched <= 1'b0;
            fail_latched <= 1'b0;
            error_seen_rd_sync <= 2'b0;
            hart1_seen_rd_sync <= 2'b0;
        end else if (ENABLE_GOLDEN_CHECK) begin
            error_seen_rd_sync <= {error_seen_rd_sync[0], error_seen};
            hart1_seen_rd_sync <= {hart1_seen_rd_sync[0], hart1_commit_seen};
            if (result_valid[0][0]) begin
                if ((result_package_number[0][0] == 16'd0) &&
                    (result_item_count[0][0] == EXPECTED_COUNT) &&
                    (result_xor0[0][0] == EXPECTED_XOR0) &&
                    (result_xor1[0][0] == EXPECTED_XOR1) &&
                    (result_sum0[0][0] == EXPECTED_SUM0) &&
                    (result_sum1[0][0] == EXPECTED_SUM1) &&
                    (result_sum2[0][0] == EXPECTED_SUM2) &&
                    (result_sum3[0][0] == EXPECTED_SUM3) &&
                    !error_seen_rd_sync[1] && !hart1_seen_rd_sync[1])
                    pass_latched <= 1'b1;
                else
                    fail_latched <= 1'b1;
            end
            if (result_valid[0][1] || |result_valid[1])
                fail_latched <= 1'b1;
        end else begin
            error_seen_rd_sync <= {error_seen_rd_sync[0], error_seen};
            hart1_seen_rd_sync <= {hart1_seen_rd_sync[0], hart1_commit_seen};
        end
    end
endmodule
