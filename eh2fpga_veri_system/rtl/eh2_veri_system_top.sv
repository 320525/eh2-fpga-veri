`timescale 1ns/1ps

module eh2_veri_system_top #(
  // Hardware keeps PHY initialization enabled.  RGMII-level presimulation
  // sets this parameter only because no serial MDIO PHY model is present.
  parameter integer PHY_INIT_BYPASS = 0,
  // Hardware clears the entire low 4 GiB.  Presimulation may reduce only
  // this length while retaining the same 512-bit fill master and AXI path.
  parameter logic [32:0] DATA_CLEAR_BYTES = 33'h1_0000_0000
) (
  input  wire        sw3_1,
  input  wire        sw4_1,
  input  wire        core_clk_p,
  input  wire        core_clk_n,
  input  wire        atg_clk_p,
  input  wire        atg_clk_n,
  input  wire        refclk_p,
  input  wire        refclk_n,
  output wire [7:0]  led,

  output wire [3:0]  rgmii_txd,
  output wire        rgmii_tx_ctl,
  output wire        rgmii_txc,
  input  wire [3:0]  rgmii_rxd,
  input  wire        rgmii_rx_ctl,
  input  wire        rgmii_rxc,
  inout  wire        mdio,
  output wire        mdc,
  output wire        phy_resetn,

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
  import eh2_system_pkg::*;

  wire board_resetn = sw3_1 && sw4_1;
  wire core_clk_ibuf, core_clk;
  wire ctrl_clk_ibuf, ctrl_clk;
  wire refclk_ibuf, refclk;
  IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE"))
    core_clk_ibuf_i (.I(core_clk_p), .IB(core_clk_n), .O(core_clk_ibuf));
  BUFG core_clk_buf_i (.I(core_clk_ibuf), .O(core_clk));
  IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE"))
    ctrl_clk_ibuf_i (.I(atg_clk_p), .IB(atg_clk_n), .O(ctrl_clk_ibuf));
  BUFG ctrl_clk_buf_i (.I(ctrl_clk_ibuf), .O(ctrl_clk));
  IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE"))
    refclk_ibuf_i (.I(refclk_p), .IB(refclk_n), .O(refclk_ibuf));
  BUFG refclk_buf_i (.I(refclk_ibuf), .O(refclk));

  // The 50 MHz processor clock feeds the same validated 125 MHz MMCM used by
  // log_eh2_crc_fpga.  This one clock drives both TEMAC GTX and CRC reduction.
  wire mmcm_fb_raw, mmcm_fb, clk125_raw, clk125, mmcm_locked;
  MMCME4_BASE #(
    .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(20.000),
    .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(20.000),
    .CLKOUT0_DIVIDE_F(8.000), .STARTUP_WAIT("FALSE")
  ) clock125_mmcm_i (
    .CLKIN1(core_clk), .CLKFBIN(mmcm_fb), .RST(!board_resetn),
    .PWRDWN(1'b0), .CLKFBOUT(mmcm_fb_raw), .CLKOUT0(clk125_raw),
    .LOCKED(mmcm_locked)
  );
  BUFG mmcm_fb_buf_i (.I(mmcm_fb_raw), .O(mmcm_fb));
  BUFG clk125_buf_i (.I(clk125_raw), .O(clk125));

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [15:0] por_pipe = 16'b0;
  always_ff @(posedge ctrl_clk or negedge board_resetn) begin
    if (!board_resetn || !mmcm_locked)
      por_pipe <= 16'b0;
    else
      por_pipe <= {por_pipe[14:0],1'b1};
  end
  wire hard_resetn = board_resetn && por_pipe[15];

  // ----------------------------------------------------------------------
  // One full-duplex Ethernet MAC and exact receive-path classification.
  // ----------------------------------------------------------------------
  logic [15:0] mac_rx_data;
  logic mac_rx_valid, mac_rx_last, mac_rx_ready;
  logic [7:0] mac_tx_data;
  logic mac_tx_valid, mac_tx_last, mac_tx_ready;
  logic mac_config_done, mac_config_error;
  logic phy_init_busy, phy_init_done, phy_init_success;
  logic [3:0] phy_init_error;
  logic phy_link_up, phy_autoneg_complete;
  logic [3:0] rx_fifo_status, tx_fifo_status;
  logic rx_fifo_overflow, tx_fifo_overflow;
  logic inband_link_status, inband_duplex_status, mac_irq;
  logic [1:0] inband_clock_speed;

  ethernet_subsystem #(.PHY_INIT_BYPASS(PHY_INIT_BYPASS)) eth_i (
    .gtx_clk(clk125), .refclk, .ctrl_clk, .hard_resetn,
    .rx_axis_tdata(mac_rx_data), .rx_axis_tvalid(mac_rx_valid),
    .rx_axis_tlast(mac_rx_last), .rx_axis_tready(mac_rx_ready),
    .tx_axis_tdata(mac_tx_data), .tx_axis_tvalid(mac_tx_valid),
    .tx_axis_tlast(mac_tx_last), .tx_axis_tready(mac_tx_ready),
    .rgmii_txd, .rgmii_tx_ctl, .rgmii_txc,
    .rgmii_rxd, .rgmii_rx_ctl, .rgmii_rxc, .mdio, .mdc, .phy_resetn,
    .mac_config_done, .mac_config_error, .phy_init_busy, .phy_init_done,
    .phy_init_success, .phy_init_error, .phy_link_up,
    .phy_autoneg_complete, .rx_fifo_status, .rx_fifo_overflow,
    .tx_fifo_status, .tx_fifo_overflow, .inband_link_status,
    .inband_clock_speed, .inband_duplex_status, .mac_irq
  );

  logic [15:0] program_stream_data;
  logic program_stream_valid, program_stream_last, program_stream_ready;
  logic [15:0] info_wr_data;
  logic info_wr_last, info_wr_en, info_rx_full, info_rx_overflow;
  logic program_frame_accepted, info_frame_accepted;
  logic rx_frame_buffer_overflow, rx_frame_length_error;
  logic [31:0] dropped_frame_count;

  eth_rx_frame_classifier rx_classifier_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .s_axis_tdata(mac_rx_data), .s_axis_tvalid(mac_rx_valid),
    .s_axis_tlast(mac_rx_last), .s_axis_tready(mac_rx_ready),
    .program_tdata(program_stream_data),
    .program_tvalid(program_stream_valid),
    .program_tlast(program_stream_last),
    .program_tready(program_stream_ready),
    .info_wr_data, .info_wr_last, .info_wr_en,
    .info_fifo_full(info_rx_full),
    .program_frame_accepted, .info_frame_accepted,
    .frame_buffer_overflow(rx_frame_buffer_overflow),
    .recognized_length_error(rx_frame_length_error),
    .dropped_frame_count
  );

  logic info_rx_rd_en, info_rx_empty, info_rx_last;
  logic [15:0] info_rx_data;
  logic system_program_end_pulse, malformed_info_frame;
  system_info_rx_fifo info_rx_fifo_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .wr_en(info_wr_en), .wr_data(info_wr_data), .wr_last(info_wr_last),
    .full(info_rx_full), .overflow(info_rx_overflow),
    .rd_en(info_rx_rd_en), .rd_data(info_rx_data),
    .rd_last(info_rx_last), .empty(info_rx_empty)
  );
  system_info_rx_decoder info_decoder_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .fifo_data(info_rx_data), .fifo_last(info_rx_last),
    .fifo_empty(info_rx_empty), .fifo_rd_en(info_rx_rd_en),
    .program_end_pulse(system_program_end_pulse),
    .malformed_frame(malformed_info_frame)
  );

  // ----------------------------------------------------------------------
  // Program DMA, controller-owned information FIFO and TX arbitration.
  // ----------------------------------------------------------------------
  logic ready_soft_reset;
  wire program_resetn = hard_resetn && !ready_soft_reset;
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(32), .ID_WIDTH(4)) program_axi32();
  logic [31:0] program_frame_count, program_dma_write_addr;
  logic [31:0] program_dma_done_count;
  logic program_frame_done, program_dma_done, program_dma_error;
  logic program_frame_length_error, program_dma_busy, datamover_error;
  logic [31:0] last_dma_status;
  logic program_first_write_pulse;
  ddr0_owner_t ddr0_owner;
  wire program_path_enable = (ddr0_owner == DDR0_OWNER_PROGRAM);
  wire program_dma_input_ready;
  assign program_stream_ready = program_path_enable ?
                                program_dma_input_ready : 1'b1;
  program_dma_subsystem program_dma_i (
    .clk(ctrl_clk), .resetn(program_resetn),
    .s_axis_tdata(program_stream_data),
    .s_axis_tvalid(program_stream_valid && program_path_enable),
    .s_axis_tlast(program_stream_last),
    .s_axis_tready(program_dma_input_ready),
    .frame_count(program_frame_count), .dma_write_addr(program_dma_write_addr),
    .frame_done(program_frame_done), .dma_done(program_dma_done),
    .dma_error(program_dma_error),
    .frame_length_error(program_frame_length_error),
    .last_dma_status, .dma_busy(program_dma_busy),
    .datamover_error, .first_write_pulse(program_first_write_pulse),
    .m_axi(program_axi32)
  );
  always_ff @(posedge ctrl_clk or negedge program_resetn) begin
    if (!program_resetn)
      program_dma_done_count <= 32'b0;
    else if (program_dma_done && !program_dma_error && !datamover_error)
      program_dma_done_count <= program_dma_done_count + 32'd1;
  end

  logic info_tx_push, info_tx_full, info_tx_overflow;
  logic [31:0] info_tx_code, info_fifo_code;
  logic info_fifo_empty, info_fifo_rd_en;
  system_info_tx_fifo info_tx_fifo_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .wr_en(info_tx_push), .wr_code(info_tx_code),
    .full(info_tx_full), .overflow(info_tx_overflow),
    .rd_en(info_fifo_rd_en), .rd_code(info_fifo_code),
    .empty(info_fifo_empty)
  );

  logic [7:0] info_tx_data;
  logic info_tx_valid, info_tx_last, info_tx_ready;
  logic info_frame_done;
  logic [31:0] info_sent_code;
  system_info_tx_formatter info_formatter_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .fifo_code(info_fifo_code), .fifo_empty(info_fifo_empty),
    .fifo_rd_en(info_fifo_rd_en), .m_axis_tdata(info_tx_data),
    .m_axis_tvalid(info_tx_valid), .m_axis_tlast(info_tx_last),
    .m_axis_tready(info_tx_ready), .frame_done(info_frame_done),
    .sent_code(info_sent_code)
  );

  // ----------------------------------------------------------------------
  // Dual DDR, fixed masters and phase-safe ownership.
  // ----------------------------------------------------------------------
  logic c0_ui_clk, c0_ui_resetn, c0_calib_done;
  logic c1_ui_clk, c1_ui_resetn, c1_calib_done;
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr0_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_axi();
  dual_ddr_mig_wrapper mig_i (
    .hard_resetn, .c0_sys_clk_p, .c0_sys_clk_n,
    .c1_sys_clk_p, .c1_sys_clk_n,
    .c0_ui_clk, .c0_ui_resetn, .c0_calib_done,
    .c1_ui_clk, .c1_ui_resetn, .c1_calib_done,
    .c0_axi(ddr0_axi), .c1_axi(ddr1_axi),
    .c0_ddr4_act_n, .c0_ddr4_adr, .c0_ddr4_ba, .c0_ddr4_bg,
    .c0_ddr4_cke, .c0_ddr4_odt, .c0_ddr4_cs_n,
    .c0_ddr4_ck_t, .c0_ddr4_ck_c, .c0_ddr4_reset_n,
    .c0_ddr4_dm_dbi_n, .c0_ddr4_dq, .c0_ddr4_dqs_c, .c0_ddr4_dqs_t,
    .c1_ddr4_act_n, .c1_ddr4_adr, .c1_ddr4_ba, .c1_ddr4_bg,
    .c1_ddr4_cke, .c1_ddr4_odt, .c1_ddr4_cs_n,
    .c1_ddr4_ck_t, .c1_ddr4_ck_c, .c1_ddr4_reset_n,
    .c1_ddr4_dm_dbi_n, .c1_ddr4_dq, .c1_ddr4_dqs_c, .c1_ddr4_dqs_t
  );

  // The MIG completion flags originate in two independent UI clock domains.
  // Synchronize their stable levels into the 100 MHz control domain exactly
  // as the validated mac_fifo_dma_proj receive/DMA path does.
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [1:0] c0_calib_complete_sync_reg;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [1:0] c1_calib_complete_sync_reg;
  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      c0_calib_complete_sync_reg <= 2'b00;
      c1_calib_complete_sync_reg <= 2'b00;
    end else begin
      c0_calib_complete_sync_reg <= {c0_calib_complete_sync_reg[0],
                                     c0_calib_done};
      c1_calib_complete_sync_reg <= {c1_calib_complete_sync_reg[0],
                                     c1_calib_done};
    end
  end
  wire c0_calib_done_ctrl = c0_calib_complete_sync_reg[1];
  wire c1_calib_done_ctrl = c1_calib_complete_sync_reg[1];

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) program_ui_axi();
  axi32_to_512_cdc program_cdc_i (
    .s_clk(ctrl_clk), .s_resetn(program_resetn),
    .m_clk(c0_ui_clk), .m_resetn(c0_ui_resetn),
    .s_axi(program_axi32), .m_axi(program_ui_axi)
  );

  logic data_atg_start_ctrl, data_atg_start_hold;
  logic data_atg_done_core, data_atg_error_core;
  logic [31:0] data_atg_status;
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(32), .ID_WIDTH(4)) data_atg_axi32();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) data_atg_ui_axi();
  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn)
      data_atg_start_hold <= 1'b0;
    else if (data_atg_start_ctrl)
      data_atg_start_hold <= 1'b1;
  end
  logic [0:0] data_atg_start_core_sync;
  sync_bits #(.WIDTH(1)) data_atg_start_sync_i (
    .clk(core_clk), .resetn(hard_resetn),
    .async_in(data_atg_start_hold), .sync_out(data_atg_start_core_sync)
  );
  data_test_atg_wrapper data_atg_i (
    .clk(core_clk), .hard_resetn, .start(data_atg_start_core_sync[0]),
    .done(data_atg_done_core), .error(data_atg_error_core),
    .status(data_atg_status), .m_axi(data_atg_axi32)
  );
  axi32_to_512_cdc data_atg_cdc_i (
    .s_clk(core_clk), .s_resetn(hard_resetn),
    .m_clk(c1_ui_clk), .m_resetn(c1_ui_resetn),
    .s_axi(data_atg_axi32), .m_axi(data_atg_ui_axi)
  );

  logic instr_check_start_ctrl, data_check_start_ctrl, zero_start_ctrl;
  logic instr_check_start_hold, data_check_start_hold, zero_start_hold;
  logic instr_check_done_ui, instr_check_pass_ui, instr_check_error_ui;
  logic data_check_done_ui, data_check_pass_ui, data_check_error_ui;
  logic zero_done_ui, zero_error_ui, zero_busy_ui;
  logic [32:0] zero_bytes_completed;
  logic [31:0] instr_mismatch_count, data_mismatch_count;
  logic [2:0] op_done_sync;
  logic [2:0] op_start_async;
  logic zero_done_armed;
  logic zero_done_ctrl;

  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      instr_check_start_hold <= 1'b0;
      data_check_start_hold  <= 1'b0;
      zero_start_hold        <= 1'b0;
      zero_done_armed        <= 1'b0;
    end else begin
      if (instr_check_start_ctrl) instr_check_start_hold <= 1'b1;
      if (data_check_start_ctrl)  data_check_start_hold  <= 1'b1;
      if (op_done_sync[0]) instr_check_start_hold <= 1'b0;
      if (op_done_sync[1]) data_check_start_hold  <= 1'b0;

      // zero_done is deliberately sticky in the DDR UI domain.  READY can
      // be entered repeatedly, so a new request must first observe the
      // engine clear its old done before the following done is accepted.
      if (zero_start_ctrl) begin
        zero_start_hold <= 1'b1;
        zero_done_armed <= 1'b0;
      end else begin
        if (zero_start_hold && !op_status_ctrl[4])
          zero_done_armed <= 1'b1;
        if (zero_done_armed && op_status_ctrl[4]) begin
          zero_start_hold <= 1'b0;
          zero_done_armed <= 1'b0;
        end
      end
    end
  end
  assign op_start_async = {
    zero_start_hold,data_check_start_hold,instr_check_start_hold
  };
  logic [0:0] instr_start_ui, data_start_ui, zero_start_ui;
  sync_bits #(.WIDTH(1)) instr_start_sync_i (
    .clk(c0_ui_clk), .resetn(c0_ui_resetn),
    .async_in(op_start_async[0]), .sync_out(instr_start_ui)
  );
  sync_bits #(.WIDTH(1)) data_start_sync_i (
    .clk(c1_ui_clk), .resetn(c1_ui_resetn),
    .async_in(op_start_async[1]), .sync_out(data_start_ui)
  );
  sync_bits #(.WIDTH(1)) zero_start_sync_i (
    .clk(c1_ui_clk), .resetn(c1_ui_resetn),
    .async_in(op_start_async[2]), .sync_out(zero_start_ui)
  );

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) instr_check_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) data_check_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) zero_axi();
  ddr_read_compare_master #(.BASE_ADDR(33'h0_8000_0000))
    instr_checker_i (
      .clk(c0_ui_clk), .resetn(c0_ui_resetn), .start(instr_start_ui[0]),
      .busy(), .done(instr_check_done_ui), .pass(instr_check_pass_ui),
      .error(instr_check_error_ui), .mismatch_count(instr_mismatch_count),
      .m_axi(instr_check_axi)
    );
  ddr_read_compare_master #(.BASE_ADDR(33'h0))
    data_checker_i (
      .clk(c1_ui_clk), .resetn(c1_ui_resetn), .start(data_start_ui[0]),
      .busy(), .done(data_check_done_ui), .pass(data_check_pass_ui),
      .error(data_check_error_ui), .mismatch_count(data_mismatch_count),
      .m_axi(data_check_axi)
    );
  ddr_fill_master #(
    .BASE_ADDR(33'h0), .LENGTH_BYTES(DATA_CLEAR_BYTES),
    .FILL_DATA(512'b0), .AXI_ID(4'h2)
  ) zero_i (
    .clk(c1_ui_clk), .resetn(c1_ui_resetn), .start(zero_start_ui[0]),
    .busy(zero_busy_ui), .done(zero_done_ui), .error(zero_error_ui),
    .bytes_completed(zero_bytes_completed), .m_axi(zero_axi)
  );

  logic [5:0] op_status_ctrl;
  sync_bits #(.WIDTH(6)) op_status_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({zero_error_ui,zero_done_ui,
               data_check_error_ui,data_check_pass_ui,data_check_done_ui,
               instr_check_done_ui}),
    .sync_out(op_status_ctrl)
  );
  // Pass and error for the instruction checker use a second small bundle.
  logic [1:0] instr_status_ctrl;
  sync_bits #(.WIDTH(2)) instr_status_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({instr_check_error_ui,instr_check_pass_ui}),
    .sync_out(instr_status_ctrl)
  );
  assign op_done_sync = {
    op_status_ctrl[4],op_status_ctrl[1],op_status_ctrl[0]
  };
  assign zero_done_ctrl = zero_done_armed && op_status_ctrl[4];

  // ----------------------------------------------------------------------
  // EH2 + CRC reduction and their DDR masters.
  // ----------------------------------------------------------------------
  system_state_t system_state;
  ddr1_owner_t ddr1_owner;
  logic eh2_execute_enable_ctrl;
  logic [0:0] eh2_execute_enable_core;
  sync_bits #(.WIDTH(1)) execute_sync_i (
    .clk(core_clk), .resetn(hard_resetn),
    .async_in(eh2_execute_enable_ctrl), .sync_out(eh2_execute_enable_core)
  );
  wire eh2_cycle_resetn = hard_resetn && eh2_execute_enable_core[0];

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(64), .ID_WIDTH(4)) ifu_axi64();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(64), .ID_WIDTH(4)) lsu_axi64();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ifu_ui_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) lsu_ui_axi();
  logic eh2_core_rst_l, eh2_init_busy, eh2_init_done_core, eh2_init_error_core;
  logic [1:0] eh2_stopped_core;
  logic [1:0][15:0] eh2_package_core;
  logic [1:0][1:0] result_valid_crc;
  logic [1:0][1:0][15:0] result_package_crc;
  logic [1:0][1:0][63:0] result_xor0_crc, result_xor1_crc;
  logic [1:0][1:0][63:0] result_sum0_crc, result_sum1_crc;
  logic [1:0][1:0][63:0] result_sum2_crc, result_sum3_crc;
  logic [1:0][1:0][31:0] result_count_crc;
  logic [1:0] nb_error_core, hash_fifo_error_core, hash_bank_error_core;
  logic [1:0] waw_valid_core, waw_hart_core;
  logic [1:0][15:0] waw_package_core, waw_sequence_core;
  logic ifu_axi_error_core, lsu_axi_error_core;

  eh2_core_crc_subsystem eh2_i (
    .clk(core_clk), .crc_rd_clk(clk125), .resetn(eh2_cycle_resetn),
    .core_rst_l(eh2_core_rst_l), .hw_init_busy(eh2_init_busy),
    .hw_init_done(eh2_init_done_core), .hw_init_error(eh2_init_error_core),
    .stopped(eh2_stopped_core), .package_number(eh2_package_core),
    .result_valid(result_valid_crc),
    .result_package_number(result_package_crc),
    .result_xor0(result_xor0_crc), .result_xor1(result_xor1_crc),
    .result_sum0(result_sum0_crc), .result_sum1(result_sum1_crc),
    .result_sum2(result_sum2_crc), .result_sum3(result_sum3_crc),
    .result_item_count(result_count_crc),
    .nb_conflict_hart(nb_error_core),
    .hash_fifo_overflow_hart(hash_fifo_error_core),
    .hash_bank_conflict_hart(hash_bank_error_core),
    .waw_cancel_valid(waw_valid_core), .waw_cancel_hart(waw_hart_core),
    .waw_cancel_package(waw_package_core),
    .waw_cancel_sequence(waw_sequence_core),
    .ifu_axi_error(ifu_axi_error_core), .lsu_axi_error(lsu_axi_error_core),
    .ifu_axi(ifu_axi64), .lsu_axi(lsu_axi64)
  );
  axi64_to_512_cdc ifu_cdc_i (
    .s_clk(core_clk), .s_resetn(eh2_cycle_resetn),
    .m_clk(c0_ui_clk), .m_resetn(c0_ui_resetn),
    .s_axi(ifu_axi64), .m_axi(ifu_ui_axi)
  );
  axi64_to_512_cdc lsu_cdc_i (
    .s_clk(core_clk), .s_resetn(eh2_cycle_resetn),
    .m_clk(c1_ui_clk), .m_resetn(c1_ui_resetn),
    .s_axi(lsu_axi64), .m_axi(lsu_ui_axi)
  );

  // Count transactions at the EH2 side of the clock/width converters. A
  // request remains outstanding until its final response is accepted, so the
  // controller cannot reset EH2 or hand a DDR port to another master while a
  // converted transaction is still in flight.
  logic [7:0] ifu_wr_outstanding, ifu_rd_outstanding;
  logic [7:0] lsu_wr_outstanding, lsu_rd_outstanding;
  wire ifu_aw_hs = ifu_axi64.awvalid && ifu_axi64.awready;
  wire ifu_b_hs  = ifu_axi64.bvalid  && ifu_axi64.bready;
  wire ifu_ar_hs = ifu_axi64.arvalid && ifu_axi64.arready;
  wire ifu_r_hs  = ifu_axi64.rvalid  && ifu_axi64.rready &&
                   ifu_axi64.rlast;
  wire lsu_aw_hs = lsu_axi64.awvalid && lsu_axi64.awready;
  wire lsu_b_hs  = lsu_axi64.bvalid  && lsu_axi64.bready;
  wire lsu_ar_hs = lsu_axi64.arvalid && lsu_axi64.arready;
  wire lsu_r_hs  = lsu_axi64.rvalid  && lsu_axi64.rready &&
                   lsu_axi64.rlast;

  always_ff @(posedge core_clk or negedge eh2_cycle_resetn) begin
    if (!eh2_cycle_resetn) begin
      ifu_wr_outstanding <= 8'b0;
      ifu_rd_outstanding <= 8'b0;
      lsu_wr_outstanding <= 8'b0;
      lsu_rd_outstanding <= 8'b0;
    end else begin
      case ({ifu_aw_hs, ifu_b_hs})
        2'b10: ifu_wr_outstanding <= ifu_wr_outstanding + 8'd1;
        2'b01: ifu_wr_outstanding <= ifu_wr_outstanding - 8'd1;
        default: ;
      endcase
      case ({ifu_ar_hs, ifu_r_hs})
        2'b10: ifu_rd_outstanding <= ifu_rd_outstanding + 8'd1;
        2'b01: ifu_rd_outstanding <= ifu_rd_outstanding - 8'd1;
        default: ;
      endcase
      case ({lsu_aw_hs, lsu_b_hs})
        2'b10: lsu_wr_outstanding <= lsu_wr_outstanding + 8'd1;
        2'b01: lsu_wr_outstanding <= lsu_wr_outstanding - 8'd1;
        default: ;
      endcase
      case ({lsu_ar_hs, lsu_r_hs})
        2'b10: lsu_rd_outstanding <= lsu_rd_outstanding + 8'd1;
        2'b01: lsu_rd_outstanding <= lsu_rd_outstanding - 8'd1;
        default: ;
      endcase
    end
  end

  wire eh2_axi_idle_core =
      (ifu_wr_outstanding == 0) && (ifu_rd_outstanding == 0) &&
      (lsu_wr_outstanding == 0) && (lsu_rd_outstanding == 0) &&
      !ifu_axi64.awvalid && !ifu_axi64.wvalid && !ifu_axi64.arvalid &&
      !lsu_axi64.awvalid && !lsu_axi64.wvalid && !lsu_axi64.arvalid;
  logic [0:0] eh2_axi_idle_ctrl;
  sync_bits #(.WIDTH(1)) eh2_axi_idle_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in(eh2_axi_idle_core), .sync_out(eh2_axi_idle_ctrl)
  );

  // Synchronize owner selects only after each prior master is idle.  The
  // controller supplies the guard interval before releasing EH2 reset.
  logic [1:0] ddr0_select_ctrl, ddr0_select_ui;
  logic [2:0] ddr1_select_ctrl, ddr1_select_ui;
  assign ddr0_select_ctrl = {
    ddr0_owner == DDR0_OWNER_EH2,
    ddr0_owner == DDR0_OWNER_CHECKER
  };
  assign ddr1_select_ctrl = {
    ddr1_owner == DDR1_OWNER_EH2,
    ddr1_owner == DDR1_OWNER_ZERO,
    ddr1_owner == DDR1_OWNER_CHECKER
  };
  sync_bits #(.WIDTH(2)) ddr0_owner_sync_i (
    .clk(c0_ui_clk), .resetn(c0_ui_resetn),
    .async_in(ddr0_select_ctrl), .sync_out(ddr0_select_ui)
  );
  sync_bits #(.WIDTH(3)) ddr1_owner_sync_i (
    .clk(c1_ui_clk), .resetn(c1_ui_resetn),
    .async_in(ddr1_select_ctrl), .sync_out(ddr1_select_ui)
  );

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr0_pre_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_pre_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_zero_phase_axi();
  axi_owner_mux2 ddr0_program_check_mux_i (
    .select_b(ddr0_select_ui[0]), .master_a(program_ui_axi),
    .master_b(instr_check_axi), .slave_out(ddr0_pre_axi)
  );
  axi_owner_mux2 ddr0_eh2_mux_i (
    .select_b(ddr0_select_ui[1]), .master_a(ddr0_pre_axi),
    .master_b(ifu_ui_axi), .slave_out(ddr0_axi)
  );
  axi_owner_mux2 ddr1_atg_check_mux_i (
    .select_b(ddr1_select_ui[0]), .master_a(data_atg_ui_axi),
    .master_b(data_check_axi), .slave_out(ddr1_pre_axi)
  );
  axi_owner_mux2 ddr1_zero_mux_i (
    .select_b(ddr1_select_ui[1]), .master_a(ddr1_pre_axi),
    .master_b(zero_axi), .slave_out(ddr1_zero_phase_axi)
  );
  axi_owner_mux2 ddr1_eh2_mux_i (
    .select_b(ddr1_select_ui[2]), .master_a(ddr1_zero_phase_axi),
    .master_b(lsu_ui_axi), .slave_out(ddr1_axi)
  );

  // ----------------------------------------------------------------------
  // CRC result/WAW CDC, WAW store and one-frame-per-result log formatter.
  // ----------------------------------------------------------------------
  logic [1:0][1:0] result_valid_ctrl;
  logic [1:0][1:0][15:0] result_package_ctrl;
  logic [1:0][1:0][63:0] result_xor0_ctrl, result_xor1_ctrl;
  logic [1:0][1:0][63:0] result_sum0_ctrl, result_sum1_ctrl;
  logic [1:0][1:0][63:0] result_sum2_ctrl, result_sum3_ctrl;
  logic [1:0][1:0][31:0] result_count_ctrl;
  logic result_cdc_overflow_crc;
  log_result_cdc result_cdc_i (
    .src_clk(clk125), .dst_clk(ctrl_clk), .resetn(eh2_cycle_resetn),
    .src_valid(result_valid_crc), .src_package(result_package_crc),
    .src_xor0(result_xor0_crc), .src_xor1(result_xor1_crc),
    .src_sum0(result_sum0_crc), .src_sum1(result_sum1_crc),
    .src_sum2(result_sum2_crc), .src_sum3(result_sum3_crc),
    .src_count(result_count_crc), .src_overflow(result_cdc_overflow_crc),
    .dst_valid(result_valid_ctrl), .dst_package(result_package_ctrl),
    .dst_xor0(result_xor0_ctrl), .dst_xor1(result_xor1_ctrl),
    .dst_sum0(result_sum0_ctrl), .dst_sum1(result_sum1_ctrl),
    .dst_sum2(result_sum2_ctrl), .dst_sum3(result_sum3_ctrl),
    .dst_count(result_count_ctrl)
  );

  logic [1:0] waw_valid_ctrl, waw_hart_ctrl, waw_cdc_overflow_core;
  logic [1:0][15:0] waw_package_ctrl, waw_sequence_ctrl;
  waw_event_cdc waw_cdc_i (
    .src_clk(core_clk), .dst_clk(ctrl_clk), .resetn(eh2_cycle_resetn),
    .src_valid(waw_valid_core), .src_hart(waw_hart_core),
    .src_package(waw_package_core), .src_sequence(waw_sequence_core),
    .src_overflow_hart(waw_cdc_overflow_core),
    .dst_valid(waw_valid_ctrl), .dst_hart(waw_hart_ctrl),
    .dst_package(waw_package_ctrl), .dst_sequence(waw_sequence_ctrl)
  );

  logic waw_read_hart, waw_read_bank;
  logic [8:0] waw_read_index, waw_read_count;
  logic [15:0] waw_read_package, waw_read_sequence;
  logic waw_read_match;
  logic [1:0][1:0] waw_clear_bank;
  logic [1:0] waw_store_overflow, waw_store_bank_conflict;
  waw_sequence_store waw_store_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .clear_all(ready_soft_reset), .event_valid(waw_valid_ctrl),
    .event_hart(waw_hart_ctrl), .event_package(waw_package_ctrl),
    .event_sequence(waw_sequence_ctrl), .read_hart(waw_read_hart),
    .read_bank(waw_read_bank), .read_index(waw_read_index),
    .read_package(waw_read_package), .read_sequence(waw_read_sequence),
    .read_count(waw_read_count), .read_package_match(waw_read_match),
    .clear_bank(waw_clear_bank), .overflow_hart(waw_store_overflow),
    .bank_conflict_hart(waw_store_bank_conflict)
  );

  logic [1:0] stopped_ctrl;
  logic [1:0][15:0] package_ctrl;
  sync_bits #(.WIDTH(34)) eh2_status_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({eh2_package_core,eh2_stopped_core}),
    .sync_out({package_ctrl,stopped_ctrl})
  );
  logic [7:0] log_tx_data;
  logic log_tx_valid, log_tx_last, log_tx_ready;
  logic log_frame_done, log_all_done, log_pending_overflow;
  wire log_packetizer_resetn = hard_resetn && !ready_soft_reset;
  log_frame_packetizer log_packetizer_i (
    .clk(ctrl_clk), .resetn(log_packetizer_resetn),
    .result_valid(result_valid_ctrl),
    .result_package_number(result_package_ctrl),
    .result_xor0(result_xor0_ctrl), .result_xor1(result_xor1_ctrl),
    .result_sum0(result_sum0_ctrl), .result_sum1(result_sum1_ctrl),
    .result_sum2(result_sum2_ctrl), .result_sum3(result_sum3_ctrl),
    .result_item_count(result_count_ctrl), .stopped(stopped_ctrl),
    .final_package_number(package_ctrl),
    .waw_read_hart, .waw_read_bank, .waw_read_index, .waw_read_package,
    .waw_read_sequence, .waw_read_count,
    .waw_read_package_match(waw_read_match), .waw_clear_bank,
    .m_axis_tdata(log_tx_data), .m_axis_tvalid(log_tx_valid),
    .m_axis_tlast(log_tx_last), .m_axis_tready(log_tx_ready),
    .frame_done(log_frame_done), .all_done(log_all_done),
    .pending_overflow(log_pending_overflow)
  );

  logic prefer_log_tx;
  system_tx_arbiter tx_arbiter_i (
    .clk(ctrl_clk), .resetn(hard_resetn), .prefer_log(prefer_log_tx),
    .info_tdata(info_tx_data), .info_tvalid(info_tx_valid),
    .info_tlast(info_tx_last), .info_tready(info_tx_ready),
    .log_tdata(log_tx_data), .log_tvalid(log_tx_valid),
    .log_tlast(log_tx_last), .log_tready(log_tx_ready),
    .m_axis_tdata(mac_tx_data), .m_axis_tvalid(mac_tx_valid),
    .m_axis_tlast(mac_tx_last), .m_axis_tready(mac_tx_ready)
  );

  // ----------------------------------------------------------------------
  // Error monitor and six-state controller.
  // ----------------------------------------------------------------------
  logic [1:0] data_atg_status_ctrl;
  sync_bits #(.WIDTH(2)) data_atg_done_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({data_atg_error_core,data_atg_done_core}),
    .sync_out(data_atg_status_ctrl)
  );
  logic [10:0] eh2_error_status_ctrl;
  sync_bits #(.WIDTH(11)) eh2_error_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({waw_cdc_overflow_core,lsu_axi_error_core,
               ifu_axi_error_core,eh2_init_error_core,
               hash_bank_error_core,hash_fifo_error_core,nb_error_core}),
    .sync_out(eh2_error_status_ctrl)
  );
  logic [1:0] eh2_init_status_ctrl;
  sync_bits #(.WIDTH(2)) eh2_init_done_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({eh2_init_error_core,eh2_init_done_core}),
    .sync_out(eh2_init_status_ctrl)
  );
  logic [0:0] result_cdc_overflow_ctrl;
  sync_bits #(.WIDTH(1)) result_error_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in(result_cdc_overflow_crc), .sync_out(result_cdc_overflow_ctrl)
  );

  localparam integer INIT_TIMEOUT_CYCLES = 500_000_000;
  logic [28:0] init_timeout_counter;
  logic init_timeout;
  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      init_timeout_counter <= 29'd0;
      init_timeout <= 1'b0;
    end else if (mac_config_done && phy_init_success &&
                 c0_calib_done_ctrl && c1_calib_done_ctrl) begin
      init_timeout_counter <= init_timeout_counter;
    end else if (init_timeout_counter == INIT_TIMEOUT_CYCLES-1) begin
      init_timeout <= 1'b1;
    end else begin
      init_timeout_counter <= init_timeout_counter + 29'd1;
    end
  end

  logic error_monitor_clear, fatal_error_pending;
  logic [31:0] fatal_error_code;
  system_error_monitor error_monitor_i (
    .clk(ctrl_clk), .resetn(hard_resetn), .clear(error_monitor_clear),
    .err_nb_hart0(eh2_error_status_ctrl[0]),
    .err_nb_hart1(eh2_error_status_ctrl[1]),
    .err_hash_hart0(eh2_error_status_ctrl[2]),
    .err_hash_hart1(eh2_error_status_ctrl[3]),
    .err_txmac_fifo(tx_fifo_overflow),
    .err_txmac_stream(log_pending_overflow ||
                      result_cdc_overflow_ctrl[0]),
    .err_waw_hart0(waw_store_overflow[0] ||
                   eh2_error_status_ctrl[9]),
    .err_waw_hart1(waw_store_overflow[1] ||
                   eh2_error_status_ctrl[10]),
    .err_bank_hart0(waw_store_bank_conflict[0] ||
                    eh2_error_status_ctrl[4]),
    .err_bank_hart1(waw_store_bank_conflict[1] ||
                    eh2_error_status_ctrl[5]),
    .err_info_rx_fifo(info_rx_overflow),
    .err_info_tx_fifo(info_tx_overflow),
    .err_rx_frame_buf(rx_frame_buffer_overflow || rx_fifo_overflow),
    .err_rx_frame_len(rx_frame_length_error || malformed_info_frame ||
                      program_frame_length_error),
    .err_mac_config(mac_config_error ||
                    (init_timeout && !mac_config_done)),
    .err_phy_init((|phy_init_error) ||
                  (init_timeout && !phy_init_success)),
    .err_phy_link(phy_init_done && !phy_link_up),
    .err_mig0(init_timeout && !c0_calib_done_ctrl),
    .err_mig1(init_timeout && !c1_calib_done_ctrl),
    .err_ddr_zero(op_status_ctrl[5]),
    .err_ddr_check(1'b0),
    .err_eh2_init(eh2_error_status_ctrl[6]),
    .err_eh2_ifu_axi(eh2_error_status_ctrl[7]),
    .err_eh2_lsu_axi(eh2_error_status_ctrl[8]),
    .err_program_write(program_dma_error),
    .err_program_fifo(rx_fifo_overflow),
    .err_program_dma(datamover_error),
    .pending(fatal_error_pending), .code(fatal_error_code)
  );

  logic led0;
  eh2_system_controller controller_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .mac_config_done, .phy_init_done(phy_init_success),
    .phy_link_up, .mig0_ready(c0_calib_done_ctrl),
    .mig1_ready(c1_calib_done_ctrl),
    .preconfig_program_end_pulse(system_program_end_pulse),
    .program_first_write_pulse, .program_end_pulse(system_program_end_pulse),
    .program_frame_count, .program_dma_done_count,
    .program_dma_busy, .data_atg_done(data_atg_status_ctrl[0]),
    .data_atg_error(data_atg_status_ctrl[1]),
    .instr_check_done(op_status_ctrl[0]),
    .instr_check_pass(instr_status_ctrl[0]),
    .instr_check_error(instr_status_ctrl[1]),
    .data_check_done(op_status_ctrl[1]),
    .data_check_pass(op_status_ctrl[2]),
    .data_check_error(op_status_ctrl[3]),
    .zero_done(zero_done_ctrl), .zero_error(op_status_ctrl[5]),
    .eh2_init_done(eh2_init_status_ctrl[0]),
    .eh2_init_error(eh2_init_status_ctrl[1]),
    .eh2_stopped(stopped_ctrl), .eh2_axi_idle(eh2_axi_idle_ctrl[0]),
    .log_tx_all_done(log_all_done),
    .fatal_error_pending, .fatal_error_code,
    .info_tx_full, .info_frame_done, .info_sent_code,
    .info_tx_push, .info_tx_code, .data_atg_start(data_atg_start_ctrl),
    .instr_check_start(instr_check_start_ctrl),
    .data_check_start(data_check_start_ctrl), .zero_start(zero_start_ctrl),
    .ready_soft_reset, .error_monitor_clear, .eh2_execute_enable(eh2_execute_enable_ctrl),
    .prefer_log_tx, .led0, .state(system_state),
    .ddr0_owner, .ddr1_owner
  );

  assign led[0] = led0;
  assign led[1] = mac_config_done && !mac_config_error;
  assign led[2] = phy_init_success;
  assign led[3] = c0_calib_done_ctrl;
  assign led[4] = c1_calib_done_ctrl;
  assign led[5] = (system_state == ST_PROGRAM_WRITE);
  assign led[6] = (system_state == ST_EXECUTE);
  assign led[7] = (system_state == ST_END);
endmodule
