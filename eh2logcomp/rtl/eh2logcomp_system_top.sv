`timescale 1ns/1ps

module eh2logcomp_system_top #(
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
  // This clock drives TEMAC GTX and the line-rate TX user path.
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
  wire base_resetn = board_resetn && por_pipe[15];
  logic global_reset_request;
  logic hard_resetn;
  logic global_reset_active;
  system_global_reset_supervisor #(.RESET_CYCLES(64)) reset_supervisor_i (
    .clk(ctrl_clk), .base_resetn, .reset_request(global_reset_request),
    .system_resetn(hard_resetn), .reset_active(global_reset_active)
  );

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
  logic rgmii_rx_ready, rx_fcs_error_pulse;
  (* MARK_DEBUG = "TRUE" *) logic [31:0] rx_fcs_error_count;
  logic [31:0] tx_frame_complete_count;
  logic [31:0] tx_submitted_frame_count;
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
    .phy_autoneg_complete, .rgmii_rx_ready,
    .rx_fcs_error_pulse, .rx_fcs_error_count,
    .tx_frame_complete_count,
    .rx_fifo_status, .rx_fifo_overflow,
    .tx_fifo_status, .tx_fifo_overflow, .inband_link_status,
    .inband_clock_speed, .inband_duplex_status, .mac_irq
  );

  // This count is taken at the 125 MHz TEMAC client boundary. Comparing it with the
  // physical TX statistics count prevents global reset from truncating frames
  // which have entered the MAC FIFO but have not yet left the RGMII pins.
  logic [31:0] tx_submitted_count_tx;
  logic [31:0] tx_submitted_gray_tx, tx_submitted_gray_ctrl;
  always_ff @(posedge clk125 or negedge hard_resetn) begin
    if (!hard_resetn) begin
      tx_submitted_count_tx <= 32'b0;
      tx_submitted_gray_tx <= 32'b0;
    end else if (mac_tx_valid && mac_tx_ready && mac_tx_last) begin
      tx_submitted_count_tx <= tx_submitted_count_tx + 32'd1;
      // Register Gray code before the synchronizer.  A combinational binary-
      // to-Gray network can glitch while several binary bits toggle.
      tx_submitted_gray_tx <=
        (tx_submitted_count_tx + 32'd1) ^
        ((tx_submitted_count_tx + 32'd1) >> 1);
    end
  end
  sync_bits #(.WIDTH(32), .STAGES(3)) tx_submit_count_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in(tx_submitted_gray_tx), .sync_out(tx_submitted_gray_ctrl)
  );
  always_comb begin
    tx_submitted_frame_count[31] = tx_submitted_gray_ctrl[31];
    for (integer bit_index = 30; bit_index >= 0; bit_index = bit_index - 1)
      tx_submitted_frame_count[bit_index] =
        tx_submitted_frame_count[bit_index+1] ^
        tx_submitted_gray_ctrl[bit_index];
  end

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
  logic system_program_end_pulse, host_send_stopped_pulse;
  logic host_global_reset_pulse;
  logic host_info_retransmit_all_pulse;
  logic malformed_info_frame;
  logic [31:0] system_program_end_total_count;
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
    .program_end_total_count(system_program_end_total_count),
    .host_send_stopped_pulse,
    .host_global_reset_pulse,
    .host_info_retransmit_all_pulse,
    .malformed_frame(malformed_info_frame)
  );

  // ----------------------------------------------------------------------
  // Program DMA, controller-owned information FIFO and TX arbitration.
  // ----------------------------------------------------------------------
  logic program_session_clear;
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(32), .ID_WIDTH(4)) program_axi32();
  logic [31:0] program_frame_count, program_dma_write_addr;
  logic [31:0] program_dma_done_count;
  logic program_frame_done, program_dma_done, program_dma_error;
  logic program_frame_length_error, program_sequence_error;
  logic program_dma_busy, datamover_error;
  logic [31:0] last_dma_status;
  logic program_first_write_pulse;
  ddr0_owner_t ddr0_owner;
  wire program_path_enable = (ddr0_owner == DDR0_OWNER_PROGRAM);
  wire program_dma_input_ready;
  assign program_stream_ready = program_path_enable ?
                                program_dma_input_ready : 1'b1;
  program_dma_subsystem program_dma_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .session_clear(program_session_clear),
    .s_axis_tdata(program_stream_data),
    .s_axis_tvalid(program_stream_valid && program_path_enable),
    .s_axis_tlast(program_stream_last),
    .s_axis_tready(program_dma_input_ready),
    .frame_count(program_frame_count), .dma_write_addr(program_dma_write_addr),
    .frame_done(program_frame_done), .dma_done(program_dma_done),
    .dma_error(program_dma_error),
    .sequence_error(program_sequence_error),
    .frame_length_error(program_frame_length_error),
    .last_dma_status, .dma_busy(program_dma_busy),
    .datamover_error, .first_write_pulse(program_first_write_pulse),
    .m_axi(program_axi32)
  );
  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn || program_session_clear)
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
  logic info_frame_queued, info_frame_done;
  logic [31:0] info_queued_code, info_sent_code;
  system_info_tx_formatter info_formatter_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .fifo_code(info_fifo_code), .fifo_empty(info_fifo_empty),
    .fifo_rd_en(info_fifo_rd_en), .m_axis_tdata(info_tx_data),
    .m_axis_tvalid(info_tx_valid), .m_axis_tlast(info_tx_last),
    .m_axis_tready(info_tx_ready), .frame_done(info_frame_queued),
    .sent_code(info_queued_code)
  );

  logic [7:0] info_tx125_data;
  logic info_tx125_valid, info_tx125_last, info_tx125_ready;
  logic info_tx_cdc_overflow;
  system_info_tx_cdc info_tx_cdc_i (
    .ctrl_clk, .tx_clk(clk125), .resetn(hard_resetn),
    .s_tdata(info_tx_data), .s_tvalid(info_tx_valid),
    .s_tlast(info_tx_last), .s_tready(info_tx_ready),
    .s_frame_queued(info_fifo_rd_en), .s_queued_code(info_fifo_code),
    .ctrl_frame_done(info_frame_done), .ctrl_sent_code(info_sent_code),
    .m_tdata(info_tx125_data), .m_tvalid(info_tx125_valid),
    .m_tlast(info_tx125_last), .m_tready(info_tx125_ready),
    .overflow(info_tx_cdc_overflow)
  );

  // ----------------------------------------------------------------------
  // Dual DDR, fixed masters and phase-safe ownership.
  // ----------------------------------------------------------------------
  logic c0_ui_clk, c0_ui_resetn, c0_calib_done;
  logic c1_ui_clk, c1_ui_resetn, c1_calib_done;
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr0_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr0_mig_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_mig_axi();
  dual_ddr_mig_wrapper mig_i (
    .hard_resetn, .c0_sys_clk_p, .c0_sys_clk_n,
    .c1_sys_clk_p, .c1_sys_clk_n,
    .c0_ui_clk, .c0_ui_resetn, .c0_calib_done,
    .c1_ui_clk, .c1_ui_resetn, .c1_calib_done,
    .c0_axi(ddr0_mig_axi), .c1_axi(ddr1_mig_axi),
    .c0_ddr4_act_n, .c0_ddr4_adr, .c0_ddr4_ba, .c0_ddr4_bg,
    .c0_ddr4_cke, .c0_ddr4_odt, .c0_ddr4_cs_n,
    .c0_ddr4_ck_t, .c0_ddr4_ck_c, .c0_ddr4_reset_n,
    .c0_ddr4_dm_dbi_n, .c0_ddr4_dq, .c0_ddr4_dqs_c, .c0_ddr4_dqs_t,
    .c1_ddr4_act_n, .c1_ddr4_adr, .c1_ddr4_ba, .c1_ddr4_bg,
    .c1_ddr4_cke, .c1_ddr4_odt, .c1_ddr4_cs_n,
    .c1_ddr4_ck_t, .c1_ddr4_ck_c, .c1_ddr4_reset_n,
    .c1_ddr4_dm_dbi_n, .c1_ddr4_dq, .c1_ddr4_dqs_c, .c1_ddr4_dqs_t
  );

  // hard_resetn is generated on ctrl_clk.  Assert it asynchronously into the
  // two Info-dump domains, but release it only on each destination clock.
  // This prevents reset removal from looking like a publish/release toggle.
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [2:0] ddr0_ui_reset_pipe;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [2:0] info_dump_ui_reset_pipe;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [2:0] info_dump_tx_reset_pipe;
  wire ddr0_ui_async_resetn = hard_resetn && c0_ui_resetn;
  wire ddr0_ui_user_resetn = ddr0_ui_reset_pipe[2];
  wire info_dump_ui_async_resetn = hard_resetn && c1_ui_resetn;
  wire info_dump_ui_resetn = info_dump_ui_reset_pipe[2];
  wire ddr1_ui_user_resetn = info_dump_ui_resetn;
  wire info_dump_tx_resetn = info_dump_tx_reset_pipe[2];
  always_ff @(posedge c0_ui_clk or negedge ddr0_ui_async_resetn) begin
    if (!ddr0_ui_async_resetn)
      ddr0_ui_reset_pipe <= 3'b000;
    else
      ddr0_ui_reset_pipe <= {ddr0_ui_reset_pipe[1:0],1'b1};
  end
  always_ff @(posedge c1_ui_clk or negedge info_dump_ui_async_resetn) begin
    if (!info_dump_ui_async_resetn)
      info_dump_ui_reset_pipe <= 3'b000;
    else
      info_dump_ui_reset_pipe <= {info_dump_ui_reset_pipe[1:0],1'b1};
  end
  always_ff @(posedge clk125 or negedge hard_resetn) begin
    if (!hard_resetn)
      info_dump_tx_reset_pipe <= 3'b000;
    else
      info_dump_tx_reset_pipe <= {info_dump_tx_reset_pipe[1:0],1'b1};
  end

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
    .s_clk(ctrl_clk), .s_resetn(hard_resetn),
    .m_clk(c0_ui_clk), .m_resetn(ddr0_ui_user_resetn),
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
    .m_clk(c1_ui_clk), .m_resetn(ddr1_ui_user_resetn),
    .s_axi(data_atg_axi32), .m_axi(data_atg_ui_axi)
  );

  logic instr_check_start_ctrl, data_check_start_ctrl, zero_start_ctrl;
  logic instr_check_start_hold, data_check_start_hold, zero_start_hold;
  logic [2:0] ddr0_select_ctrl, ddr0_select_ui;
  logic [2:0] ddr1_select_ctrl, ddr1_select_ui;
  logic instr_check_done_ui, instr_check_pass_ui, instr_check_error_ui;
  logic data_check_done_ui, data_check_pass_ui, data_check_error_ui;
  logic zero_done_ui, zero_error_ui, zero_busy_ui;
  logic [32:0] zero_bytes_completed;
  logic [31:0] instr_mismatch_count, data_mismatch_count;
  logic [2:0] op_done_sync;
  logic [2:0] op_start_async;
  logic zero_done_armed;
  logic zero_done_ctrl;
  logic [5:0] op_status_ctrl;

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
    .clk(c0_ui_clk), .resetn(ddr0_ui_user_resetn),
    .async_in(op_start_async[0]), .sync_out(instr_start_ui)
  );
  sync_bits #(.WIDTH(1)) data_start_sync_i (
    .clk(c1_ui_clk), .resetn(ddr1_ui_user_resetn),
    .async_in(op_start_async[1]), .sync_out(data_start_ui)
  );
  sync_bits #(.WIDTH(1)) zero_start_sync_i (
    .clk(c0_ui_clk), .resetn(ddr0_ui_user_resetn),
    .async_in(op_start_async[2]), .sync_out(zero_start_ui)
  );

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) instr_check_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) data_check_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) zero_axi();
  ddr_read_compare_master #(.BASE_ADDR(33'h0_8000_0000))
    instr_checker_i (
      .clk(c0_ui_clk), .resetn(ddr0_ui_user_resetn),
      .start(instr_start_ui[0] && ddr0_select_ui[0]),
      .busy(), .done(instr_check_done_ui), .pass(instr_check_pass_ui),
      .error(instr_check_error_ui), .mismatch_count(instr_mismatch_count),
      .m_axi(instr_check_axi)
    );
  ddr_read_compare_master #(.BASE_ADDR(33'h0))
    data_checker_i (
      .clk(c1_ui_clk), .resetn(ddr1_ui_user_resetn),
      .start(data_start_ui[0] && ddr1_select_ui[0]),
      .busy(), .done(data_check_done_ui), .pass(data_check_pass_ui),
      .error(data_check_error_ui), .mismatch_count(data_mismatch_count),
      .m_axi(data_check_axi)
    );
  ddr_fill_master #(
    .BASE_ADDR(33'h0), .LENGTH_BYTES(DATA_CLEAR_BYTES),
    .FILL_DATA(512'b0), .AXI_ID(4'h2)
  ) zero_i (
    .clk(c0_ui_clk), .resetn(ddr0_ui_user_resetn),
    .start(zero_start_ui[0] && ddr0_select_ui[1]),
    .busy(zero_busy_ui), .done(zero_done_ui), .error(zero_error_ui),
    .bytes_completed(zero_bytes_completed), .m_axi(zero_axi)
  );

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
  // The legacy CRC implementation is retained only as non-compiled reference.
  // ----------------------------------------------------------------------
`ifdef LEGACY_CRC_DISABLED
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
  logic [1:0] eh2_started_core, eh2_stopped_core;
  logic [1:0][15:0] eh2_package_core;
  logic [1:0][1:0] result_valid_crc;
  logic [1:0][1:0][15:0] result_package_crc;
  logic [1:0][1:0][63:0] result_xor0_crc, result_xor1_crc;
  logic [1:0][1:0][63:0] result_sum0_crc, result_sum1_crc;
  logic [1:0][1:0][63:0] result_sum2_crc, result_sum3_crc;
  logic [1:0][1:0][31:0] result_count_crc;
  logic [1:0] nb_error_core, hash_fifo_error_core, hash_bank_error_core;
  logic [3:0] waw_valid_core, waw_hart_core;
  logic [3:0][15:0] waw_package_core, waw_sequence_core;
  logic ifu_axi_error_core, lsu_axi_error_core;

  eh2_core_crc_subsystem eh2_i (
    .clk(core_clk), .crc_rd_clk(clk125), .resetn(eh2_cycle_resetn),
    .core_rst_l(eh2_core_rst_l), .hw_init_busy(eh2_init_busy),
    .hw_init_done(eh2_init_done_core), .hw_init_error(eh2_init_error_core),
    .started(eh2_started_core), .stopped(eh2_stopped_core),
    .package_number(eh2_package_core),
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
    .m_clk(c0_ui_clk), .m_resetn(ddr0_ui_user_resetn),
    .s_axi(ifu_axi64), .m_axi(ifu_ui_axi)
  );
  axi64_to_512_cdc lsu_cdc_i (
    .s_clk(core_clk), .s_resetn(eh2_cycle_resetn),
    .m_clk(c1_ui_clk), .m_resetn(ddr1_ui_user_resetn),
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

  wire eh2_axi_idle_core_comb =
      (ifu_wr_outstanding == 0) && (ifu_rd_outstanding == 0) &&
      (lsu_wr_outstanding == 0) && (lsu_rd_outstanding == 0) &&
      !ifu_axi64.awvalid && !ifu_axi64.wvalid && !ifu_axi64.arvalid &&
      !lsu_axi64.awvalid && !lsu_axi64.wvalid && !lsu_axi64.arvalid;
  // Register the complete idle decision in the source domain before the
  // single-bit synchronizer.  This prevents comparator/reduction glitches
  // from being interpreted as a safe DDR handoff indication.
  logic eh2_axi_idle_core;
  always_ff @(posedge core_clk or negedge eh2_cycle_resetn) begin
    if (!eh2_cycle_resetn)
      eh2_axi_idle_core <= 1'b0;
    else
      eh2_axi_idle_core <= eh2_axi_idle_core_comb;
  end
  logic [0:0] eh2_axi_idle_ctrl;
  sync_bits #(.WIDTH(1)) eh2_axi_idle_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in(eh2_axi_idle_core), .sync_out(eh2_axi_idle_ctrl)
  );

  // Synchronize owner selects only after each prior master is idle.  The
  // controller supplies the guard interval before releasing EH2 reset.
  wire [1:0] ddr0_select_next = {
    ddr0_owner == DDR0_OWNER_EH2,
    ddr0_owner == DDR0_OWNER_CHECKER
  };
  wire [2:0] ddr1_select_next = {
    ddr1_owner == DDR1_OWNER_EH2,
    ddr1_owner == DDR1_OWNER_ZERO,
    ddr1_owner == DDR1_OWNER_CHECKER
  };
  // The enum-to-one-hot decode is registered before crossing clock domains;
  // otherwise simultaneous state-bit changes can produce a transient owner.
  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      ddr0_select_ctrl <= 2'b00;
      ddr1_select_ctrl <= 3'b000;
    end else begin
      ddr0_select_ctrl <= ddr0_select_next;
      ddr1_select_ctrl <= ddr1_select_next;
    end
  end
  sync_bits #(.WIDTH(2)) ddr0_owner_sync_i (
    .clk(c0_ui_clk), .resetn(ddr0_ui_user_resetn),
    .async_in(ddr0_select_ctrl), .sync_out(ddr0_select_ui)
  );
  sync_bits #(.WIDTH(3)) ddr1_owner_sync_i (
    .clk(c1_ui_clk), .resetn(ddr1_ui_user_resetn),
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

  logic [3:0] waw_valid_ctrl, waw_hart_ctrl;
  logic [1:0] waw_cdc_overflow_core;
  logic [3:0][15:0] waw_package_ctrl, waw_sequence_ctrl;
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
    .clear_all(1'b0), .event_valid(waw_valid_ctrl),
    .event_hart(waw_hart_ctrl), .event_package(waw_package_ctrl),
    .event_sequence(waw_sequence_ctrl), .read_hart(waw_read_hart),
    .read_bank(waw_read_bank), .read_index(waw_read_index),
    .read_package(waw_read_package), .read_sequence(waw_read_sequence),
    .read_count(waw_read_count), .read_package_match(waw_read_match),
    .clear_bank(waw_clear_bank), .overflow_hart(waw_store_overflow),
    .bank_conflict_hart(waw_store_bank_conflict)
  );

  logic [1:0] started_ctrl, stopped_ctrl;
  logic [1:0][15:0] package_ctrl;
  sync_bits #(.WIDTH(36)) eh2_status_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({eh2_package_core,eh2_started_core,eh2_stopped_core}),
    .sync_out({package_ctrl,started_ctrl,stopped_ctrl})
  );
  logic [7:0] log_tx_data;
  logic log_tx_valid, log_tx_last, log_tx_ready;
  logic log_frame_done, log_all_done, log_pending_overflow;
  log_frame_packetizer log_packetizer_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
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
`endif

  // ----------------------------------------------------------------------
  // EH2 Info Struct capture, dual FIFOs, DDR0 IFU/LSU and DDR1 log DMA.
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
  logic [1:0] eh2_started_core, eh2_stopped_core;
  logic [1:0][3:0] info_record_valid_core, info_record_ready_core;
  logic [1:0][3:0][255:0] info_record_data_core;
  logic info_capture_done_core;
  logic [1:0][31:0] info_next_sequence_core;
  logic [1:0][31:0] info_commit_count_core, info_generated_count_core;
  logic [1:0][5:0] info_pending_nb_core;
  logic [1:0] nb_error_core, capture_overflow_core, waw_cause_error_core;
  logic ifu_axi_error_core, lsu_axi_error_core;

  eh2_core_info_subsystem eh2_i (
    .clk(core_clk), .resetn(hard_resetn),
    .info_system_ready(eh2_execute_enable_core[0]),
    .core_rst_l(eh2_core_rst_l), .hw_init_busy(eh2_init_busy),
    .hw_init_done(eh2_init_done_core), .hw_init_error(eh2_init_error_core),
    .started(eh2_started_core), .stopped(eh2_stopped_core),
    .record_valid(info_record_valid_core),
    .record_data(info_record_data_core),
    .record_ready(info_record_ready_core),
    .capture_done(info_capture_done_core),
    .next_sequence(info_next_sequence_core),
    .commit_count(info_commit_count_core),
    .generated_count(info_generated_count_core),
    .pending_nonblock_count(info_pending_nb_core),
    .nb_conflict_hart(nb_error_core),
    .info_fifo_overflow_hart(capture_overflow_core),
    .waw_cause_error_hart(waw_cause_error_core),
    .ifu_axi_error(ifu_axi_error_core), .lsu_axi_error(lsu_axi_error_core),
    .ifu_axi(ifu_axi64), .lsu_axi(lsu_axi64)
  );

  axi64_to_512_cdc ifu_cdc_i (
    .s_clk(core_clk), .s_resetn(eh2_cycle_resetn),
    .m_clk(c0_ui_clk), .m_resetn(ddr0_ui_user_resetn),
    .s_axi(ifu_axi64), .m_axi(ifu_ui_axi)
  );
  axi64_to_512_cdc lsu_cdc_i (
    .s_clk(core_clk), .s_resetn(eh2_cycle_resetn),
    .m_clk(c0_ui_clk), .m_resetn(ddr0_ui_user_resetn),
    .s_axi(lsu_axi64), .m_axi(lsu_ui_axi)
  );
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) eh2_ddr0_axi();
  axi_burst_arbiter_2x1 eh2_ddr0_arbiter_i (
    .clk(c0_ui_clk), .resetn(ddr0_ui_user_resetn),
    .master_a(ifu_ui_axi), .master_b(lsu_ui_axi), .slave_out(eh2_ddr0_axi)
  );

  // A 16-record register queue per hart forms a deliberate core-clock timing
  // boundary between the wide WAW/capture network and the XPM BRAM write
  // enables.  It retains the full four-record-per-cycle producer throughput.
  logic [1:0][3:0] info_queue_valid, info_queue_ready;
  logic [1:0][3:0][255:0] info_queue_data;
  logic [1:0] info_queue_empty, info_queue_overflow;
  logic [1:0][4:0] info_queue_occupancy;
  for (genvar queue_hart = 0; queue_hart < 2;
       queue_hart = queue_hart + 1) begin : g_info_write_elastic
    info_record_elastic_4w4r #(.DEPTH(16)) info_write_elastic_i (
      .clk(core_clk), .rst_l(hard_resetn),
      .in_valid(info_record_valid_core[queue_hart]),
      .in_data(info_record_data_core[queue_hart]),
      .in_ready(info_record_ready_core[queue_hart]),
      .out_valid(info_queue_valid[queue_hart]),
      .out_data(info_queue_data[queue_hart]),
      .out_ready(info_queue_ready[queue_hart]),
      .empty(info_queue_empty[queue_hart]),
      .overflow(info_queue_overflow[queue_hart]),
      .occupancy(info_queue_occupancy[queue_hart])
    );
  end

  // Capture is complete only after both registered timing queues have
  // delivered their final records.  This level freezes the final partial
  // bank and is the completion indication synchronized into the DDR1 domain.
  // Register the completion level in its 50 MHz source domain before it
  // fans out to the DDR1-domain synchronizers.  Both terms below are local
  // registered state, but their combinational AND could otherwise be seen
  // (and physically implemented) as logic immediately ahead of a CDC
  // synchronizer.  The one-cycle delay does not change the protocol: the
  // level is sticky until the following global reset.
  logic info_pipeline_done_core;
  always_ff @(posedge core_clk or negedge hard_resetn) begin
    if (!hard_resetn)
      info_pipeline_done_core <= 1'b0;
    else
      info_pipeline_done_core <= info_capture_done_core &&
                                 (&info_queue_empty);
  end

  // Each hart owns a 2048-record information FIFO.  It is physically four
  // ordered 512-record banks: one bank is filled by EH2 while a previously
  // full bank is transferred atomically to DDR1.
  logic [1:0] info_fifo_wr_overflow, info_fifo_wr_init;
  logic [1:0] info_fifo_rd_valid, info_fifo_rd_ready;
  logic [1:0][511:0] info_fifo_rd_data;
  logic [1:0][1:0] info_fifo_rd_records;
  logic [1:0] info_fifo_all_empty;
  logic [1:0][11:0] info_fifo_wr_occupancy;
  logic [1:0] info_batch_valid, info_batch_claim, info_batch_done;
  logic [1:0][9:0] info_batch_record_count;
  for (genvar info_hart = 0; info_hart < 2; info_hart = info_hart + 1) begin : g_info_fifo
    info_fifo_pingpong_4w2r #(.RECORD_DEPTH(2048)) info_fifo_i (
      .wr_clk(core_clk), .rd_clk(c1_ui_clk), .rst_l(hard_resetn),
      .wr_valid(info_queue_valid[info_hart]),
      .wr_data(info_queue_data[info_hart]),
      .wr_ready(info_queue_ready[info_hart]),
      .wr_overflow(info_fifo_wr_overflow[info_hart]),
      .wr_init_done(info_fifo_wr_init[info_hart]),
      .wr_occupancy(info_fifo_wr_occupancy[info_hart]),
      .wr_flush(info_pipeline_done_core),
      .batch_valid(info_batch_valid[info_hart]),
      .batch_record_count(info_batch_record_count[info_hart]),
      .batch_claim(info_batch_claim[info_hart]),
      .batch_done(info_batch_done[info_hart]),
      .rd_valid(info_fifo_rd_valid[info_hart]),
      .rd_data(info_fifo_rd_data[info_hart]),
      .rd_record_count(info_fifo_rd_records[info_hart]),
      .rd_ready(info_fifo_rd_ready[info_hart]),
      .all_empty(info_fifo_all_empty[info_hart])
    );
  end

  // Register both selected bank streams before the DDR1 AXI writer.  This
  // prevents MIG WREADY and the writer's bank/burst selection from feeding
  // directly back into the XPM FIFO read enables at 266.5 MHz.
  logic [1:0] info_elastic_valid, info_elastic_ready;
  logic [1:0][511:0] info_elastic_data;
  logic [1:0][1:0] info_elastic_records;
  logic [1:0] info_elastic_empty;
  logic [1:0][2:0] info_elastic_buffered_records;
  logic [1:0] info_dma_empty;
  for (genvar elastic_hart = 0; elastic_hart < 2;
       elastic_hart = elastic_hart + 1) begin : g_info_elastic
    info_fifo_read_elastic info_elastic_i (
      .clk(c1_ui_clk), .rst_l(ddr1_ui_user_resetn),
      .in_valid(info_fifo_rd_valid[elastic_hart]),
      .in_data(info_fifo_rd_data[elastic_hart]),
      .in_record_count(info_fifo_rd_records[elastic_hart]),
      .in_ready(info_fifo_rd_ready[elastic_hart]),
      .out_valid(info_elastic_valid[elastic_hart]),
      .out_data(info_elastic_data[elastic_hart]),
      .out_record_count(info_elastic_records[elastic_hart]),
      .out_ready(info_elastic_ready[elastic_hart]),
      .empty(info_elastic_empty[elastic_hart]),
      .buffered_records(info_elastic_buffered_records[elastic_hart])
    );
    // A claimed bank supplies its exact frozen record count to the DMA.  The
    // elastic queue only breaks timing; it never participates in burst-length
    // planning, so no asynchronous count can over-advertise available data.
    assign info_dma_empty[elastic_hart] =
      info_fifo_all_empty[elastic_hart] &&
      info_elastic_empty[elastic_hart];
  end

  logic [0:0] capture_done_ui;
  sync_bits #(.WIDTH(1)) capture_done_ui_sync_i (
    .clk(c1_ui_clk), .resetn(ddr1_ui_user_resetn),
    .async_in(info_pipeline_done_core), .sync_out(capture_done_ui)
  );
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) info_write_axi();
  logic [31:0] h0_written_records, h1_written_records;
  logic info_write_busy, info_write_done_ui, info_write_axi_error;
  logic info_region_overflow;
  info_ddr_pingpong_write_dma info_write_dma_i (
    .clk(c1_ui_clk), .rst_l(ddr1_ui_user_resetn),
    .capture_done(capture_done_ui[0]),
    .h0_batch_valid(info_batch_valid[0]),
    .h0_batch_record_count(info_batch_record_count[0]),
    .h0_batch_claim(info_batch_claim[0]), .h0_batch_done(info_batch_done[0]),
    .h0_valid(info_elastic_valid[0]), .h0_data(info_elastic_data[0]),
    .h0_record_count(info_elastic_records[0]),
    .h0_empty(info_dma_empty[0]), .h0_ready(info_elastic_ready[0]),
    .h1_batch_valid(info_batch_valid[1]),
    .h1_batch_record_count(info_batch_record_count[1]),
    .h1_batch_claim(info_batch_claim[1]), .h1_batch_done(info_batch_done[1]),
    .h1_valid(info_elastic_valid[1]), .h1_data(info_elastic_data[1]),
    .h1_record_count(info_elastic_records[1]),
    .h1_empty(info_dma_empty[1]), .h1_ready(info_elastic_ready[1]),
    .axi(info_write_axi), .h0_written_records, .h1_written_records,
    .busy(info_write_busy), .all_writes_done(info_write_done_ui),
    .axi_error(info_write_axi_error), .region_overflow(info_region_overflow)
  );

  logic info_dump_start_ctrl, info_dump_start_ui;
  event_toggle_cdc dump_start_cdc_i (
    .src_clk(ctrl_clk), .dst_clk(c1_ui_clk), .resetn(hard_resetn),
    .src_event(info_dump_start_ctrl), .dst_pulse(info_dump_start_ui)
  );
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) info_read_axi();
  logic [7:0] dump_tx_data;
  logic dump_tx_valid, dump_tx_last, dump_tx_ready;
  logic dump_frame_done_tx, info_dump_done_ui, info_dump_busy_ui;
  logic info_dump_error_ui;
  logic [3:0] info_dump_error_cause_ui;
  info_log_dump_subsystem dump_i (
    .ui_clk(c1_ui_clk), .tx_clk(clk125),
    .ui_resetn(info_dump_ui_resetn), .tx_resetn(info_dump_tx_resetn),
    .cdc_resetn(hard_resetn),
    .start(info_dump_start_ui),
    .h0_total_records(h0_written_records),
    .h1_total_records(h1_written_records), .axi(info_read_axi),
    .tx_tdata(dump_tx_data), .tx_tvalid(dump_tx_valid),
    .tx_tlast(dump_tx_last), .tx_tready(dump_tx_ready),
    .frame_done_tx(dump_frame_done_tx),
    .all_done_ui(info_dump_done_ui), .busy_ui(info_dump_busy_ui),
    .error_ui(info_dump_error_ui),
    .error_cause_ui(info_dump_error_cause_ui)
  );

  logic [2:0] ddr0_select_next;
  logic [2:0] ddr1_select_next;
  always_comb begin
    ddr0_select_next = {
      ddr0_owner == DDR0_OWNER_EH2,
      ddr0_owner == DDR0_OWNER_ZERO,
      ddr0_owner == DDR0_OWNER_CHECKER
    };
    ddr1_select_next = {
      ddr1_owner == DDR1_OWNER_INFO_READ,
      ddr1_owner == DDR1_OWNER_INFO_WRITE,
      ddr1_owner == DDR1_OWNER_CHECKER
    };
  end
  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      ddr0_select_ctrl <= 3'b000;
      ddr1_select_ctrl <= 3'b000;
    end else begin
      ddr0_select_ctrl <= ddr0_select_next;
      ddr1_select_ctrl <= ddr1_select_next;
    end
  end
  sync_bits #(.WIDTH(3)) ddr0_owner_sync_i (
    .clk(c0_ui_clk), .resetn(ddr0_ui_user_resetn),
    .async_in(ddr0_select_ctrl), .sync_out(ddr0_select_ui)
  );
  sync_bits #(.WIDTH(3)) ddr1_owner_sync_i (
    .clk(c1_ui_clk), .resetn(ddr1_ui_user_resetn),
    .async_in(ddr1_select_ctrl), .sync_out(ddr1_select_ui)
  );

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr0_pre_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr0_zero_axi();
  axi_owner_mux2 ddr0_program_check_mux_i (
    .select_b(ddr0_select_ui[0]), .master_a(program_ui_axi),
    .master_b(instr_check_axi), .slave_out(ddr0_pre_axi)
  );
  axi_owner_mux2 ddr0_zero_mux_i (
    .select_b(ddr0_select_ui[1]), .master_a(ddr0_pre_axi),
    .master_b(zero_axi), .slave_out(ddr0_zero_axi)
  );
  axi_owner_mux2 ddr0_eh2_mux_i (
    .select_b(ddr0_select_ui[2]), .master_a(ddr0_zero_axi),
    .master_b(eh2_ddr0_axi), .slave_out(ddr0_axi)
  );

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_pre_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) ddr1_write_phase_axi();
  axi_owner_mux2 ddr1_atg_check_mux_i (
    .select_b(ddr1_select_ui[0]), .master_a(data_atg_ui_axi),
    .master_b(data_check_axi), .slave_out(ddr1_pre_axi)
  );
  axi_owner_mux2 ddr1_write_mux_i (
    .select_b(ddr1_select_ui[1]), .master_a(ddr1_pre_axi),
    .master_b(info_write_axi), .slave_out(ddr1_write_phase_axi)
  );
  axi_owner_mux2 ddr1_read_mux_i (
    .select_b(ddr1_select_ui[2]), .master_a(ddr1_write_phase_axi),
    .master_b(info_read_axi), .slave_out(ddr1_axi)
  );

  // Register WDATA/WSTRB/WLAST at each MIG boundary.  Besides sustaining one
  // beat per UI clock, these slices prevent the phase-owner mux chain from
  // directly driving hundreds of registers inside each MIG upsizer across an
  // SLR boundary.
  axi_w_channel_register_slice ddr0_w_slice_i (
    .clk(c0_ui_clk), .resetn(ddr0_ui_user_resetn),
    .source(ddr0_axi), .sink(ddr0_mig_axi)
  );
  axi_w_channel_register_slice ddr1_w_slice_i (
    .clk(c1_ui_clk), .resetn(ddr1_ui_user_resetn),
    .source(ddr1_axi), .sink(ddr1_mig_axi)
  );

  logic [1:0] started_ctrl, stopped_ctrl;
  sync_bits #(.WIDTH(4)) eh2_status_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({eh2_started_core,eh2_stopped_core}),
    .sync_out({started_ctrl,stopped_ctrl})
  );

  logic [7:0] ifu_wr_outstanding, ifu_rd_outstanding;
  logic [7:0] lsu_wr_outstanding, lsu_rd_outstanding;
  wire ifu_aw_hs = ifu_axi64.awvalid && ifu_axi64.awready;
  wire ifu_b_hs = ifu_axi64.bvalid && ifu_axi64.bready;
  wire ifu_ar_hs = ifu_axi64.arvalid && ifu_axi64.arready;
  wire ifu_r_hs = ifu_axi64.rvalid && ifu_axi64.rready && ifu_axi64.rlast;
  wire lsu_aw_hs = lsu_axi64.awvalid && lsu_axi64.awready;
  wire lsu_b_hs = lsu_axi64.bvalid && lsu_axi64.bready;
  wire lsu_ar_hs = lsu_axi64.arvalid && lsu_axi64.arready;
  wire lsu_r_hs = lsu_axi64.rvalid && lsu_axi64.rready && lsu_axi64.rlast;
  always_ff @(posedge core_clk or negedge eh2_cycle_resetn) begin
    if (!eh2_cycle_resetn) begin
      ifu_wr_outstanding <= 0; ifu_rd_outstanding <= 0;
      lsu_wr_outstanding <= 0; lsu_rd_outstanding <= 0;
    end else begin
      case ({ifu_aw_hs,ifu_b_hs})
        2'b10: ifu_wr_outstanding <= ifu_wr_outstanding+1'b1;
        2'b01: ifu_wr_outstanding <= ifu_wr_outstanding-1'b1;
        default: ;
      endcase
      case ({ifu_ar_hs,ifu_r_hs})
        2'b10: ifu_rd_outstanding <= ifu_rd_outstanding+1'b1;
        2'b01: ifu_rd_outstanding <= ifu_rd_outstanding-1'b1;
        default: ;
      endcase
      case ({lsu_aw_hs,lsu_b_hs})
        2'b10: lsu_wr_outstanding <= lsu_wr_outstanding+1'b1;
        2'b01: lsu_wr_outstanding <= lsu_wr_outstanding-1'b1;
        default: ;
      endcase
      case ({lsu_ar_hs,lsu_r_hs})
        2'b10: lsu_rd_outstanding <= lsu_rd_outstanding+1'b1;
        2'b01: lsu_rd_outstanding <= lsu_rd_outstanding-1'b1;
        default: ;
      endcase
    end
  end
  logic eh2_axi_idle_core;
  always_ff @(posedge core_clk or negedge eh2_cycle_resetn) begin
    if (!eh2_cycle_resetn)
      eh2_axi_idle_core <= 1'b0;
    else
      eh2_axi_idle_core <= (ifu_wr_outstanding == 0) &&
        (ifu_rd_outstanding == 0) && (lsu_wr_outstanding == 0) &&
        (lsu_rd_outstanding == 0) && !ifu_axi64.awvalid &&
        !ifu_axi64.wvalid && !ifu_axi64.arvalid && !lsu_axi64.awvalid &&
        !lsu_axi64.wvalid && !lsu_axi64.arvalid;
  end
  logic [0:0] eh2_axi_idle_ctrl;
  sync_bits #(.WIDTH(1)) eh2_axi_idle_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in(eh2_axi_idle_core), .sync_out(eh2_axi_idle_ctrl)
  );

  logic [7:0] log_tx_data;
  logic log_tx_valid, log_tx_last, log_tx_ready;
  assign log_tx_data = dump_tx_data;
  assign log_tx_valid = dump_tx_valid;
  assign log_tx_last = dump_tx_last;
  assign dump_tx_ready = log_tx_ready;

  logic prefer_log_tx;
  logic [0:0] prefer_log_tx125;
  sync_bits #(.WIDTH(1), .STAGES(3)) prefer_log_tx_sync_i (
    .clk(clk125), .resetn(hard_resetn),
    .async_in(prefer_log_tx), .sync_out(prefer_log_tx125)
  );
  system_tx_arbiter tx_arbiter_i (
    .clk(clk125), .resetn(hard_resetn), .prefer_log(prefer_log_tx125[0]),
    .info_tdata(info_tx125_data), .info_tvalid(info_tx125_valid),
    .info_tlast(info_tx125_last), .info_tready(info_tx125_ready),
    .log_tdata(log_tx_data), .log_tvalid(log_tx_valid),
    .log_tlast(log_tx_last), .log_tready(log_tx_ready),
    .m_axis_tdata(mac_tx_data), .m_axis_tvalid(mac_tx_valid),
    .m_axis_tlast(mac_tx_last), .m_axis_tready(mac_tx_ready)
  );

  logic [0:0] info_write_done_ctrl, info_dump_done_ctrl;
  logic [1:0] info_write_error_ctrl;
  logic [3:0] info_dump_error_cause_ctrl;
  sync_bits #(.WIDTH(8)) info_dma_status_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({info_dump_error_cause_ui,info_region_overflow,
               info_write_axi_error,
               info_dump_done_ui,info_write_done_ui}),
    .sync_out({info_dump_error_cause_ctrl,info_write_error_ctrl,
               info_dump_done_ctrl,
               info_write_done_ctrl})
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
  // Preserve each producer stage as an independent status bit.  In the old
  // design physical FIFO, elastic queue and capture overflow were ORed in the
  // 50 MHz domain and all appeared at the host as C1/C2.
  logic [12:0] eh2_error_status_ctrl;
  sync_bits #(.WIDTH(13)) eh2_error_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in({waw_cause_error_core,info_fifo_wr_overflow,
               info_queue_overflow,capture_overflow_core,lsu_axi_error_core,
               ifu_axi_error_core,eh2_init_error_core,nb_error_core}),
    .sync_out(eh2_error_status_ctrl)
  );
  logic [0:0] eh2_init_done_ctrl;
  sync_bits #(.WIDTH(1)) eh2_init_done_sync_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .async_in(eh2_init_done_core), .sync_out(eh2_init_done_ctrl)
  );
  localparam integer INIT_TIMEOUT_CYCLES = 500_000_000;
  logic [28:0] init_timeout_counter;
  logic init_timeout;
  always_ff @(posedge ctrl_clk or negedge hard_resetn) begin
    if (!hard_resetn) begin
      init_timeout_counter <= 29'd0;
      init_timeout <= 1'b0;
    end else if (mac_config_done && phy_init_success && rgmii_rx_ready &&
                 c0_calib_done_ctrl && c1_calib_done_ctrl) begin
      init_timeout_counter <= init_timeout_counter;
    end else if (init_timeout_counter == INIT_TIMEOUT_CYCLES-1) begin
      init_timeout <= 1'b1;
    end else begin
      init_timeout_counter <= init_timeout_counter + 29'd1;
    end
  end

  logic fatal_error_pending;
  logic [31:0] fatal_error_code;
  system_error_monitor error_monitor_i (
    .clk(ctrl_clk), .resetn(hard_resetn), .clear(1'b0),
    .err_nb_hart0(eh2_error_status_ctrl[0]),
    .err_nb_hart1(eh2_error_status_ctrl[1]),
    .err_hash_hart0(1'b0),
    .err_hash_hart1(1'b0),
    .err_txmac_fifo(tx_fifo_overflow),
    .err_txmac_stream(info_tx_cdc_overflow),
    .err_waw_hart0(1'b0),
    .err_waw_hart1(1'b0),
    .err_bank_hart0(1'b0),
    .err_bank_hart1(1'b0),
    .err_info_rx_fifo(info_rx_overflow),
    .err_info_tx_fifo(info_tx_overflow),
    .err_rx_frame_buf(rx_frame_buffer_overflow || rx_fifo_overflow),
    .err_rx_frame_len(rx_frame_length_error || malformed_info_frame ||
                      program_frame_length_error),
    .err_mac_rx_fcs(rx_fcs_error_pulse),
    .err_mac_config(mac_config_error ||
                    (init_timeout && !mac_config_done)),
    .err_phy_init((|phy_init_error) ||
                  (init_timeout && !phy_init_success)),
    .err_phy_link((phy_init_done && !phy_link_up) ||
                  (init_timeout && !rgmii_rx_ready)),
    .err_mig0(init_timeout && !c0_calib_done_ctrl),
    .err_mig1(init_timeout && !c1_calib_done_ctrl),
    .err_ddr_zero(op_status_ctrl[5]),
    .err_ddr_check(1'b0),
    .err_eh2_init(eh2_error_status_ctrl[2]),
    .err_eh2_ifu_axi(eh2_error_status_ctrl[3]),
    .err_eh2_lsu_axi(eh2_error_status_ctrl[4]),
    .err_program_write(program_dma_error),
    .err_program_fifo(rx_fifo_overflow),
    .err_program_dma(datamover_error),
    .err_program_sequence(program_sequence_error),
    .err_info_fifo_h0(eh2_error_status_ctrl[9]),
    .err_info_fifo_h1(eh2_error_status_ctrl[10]),
    .err_info_queue_h0(eh2_error_status_ctrl[7]),
    .err_info_queue_h1(eh2_error_status_ctrl[8]),
    .err_info_capture_h0(eh2_error_status_ctrl[5]),
    .err_info_capture_h1(eh2_error_status_ctrl[6]),
    .err_info_dma(|info_write_error_ctrl),
    .err_info_dump(info_dump_error_cause_ctrl[0]),
    .err_info_dump_read_protocol(info_dump_error_cause_ctrl[1]),
    .err_info_dump_frame_protocol(info_dump_error_cause_ctrl[2]),
    .err_info_dump_release(info_dump_error_cause_ctrl[3]),
    .err_waw_cause_h0(eh2_error_status_ctrl[11]),
    .err_waw_cause_h1(eh2_error_status_ctrl[12]),
    .pending(fatal_error_pending), .code(fatal_error_code)
  );

  logic led0;
  eh2_system_controller controller_i (
    .clk(ctrl_clk), .resetn(hard_resetn),
    .mac_config_done, .phy_init_done(phy_init_success),
    .phy_link_up, .rgmii_rx_ready,
    .mig0_ready(c0_calib_done_ctrl),
    .mig1_ready(c1_calib_done_ctrl),
    .preconfig_program_end_pulse(system_program_end_pulse),
    .program_first_write_pulse, .program_end_pulse(system_program_end_pulse),
    .program_end_total_count(system_program_end_total_count),
    .program_frame_count, .program_dma_done_count,
    .program_dma_busy,
    .host_send_stopped_pulse,
    .host_global_reset_pulse,
    .host_info_retransmit_all_pulse,
    .data_atg_done(data_atg_status_ctrl[0]),
    .data_atg_error(data_atg_status_ctrl[1]),
    .instr_check_done(op_status_ctrl[0]),
    .instr_check_pass(instr_status_ctrl[0]),
    .instr_check_error(instr_status_ctrl[1]),
    .data_check_done(op_status_ctrl[1]),
    .data_check_pass(op_status_ctrl[2]),
    .data_check_error(op_status_ctrl[3]),
    .zero_done(zero_done_ctrl), .zero_error(op_status_ctrl[5]),
    .eh2_init_done(eh2_init_done_ctrl[0]),
    .eh2_init_error(eh2_error_status_ctrl[2]),
    .eh2_started(started_ctrl), .eh2_stopped(stopped_ctrl),
    .eh2_axi_idle(eh2_axi_idle_ctrl[0]),
    .info_write_done(info_write_done_ctrl[0]),
    .info_dump_done(info_dump_done_ctrl[0]),
    .fatal_error_pending, .fatal_error_code,
    .info_tx_full, .info_frame_done, .info_sent_code,
    .tx_frame_complete_count, .tx_submitted_frame_count,
    .info_tx_push, .info_tx_code, .data_atg_start(data_atg_start_ctrl),
    .instr_check_start(instr_check_start_ctrl),
    .data_check_start(data_check_start_ctrl), .zero_start(zero_start_ctrl),
    .program_session_clear, .global_reset_request,
    .eh2_execute_enable(eh2_execute_enable_ctrl),
    .prefer_log_tx, .info_dump_start(info_dump_start_ctrl),
    .led0, .state(system_state),
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
