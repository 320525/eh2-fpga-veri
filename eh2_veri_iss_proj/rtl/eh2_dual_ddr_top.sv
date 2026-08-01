`timescale 1ns/1ps

module eh2_dual_ddr_top #(
  parameter logic [31:0] HW_INIT_DCCM_LAST = 32'hf004_fff8,
  parameter logic [31:0] HW_INIT_ICCM_LAST = 32'hee00_fff8
) (
  input  wire        sw3_1,
  input  wire        sw4_1,
  input  wire        core_clk_p,
  input  wire        core_clk_n,
  input  wire        atg_clk_p,
  input  wire        atg_clk_n,
  output wire [7:0]  led,

  input  wire        c0_sys_clk_p,
  input  wire        c0_sys_clk_n,
  output wire        c0_ddr4_act_n,
  output wire [16:0] c0_ddr4_adr,
  output wire [1:0]  c0_ddr4_ba,
  output wire [1:0]  c0_ddr4_bg,
  output wire [0:0]  c0_ddr4_cke,
  output wire [0:0]  c0_ddr4_odt,
  output wire [0:0]  c0_ddr4_cs_n,
  output wire [0:0]  c0_ddr4_ck_t,
  output wire [0:0]  c0_ddr4_ck_c,
  output wire        c0_ddr4_reset_n,
  inout  wire [8:0]  c0_ddr4_dm_dbi_n,
  inout  wire [71:0] c0_ddr4_dq,
  inout  wire [8:0]  c0_ddr4_dqs_c,
  inout  wire [8:0]  c0_ddr4_dqs_t,

  input  wire        c1_sys_clk_p,
  input  wire        c1_sys_clk_n,
  output wire        c1_ddr4_act_n,
  output wire [16:0] c1_ddr4_adr,
  output wire [1:0]  c1_ddr4_ba,
  output wire [1:0]  c1_ddr4_bg,
  output wire [0:0]  c1_ddr4_cke,
  output wire [0:0]  c1_ddr4_odt,
  output wire [0:0]  c1_ddr4_cs_n,
  output wire [0:0]  c1_ddr4_ck_t,
  output wire [0:0]  c1_ddr4_ck_c,
  output wire        c1_ddr4_reset_n,
  inout  wire [8:0]  c1_ddr4_dm_dbi_n,
  inout  wire [71:0] c1_ddr4_dq,
  inout  wire [8:0]  c1_ddr4_dqs_c,
  inout  wire [8:0]  c1_ddr4_dqs_t
);
  wire board_resetn = sw3_1 & sw4_1;

  wire core_clk_ibuf;
  wire core_clk;
  wire atg_clk_ibuf;
  wire atg_clk;
  IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE")) core_clk_ibuf_i (
    .I(core_clk_p), .IB(core_clk_n), .O(core_clk_ibuf)
  );
  BUFG core_clk_bufg_i (.I(core_clk_ibuf), .O(core_clk));
  IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE")) atg_clk_ibuf_i (
    .I(atg_clk_p), .IB(atg_clk_n), .O(atg_clk_ibuf)
  );
  BUFG atg_clk_bufg_i (.I(atg_clk_ibuf), .O(atg_clk));

  // Explicit power-on reset. FPGA register INIT keeps the pipe at zero after
  // configuration even when both active-low board keys are already released.
  // Reset assertion is asynchronous; release requires 16 valid ATG clocks.
  // Consequently all eight LEDs, both MIGs, both ATGs and EH2 start inactive.
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [15:0] power_on_reset_pipe = 16'b0;
  always_ff @(posedge atg_clk or negedge board_resetn) begin
    if (!board_resetn)
      power_on_reset_pipe <= 16'b0;
    else
      power_on_reset_pipe <= {power_on_reset_pipe[14:0], 1'b1};
  end
  wire system_resetn = board_resetn && power_on_reset_pipe[15];
  wire mig_sys_rst   = ~system_resetn;

  wire c0_init_calib_complete;
  wire c0_ui_clk;
  wire c0_ui_rst;
  wire c1_init_calib_complete;
  wire c1_ui_clk;
  wire c1_ui_rst;
  wire c0_mig_resetn = c0_init_calib_complete && !c0_ui_rst;
  wire c1_mig_resetn = c1_init_calib_complete && !c1_ui_rst;

  // Each ATG starts only after its own MIG is calibrated. Completion and
  // status are captured before the ATG is put back into reset permanently.
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] c0_calib_atg_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] c1_calib_atg_sync;
  always_ff @(posedge atg_clk or negedge system_resetn) begin
    if (!system_resetn) begin
      c0_calib_atg_sync <= 2'b00;
      c1_calib_atg_sync <= 2'b00;
    end else begin
      c0_calib_atg_sync <= {c0_calib_atg_sync[0], c0_init_calib_complete};
      c1_calib_atg_sync <= {c1_calib_atg_sync[0], c1_init_calib_complete};
    end
  end

  wire atg0_done;
  wire [31:0] atg0_status;
  wire atg1_done;
  wire [31:0] atg1_status;
  logic atg0_done_latched;
  logic atg0_error_latched;
  logic atg1_done_latched;
  logic atg1_error_latched;
  wire atg0_resetn = system_resetn && c0_calib_atg_sync[1] &&
                     !atg0_done_latched;
  wire atg1_resetn = system_resetn && c1_calib_atg_sync[1] &&
                     !atg1_done_latched;

  always_ff @(posedge atg_clk or negedge system_resetn) begin
    if (!system_resetn) begin
      atg0_done_latched  <= 1'b0;
      atg0_error_latched <= 1'b0;
      atg1_done_latched  <= 1'b0;
      atg1_error_latched <= 1'b0;
    end else begin
      if (!atg0_done_latched && atg0_done) begin
        atg0_done_latched  <= 1'b1;
        atg0_error_latched <= (atg0_status[1:0] != 2'b01);
      end
      if (!atg1_done_latched && atg1_done) begin
        atg1_done_latched  <= 1'b1;
        atg1_error_latched <= (atg1_status[1:0] != 2'b01);
      end
    end
  end

  wire [31:0] atg0_awaddr;
  wire [2:0]  atg0_awprot;
  wire        atg0_awvalid;
  wire        atg0_awready;
  wire [31:0] atg0_wdata;
  wire [3:0]  atg0_wstrb;
  wire        atg0_wvalid;
  wire        atg0_wready;
  wire [1:0]  atg0_bresp;
  wire        atg0_bvalid;
  wire        atg0_bready;
  wire [31:0] atg1_awaddr;
  wire [2:0]  atg1_awprot;
  wire        atg1_awvalid;
  wire        atg1_awready;
  wire [31:0] atg1_wdata;
  wire [3:0]  atg1_wstrb;
  wire        atg1_wvalid;
  wire        atg1_wready;
  wire [1:0]  atg1_bresp;
  wire        atg1_bvalid;
  wire        atg1_bready;

  atg_program atg0_i (
    .s_axi_aclk(atg_clk), .s_axi_aresetn(atg0_resetn),
    .m_axi_lite_ch1_awaddr(atg0_awaddr),
    .m_axi_lite_ch1_awprot(atg0_awprot),
    .m_axi_lite_ch1_awvalid(atg0_awvalid),
    .m_axi_lite_ch1_awready(atg0_awready),
    .m_axi_lite_ch1_wdata(atg0_wdata),
    .m_axi_lite_ch1_wstrb(atg0_wstrb),
    .m_axi_lite_ch1_wvalid(atg0_wvalid),
    .m_axi_lite_ch1_wready(atg0_wready),
    .m_axi_lite_ch1_bresp(atg0_bresp),
    .m_axi_lite_ch1_bvalid(atg0_bvalid),
    .m_axi_lite_ch1_bready(atg0_bready),
    .done(atg0_done), .status(atg0_status)
  );

  atg_data atg1_i (
    .s_axi_aclk(atg_clk), .s_axi_aresetn(atg1_resetn),
    .m_axi_lite_ch1_awaddr(atg1_awaddr),
    .m_axi_lite_ch1_awprot(atg1_awprot),
    .m_axi_lite_ch1_awvalid(atg1_awvalid),
    .m_axi_lite_ch1_awready(atg1_awready),
    .m_axi_lite_ch1_wdata(atg1_wdata),
    .m_axi_lite_ch1_wstrb(atg1_wstrb),
    .m_axi_lite_ch1_wvalid(atg1_wvalid),
    .m_axi_lite_ch1_wready(atg1_wready),
    .m_axi_lite_ch1_bresp(atg1_bresp),
    .m_axi_lite_ch1_bvalid(atg1_bvalid),
    .m_axi_lite_ch1_bready(atg1_bready),
    .done(atg1_done), .status(atg1_status)
  );

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(32),  .ID_WIDTH(4)) atg0_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(32),  .ID_WIDTH(4)) atg1_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) atg0_ui_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) atg1_ui_axi();

  assign atg0_axi.awid = 4'd0;
  assign atg0_axi.awaddr = {1'b0, atg0_awaddr};
  assign atg0_axi.awlen = 8'd0;
  assign atg0_axi.awsize = 3'd2;
  assign atg0_axi.awburst = 2'b01;
  assign atg0_axi.awlock = 1'b0;
  assign atg0_axi.awcache = 4'b0000;
  assign atg0_axi.awprot = atg0_awprot;
  assign atg0_axi.awregion = 4'b0000;
  assign atg0_axi.awqos = 4'b0000;
  assign atg0_axi.awvalid = atg0_awvalid;
  assign atg0_awready = atg0_axi.awready;
  assign atg0_axi.wdata = atg0_wdata;
  assign atg0_axi.wstrb = atg0_wstrb;
  assign atg0_axi.wlast = 1'b1;
  assign atg0_axi.wvalid = atg0_wvalid;
  assign atg0_wready = atg0_axi.wready;
  assign atg0_bresp = atg0_axi.bresp;
  assign atg0_bvalid = atg0_axi.bvalid;
  assign atg0_axi.bready = atg0_bready;
  assign atg0_axi.arid = 4'd0;
  assign atg0_axi.araddr = 33'd0;
  assign atg0_axi.arlen = 8'd0;
  assign atg0_axi.arsize = 3'd2;
  assign atg0_axi.arburst = 2'b01;
  assign atg0_axi.arlock = 1'b0;
  assign atg0_axi.arcache = 4'b0000;
  assign atg0_axi.arprot = 3'b000;
  assign atg0_axi.arregion = 4'b0000;
  assign atg0_axi.arqos = 4'b0000;
  assign atg0_axi.arvalid = 1'b0;
  assign atg0_axi.rready = 1'b1;

  assign atg1_axi.awid = 4'd0;
  assign atg1_axi.awaddr = {1'b0, atg1_awaddr};
  assign atg1_axi.awlen = 8'd0;
  assign atg1_axi.awsize = 3'd2;
  assign atg1_axi.awburst = 2'b01;
  assign atg1_axi.awlock = 1'b0;
  assign atg1_axi.awcache = 4'b0000;
  assign atg1_axi.awprot = atg1_awprot;
  assign atg1_axi.awregion = 4'b0000;
  assign atg1_axi.awqos = 4'b0000;
  assign atg1_axi.awvalid = atg1_awvalid;
  assign atg1_awready = atg1_axi.awready;
  assign atg1_axi.wdata = atg1_wdata;
  assign atg1_axi.wstrb = atg1_wstrb;
  assign atg1_axi.wlast = 1'b1;
  assign atg1_axi.wvalid = atg1_wvalid;
  assign atg1_wready = atg1_axi.wready;
  assign atg1_bresp = atg1_axi.bresp;
  assign atg1_bvalid = atg1_axi.bvalid;
  assign atg1_axi.bready = atg1_bready;
  assign atg1_axi.arid = 4'd0;
  assign atg1_axi.araddr = 33'd0;
  assign atg1_axi.arlen = 8'd0;
  assign atg1_axi.arsize = 3'd2;
  assign atg1_axi.arburst = 2'b01;
  assign atg1_axi.arlock = 1'b0;
  assign atg1_axi.arcache = 4'b0000;
  assign atg1_axi.arprot = 3'b000;
  assign atg1_axi.arregion = 4'b0000;
  assign atg1_axi.arqos = 4'b0000;
  assign atg1_axi.arvalid = 1'b0;
  assign atg1_axi.rready = 1'b1;

  axi32_to_512_cdc atg0_path_i (
    .s_clk(atg_clk), .s_resetn(atg0_resetn),
    .m_clk(c0_ui_clk), .m_resetn(c0_mig_resetn),
    .s_axi(atg0_axi), .m_axi(atg0_ui_axi)
  );
  axi32_to_512_cdc atg1_path_i (
    .s_clk(atg_clk), .s_resetn(atg1_resetn),
    .m_clk(c1_ui_clk), .m_resetn(c1_mig_resetn),
    .s_axi(atg1_axi), .m_axi(atg1_ui_axi)
  );

  // Release the EH2 reset only after both MIGs and both initialization ATGs
  // have completed successfully. The delay mirrors the official testbench's
  // separate debug-reset and core-reset sequencing.
  // Synchronize every source independently before combining it. Combining
  // status bits from several unrelated clocks ahead of one synchronizer would
  // create a multi-clock fan-in CDC hazard.
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] c0_calib_core_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] c1_calib_core_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] atg0_done_core_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] atg1_done_core_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] atg0_error_core_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] atg1_error_core_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] init0_pass_core_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] init1_pass_core_sync;
  wire init0_verify_done;
  wire init0_verify_pass;
  wire init0_verify_error;
  wire init1_verify_done;
  wire init1_verify_pass;
  wire init1_verify_error;
  wire init_success_core = c0_calib_core_sync[1] && c1_calib_core_sync[1] &&
    atg0_done_core_sync[1] && atg1_done_core_sync[1] &&
    !atg0_error_core_sync[1] && !atg1_error_core_sync[1] &&
    init0_pass_core_sync[1] && init1_pass_core_sync[1];
  logic [3:0] reset_release_count;
  logic dbg_rst_l;
  logic core_rst_l;
  always_ff @(posedge core_clk or negedge system_resetn) begin
    if (!system_resetn) begin
      c0_calib_core_sync <= 2'b00;
      c1_calib_core_sync <= 2'b00;
      atg0_done_core_sync <= 2'b00;
      atg1_done_core_sync <= 2'b00;
      atg0_error_core_sync <= 2'b00;
      atg1_error_core_sync <= 2'b00;
      init0_pass_core_sync <= 2'b00;
      init1_pass_core_sync <= 2'b00;
      reset_release_count <= 4'd0;
      dbg_rst_l <= 1'b0;
      core_rst_l <= 1'b0;
    end else begin
      c0_calib_core_sync <= {c0_calib_core_sync[0], c0_init_calib_complete};
      c1_calib_core_sync <= {c1_calib_core_sync[0], c1_init_calib_complete};
      atg0_done_core_sync <= {atg0_done_core_sync[0], atg0_done_latched};
      atg1_done_core_sync <= {atg1_done_core_sync[0], atg1_done_latched};
      atg0_error_core_sync <= {atg0_error_core_sync[0], atg0_error_latched};
      atg1_error_core_sync <= {atg1_error_core_sync[0], atg1_error_latched};
      init0_pass_core_sync <= {init0_pass_core_sync[0], init0_verify_pass};
      init1_pass_core_sync <= {init1_pass_core_sync[0], init1_verify_pass};
      if (!init_success_core) begin
        reset_release_count <= 4'd0;
        dbg_rst_l <= 1'b0;
        core_rst_l <= 1'b0;
      end else begin
        if (reset_release_count != 4'hf)
          reset_release_count <= reset_release_count + 1'b1;
        if (reset_release_count >= 4'd2)
          dbg_rst_l <= 1'b1;
        if (reset_release_count >= 4'd5)
          core_rst_l <= 1'b1;
      end
    end
  end

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(64),  .ID_WIDTH(4)) ifu_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(64),  .ID_WIDTH(4)) lsu_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ifu_ui_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) lsu_ui_axi();
  logic any_lsu_write_seen;
  logic any_ifu_fetch_seen;
  logic any_ifu_read_seen;
  logic any_lsu_read_request_seen;
  logic any_lsu_read_seen;
  logic terminal_write_complete;
  logic terminal_write_error;
  logic eh2_hw_init_busy;
  logic eh2_hw_init_done;
  logic eh2_hw_init_error;

  eh2_core_wrapper_hw #(
    .HW_INIT_DCCM_LAST(HW_INIT_DCCM_LAST),
    .HW_INIT_ICCM_LAST(HW_INIT_ICCM_LAST)
  ) eh2_i (
    .clk(core_clk), .rst_l(core_rst_l), .dbg_rst_l(dbg_rst_l),
    .hw_init_busy(eh2_hw_init_busy), .hw_init_done(eh2_hw_init_done),
    .hw_init_error(eh2_hw_init_error),
    .any_lsu_write_seen(any_lsu_write_seen),
    .terminal_write_complete(terminal_write_complete),
    .terminal_write_error(terminal_write_error),
    .ifu_axi(ifu_axi), .lsu_axi(lsu_axi)
  );

  // Latch the first completed IFU address handshake. A sticky indication is
  // required because an AXI fetch pulse is far too short to see on a board
  // LED. The flag can only assert after core_rst_l releases, which in turn
  // requires both MIG/ATG initializers to have completed successfully.
  always_ff @(posedge core_clk or negedge core_rst_l) begin
    if (!core_rst_l) begin
      any_ifu_fetch_seen <= 1'b0;
      any_ifu_read_seen <= 1'b0;
      any_lsu_read_request_seen <= 1'b0;
      any_lsu_read_seen <= 1'b0;
    end else begin
      if (ifu_axi.arvalid && ifu_axi.arready)
        any_ifu_fetch_seen <= 1'b1;
      if (ifu_axi.rvalid && ifu_axi.rready &&
          (ifu_axi.rresp == 2'b00) && ifu_axi.rlast)
        any_ifu_read_seen <= 1'b1;
      if (lsu_axi.arvalid && lsu_axi.arready)
        any_lsu_read_request_seen <= 1'b1;
      if (lsu_axi.rvalid && lsu_axi.rready &&
          (lsu_axi.rresp == 2'b00) && lsu_axi.rlast)
        any_lsu_read_seen <= 1'b1;
    end
  end

  axi64_to_512_cdc ifu_path_i (
    .s_clk(core_clk), .s_resetn(core_rst_l),
    .m_clk(c0_ui_clk), .m_resetn(c0_mig_resetn),
    .s_axi(ifu_axi), .m_axi(ifu_ui_axi)
  );
  axi64_to_512_cdc lsu_path_i (
    .s_clk(core_clk), .s_resetn(core_rst_l),
    .m_clk(c1_ui_clk), .m_resetn(c1_mig_resetn),
    .s_axi(lsu_axi), .m_axi(lsu_ui_axi)
  );

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] atg0_done_ui_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] atg1_done_ui_sync;
  always_ff @(posedge c0_ui_clk) begin
    if (!c0_mig_resetn) atg0_done_ui_sync <= 2'b00;
    else atg0_done_ui_sync <= {atg0_done_ui_sync[0], atg0_done_latched};
  end
  always_ff @(posedge c1_ui_clk) begin
    if (!c1_mig_resetn) atg1_done_ui_sync <= 2'b00;
    else atg1_done_ui_sync <= {atg1_done_ui_sync[0], atg1_done_latched};
  end

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) init0_checker_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) init1_checker_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr0_init_phase_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_init_phase_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr0_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_cpu_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) checker_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_axi();

  wire init0_verify_busy;
  wire init1_verify_busy;
  ddr_init_readback_checker #(.PROGRAM_IMAGE(1'b1)) init0_checker_i (
    .clk(c0_ui_clk), .resetn(c0_mig_resetn),
    .start(atg0_done_ui_sync[1]), .busy(init0_verify_busy),
    .done(init0_verify_done), .pass(init0_verify_pass),
    .error(init0_verify_error), .m_axi(init0_checker_axi)
  );
  ddr_init_readback_checker #(.PROGRAM_IMAGE(1'b0)) init1_checker_i (
    .clk(c1_ui_clk), .resetn(c1_mig_resetn),
    .start(atg1_done_ui_sync[1]), .busy(init1_verify_busy),
    .done(init1_verify_done), .pass(init1_verify_pass),
    .error(init1_verify_error), .m_axi(init1_checker_axi)
  );

  // Each DDR bus changes ownership in one direction only:
  // write-only ATG -> initialization readback checker -> EH2.
  axi_owner_mux2 ddr0_atg_to_verify_i (
    .select_b(atg0_done_ui_sync[1]), .master_a(atg0_ui_axi),
    .master_b(init0_checker_axi), .slave_out(ddr0_init_phase_axi)
  );
  axi_owner_mux2 ddr0_verify_to_cpu_i (
    .select_b(init0_verify_pass), .master_a(ddr0_init_phase_axi),
    .master_b(ifu_ui_axi), .slave_out(ddr0_axi)
  );
  axi_owner_mux2 ddr1_atg_to_verify_i (
    .select_b(atg1_done_ui_sync[1]), .master_a(atg1_ui_axi),
    .master_b(init1_checker_axi), .slave_out(ddr1_init_phase_axi)
  );
  axi_owner_mux2 ddr1_verify_to_cpu_i (
    .select_b(init1_verify_pass), .master_a(ddr1_init_phase_axi),
    .master_b(lsu_ui_axi), .slave_out(ddr1_cpu_axi)
  );

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] terminal_ui_sync;
  logic checker_owns_bus;
  always_ff @(posedge c1_ui_clk) begin
    if (!c1_mig_resetn) begin
      terminal_ui_sync <= 2'b00;
      checker_owns_bus <= 1'b0;
    end else begin
      terminal_ui_sync <= {terminal_ui_sync[0], terminal_write_complete};
      if (terminal_ui_sync[1])
        checker_owns_bus <= 1'b1;
    end
  end

  wire checker_busy;
  wire checker_done;
  wire checker_pass;
  wire checker_error;
  ddr_result_checker checker_i (
    .clk(c1_ui_clk), .resetn(c1_mig_resetn), .start(checker_owns_bus),
    .busy(checker_busy), .done(checker_done), .pass(checker_pass),
    .error(checker_error), .m_axi(checker_axi)
  );
  axi_owner_mux2 ddr1_check_mux_i (
    .select_b(checker_owns_bus), .master_a(ddr1_cpu_axi),
    .master_b(checker_axi), .slave_out(ddr1_axi)
  );

  // LEDs are active high. Force every LED off while either board reset is
  // asserted; after reset release each bit may turn on only when its sticky
  // status condition has been reached.
  wire [7:0] led_status;
  assign led_status[0] = atg0_done_latched && !atg0_error_latched &&
                         init0_verify_done && init0_verify_pass &&
                         !init0_verify_error;
  assign led_status[1] = atg1_done_latched && !atg1_error_latched &&
                         init1_verify_done && init1_verify_pass &&
                         !init1_verify_error;
  assign led_status[2] = any_ifu_fetch_seen;
  assign led_status[3] = any_ifu_read_seen;
  assign led_status[4] = any_lsu_read_request_seen;
  assign led_status[5] = any_lsu_read_seen;
  assign led_status[6] = any_lsu_write_seen;
  assign led_status[7] = eh2_hw_init_done && !eh2_hw_init_error &&
                         checker_done && checker_pass && !checker_error;
  assign led = system_resetn ? led_status : 8'b0000_0000;

  ddr4_0 ddr0_i (
    .c0_init_calib_complete(c0_init_calib_complete), .dbg_clk(),
    .c0_sys_clk_p(c0_sys_clk_p), .c0_sys_clk_n(c0_sys_clk_n), .dbg_bus(),
    .c0_ddr4_adr(c0_ddr4_adr), .c0_ddr4_ba(c0_ddr4_ba),
    .c0_ddr4_cke(c0_ddr4_cke), .c0_ddr4_cs_n(c0_ddr4_cs_n),
    .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n), .c0_ddr4_dq(c0_ddr4_dq),
    .c0_ddr4_dqs_c(c0_ddr4_dqs_c), .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
    .c0_ddr4_odt(c0_ddr4_odt), .c0_ddr4_bg(c0_ddr4_bg),
    .c0_ddr4_reset_n(c0_ddr4_reset_n), .c0_ddr4_act_n(c0_ddr4_act_n),
    .c0_ddr4_ck_c(c0_ddr4_ck_c), .c0_ddr4_ck_t(c0_ddr4_ck_t),
    .c0_ddr4_ui_clk(c0_ui_clk), .c0_ddr4_ui_clk_sync_rst(c0_ui_rst),
    .c0_ddr4_aresetn(c0_mig_resetn),
    .c0_ddr4_s_axi_ctrl_awvalid(1'b0), .c0_ddr4_s_axi_ctrl_awready(),
    .c0_ddr4_s_axi_ctrl_awaddr(32'd0), .c0_ddr4_s_axi_ctrl_wvalid(1'b0),
    .c0_ddr4_s_axi_ctrl_wready(), .c0_ddr4_s_axi_ctrl_wdata(32'd0),
    .c0_ddr4_s_axi_ctrl_bvalid(), .c0_ddr4_s_axi_ctrl_bready(1'b1),
    .c0_ddr4_s_axi_ctrl_bresp(), .c0_ddr4_s_axi_ctrl_arvalid(1'b0),
    .c0_ddr4_s_axi_ctrl_arready(), .c0_ddr4_s_axi_ctrl_araddr(32'd0),
    .c0_ddr4_s_axi_ctrl_rvalid(), .c0_ddr4_s_axi_ctrl_rready(1'b1),
    .c0_ddr4_s_axi_ctrl_rdata(), .c0_ddr4_s_axi_ctrl_rresp(),
    .c0_ddr4_interrupt(),
    .c0_ddr4_s_axi_awid(ddr0_axi.awid), .c0_ddr4_s_axi_awaddr(ddr0_axi.awaddr),
    .c0_ddr4_s_axi_awlen(ddr0_axi.awlen), .c0_ddr4_s_axi_awsize(ddr0_axi.awsize),
    .c0_ddr4_s_axi_awburst(ddr0_axi.awburst), .c0_ddr4_s_axi_awlock(ddr0_axi.awlock),
    .c0_ddr4_s_axi_awcache(ddr0_axi.awcache), .c0_ddr4_s_axi_awprot(ddr0_axi.awprot),
    .c0_ddr4_s_axi_awqos(ddr0_axi.awqos), .c0_ddr4_s_axi_awvalid(ddr0_axi.awvalid),
    .c0_ddr4_s_axi_awready(ddr0_axi.awready), .c0_ddr4_s_axi_wdata(ddr0_axi.wdata),
    .c0_ddr4_s_axi_wstrb(ddr0_axi.wstrb), .c0_ddr4_s_axi_wlast(ddr0_axi.wlast),
    .c0_ddr4_s_axi_wvalid(ddr0_axi.wvalid), .c0_ddr4_s_axi_wready(ddr0_axi.wready),
    .c0_ddr4_s_axi_bready(ddr0_axi.bready), .c0_ddr4_s_axi_bid(ddr0_axi.bid),
    .c0_ddr4_s_axi_bresp(ddr0_axi.bresp), .c0_ddr4_s_axi_bvalid(ddr0_axi.bvalid),
    .c0_ddr4_s_axi_arid(ddr0_axi.arid), .c0_ddr4_s_axi_araddr(ddr0_axi.araddr),
    .c0_ddr4_s_axi_arlen(ddr0_axi.arlen), .c0_ddr4_s_axi_arsize(ddr0_axi.arsize),
    .c0_ddr4_s_axi_arburst(ddr0_axi.arburst), .c0_ddr4_s_axi_arlock(ddr0_axi.arlock),
    .c0_ddr4_s_axi_arcache(ddr0_axi.arcache), .c0_ddr4_s_axi_arprot(ddr0_axi.arprot),
    .c0_ddr4_s_axi_arqos(ddr0_axi.arqos), .c0_ddr4_s_axi_arvalid(ddr0_axi.arvalid),
    .c0_ddr4_s_axi_arready(ddr0_axi.arready), .c0_ddr4_s_axi_rready(ddr0_axi.rready),
    .c0_ddr4_s_axi_rlast(ddr0_axi.rlast), .c0_ddr4_s_axi_rvalid(ddr0_axi.rvalid),
    .c0_ddr4_s_axi_rresp(ddr0_axi.rresp), .c0_ddr4_s_axi_rid(ddr0_axi.rid),
    .c0_ddr4_s_axi_rdata(ddr0_axi.rdata), .sys_rst(mig_sys_rst)
  );

  ddr4_1 ddr1_i (
    .c0_init_calib_complete(c1_init_calib_complete), .dbg_clk(),
    .c0_sys_clk_p(c1_sys_clk_p), .c0_sys_clk_n(c1_sys_clk_n), .dbg_bus(),
    .c0_ddr4_adr(c1_ddr4_adr), .c0_ddr4_ba(c1_ddr4_ba),
    .c0_ddr4_cke(c1_ddr4_cke), .c0_ddr4_cs_n(c1_ddr4_cs_n),
    .c0_ddr4_dm_dbi_n(c1_ddr4_dm_dbi_n), .c0_ddr4_dq(c1_ddr4_dq),
    .c0_ddr4_dqs_c(c1_ddr4_dqs_c), .c0_ddr4_dqs_t(c1_ddr4_dqs_t),
    .c0_ddr4_odt(c1_ddr4_odt), .c0_ddr4_bg(c1_ddr4_bg),
    .c0_ddr4_reset_n(c1_ddr4_reset_n), .c0_ddr4_act_n(c1_ddr4_act_n),
    .c0_ddr4_ck_c(c1_ddr4_ck_c), .c0_ddr4_ck_t(c1_ddr4_ck_t),
    .c0_ddr4_ui_clk(c1_ui_clk), .c0_ddr4_ui_clk_sync_rst(c1_ui_rst),
    .c0_ddr4_aresetn(c1_mig_resetn),
    .c0_ddr4_s_axi_ctrl_awvalid(1'b0), .c0_ddr4_s_axi_ctrl_awready(),
    .c0_ddr4_s_axi_ctrl_awaddr(32'd0), .c0_ddr4_s_axi_ctrl_wvalid(1'b0),
    .c0_ddr4_s_axi_ctrl_wready(), .c0_ddr4_s_axi_ctrl_wdata(32'd0),
    .c0_ddr4_s_axi_ctrl_bvalid(), .c0_ddr4_s_axi_ctrl_bready(1'b1),
    .c0_ddr4_s_axi_ctrl_bresp(), .c0_ddr4_s_axi_ctrl_arvalid(1'b0),
    .c0_ddr4_s_axi_ctrl_arready(), .c0_ddr4_s_axi_ctrl_araddr(32'd0),
    .c0_ddr4_s_axi_ctrl_rvalid(), .c0_ddr4_s_axi_ctrl_rready(1'b1),
    .c0_ddr4_s_axi_ctrl_rdata(), .c0_ddr4_s_axi_ctrl_rresp(),
    .c0_ddr4_interrupt(),
    .c0_ddr4_s_axi_awid(ddr1_axi.awid), .c0_ddr4_s_axi_awaddr(ddr1_axi.awaddr),
    .c0_ddr4_s_axi_awlen(ddr1_axi.awlen), .c0_ddr4_s_axi_awsize(ddr1_axi.awsize),
    .c0_ddr4_s_axi_awburst(ddr1_axi.awburst), .c0_ddr4_s_axi_awlock(ddr1_axi.awlock),
    .c0_ddr4_s_axi_awcache(ddr1_axi.awcache), .c0_ddr4_s_axi_awprot(ddr1_axi.awprot),
    .c0_ddr4_s_axi_awqos(ddr1_axi.awqos), .c0_ddr4_s_axi_awvalid(ddr1_axi.awvalid),
    .c0_ddr4_s_axi_awready(ddr1_axi.awready), .c0_ddr4_s_axi_wdata(ddr1_axi.wdata),
    .c0_ddr4_s_axi_wstrb(ddr1_axi.wstrb), .c0_ddr4_s_axi_wlast(ddr1_axi.wlast),
    .c0_ddr4_s_axi_wvalid(ddr1_axi.wvalid), .c0_ddr4_s_axi_wready(ddr1_axi.wready),
    .c0_ddr4_s_axi_bready(ddr1_axi.bready), .c0_ddr4_s_axi_bid(ddr1_axi.bid),
    .c0_ddr4_s_axi_bresp(ddr1_axi.bresp), .c0_ddr4_s_axi_bvalid(ddr1_axi.bvalid),
    .c0_ddr4_s_axi_arid(ddr1_axi.arid), .c0_ddr4_s_axi_araddr(ddr1_axi.araddr),
    .c0_ddr4_s_axi_arlen(ddr1_axi.arlen), .c0_ddr4_s_axi_arsize(ddr1_axi.arsize),
    .c0_ddr4_s_axi_arburst(ddr1_axi.arburst), .c0_ddr4_s_axi_arlock(ddr1_axi.arlock),
    .c0_ddr4_s_axi_arcache(ddr1_axi.arcache), .c0_ddr4_s_axi_arprot(ddr1_axi.arprot),
    .c0_ddr4_s_axi_arqos(ddr1_axi.arqos), .c0_ddr4_s_axi_arvalid(ddr1_axi.arvalid),
    .c0_ddr4_s_axi_arready(ddr1_axi.arready), .c0_ddr4_s_axi_rready(ddr1_axi.rready),
    .c0_ddr4_s_axi_rlast(ddr1_axi.rlast), .c0_ddr4_s_axi_rvalid(ddr1_axi.rvalid),
    .c0_ddr4_s_axi_rresp(ddr1_axi.rresp), .c0_ddr4_s_axi_rid(ddr1_axi.rid),
    .c0_ddr4_s_axi_rdata(ddr1_axi.rdata), .sys_rst(mig_sys_rst)
  );
endmodule
