`timescale 1ns / 1ps

module eth_tx_core_tb;

  reg gtx_clk = 1'b0;
  reg refclk = 1'b0;
  reg s_axi_aclk = 1'b0;
  reg rgmii_rxc = 1'b0;
  reg system_resetn = 1'b0;

  always #4.000 gtx_clk = ~gtx_clk;
  always #1.500 refclk = ~refclk;
  always #5.000 s_axi_aclk = ~s_axi_aclk;
  always #4.000 rgmii_rxc = ~rgmii_rxc;

  wire [3:0] rgmii_txd;
  wire       rgmii_tx_ctl;
  wire       rgmii_txc;
  wire       mdio;
  wire       mdc;
  wire       phy_resetn;
  wire       mac_config_done;
  wire       mac_config_error;
  wire       phy_init_busy;
  wire       phy_init_done;
  wire       phy_init_success;
  wire [3:0] phy_init_error;
  wire [4:0] phy_addr;
  wire [15:0] phy_id1;
  wire [15:0] phy_id2;
  wire       phy_link_up;
  wire       phy_autoneg_complete;
  wire       tx_control_done;
  wire [31:0] tx_control_status;
  wire       tx_atg_error;
  wire [3:0] tx_fifo_status;
  wire       tx_fifo_overflow;
  wire [3:0] tx_fifo_frame_count;
  wire [3:0] tx_mac_frame_count;
  wire       tx_length_error;
  wire       inband_link_status;
  wire [1:0] inband_clock_speed;
  wire       inband_duplex_status;
  wire       mac_irq;

  eth_tx_core #(
    .PHY_INIT_BYPASS (1)
  ) dut (
    .gtx_clk                 (gtx_clk),
    .refclk                  (refclk),
    .s_axi_aclk              (s_axi_aclk),
    .system_resetn           (system_resetn),
    .rgmii_txd               (rgmii_txd),
    .rgmii_tx_ctl            (rgmii_tx_ctl),
    .rgmii_txc               (rgmii_txc),
    .rgmii_rxd               (4'h0),
    .rgmii_rx_ctl            (1'b0),
    .rgmii_rxc               (rgmii_rxc),
    .mdio                    (mdio),
    .mdc                     (mdc),
    .phy_resetn              (phy_resetn),
    .mac_config_done         (mac_config_done),
    .mac_config_error        (mac_config_error),
    .phy_init_busy           (phy_init_busy),
    .phy_init_done           (phy_init_done),
    .phy_init_success        (phy_init_success),
    .phy_init_error          (phy_init_error),
    .phy_addr                (phy_addr),
    .phy_id1                 (phy_id1),
    .phy_id2                 (phy_id2),
    .phy_link_up             (phy_link_up),
    .phy_autoneg_complete    (phy_autoneg_complete),
    .tx_control_done         (tx_control_done),
    .tx_control_status       (tx_control_status),
    .tx_atg_error            (tx_atg_error),
    .tx_fifo_status          (tx_fifo_status),
    .tx_fifo_overflow        (tx_fifo_overflow),
    .tx_fifo_frame_count     (tx_fifo_frame_count),
    .tx_mac_frame_count      (tx_mac_frame_count),
    .tx_length_error         (tx_length_error),
    .inband_link_status      (inband_link_status),
    .inband_clock_speed      (inband_clock_speed),
    .inband_duplex_status    (inband_duplex_status),
    .mac_irq                 (mac_irq)
  );

  function automatic [7:0] expected_frame_byte(input integer byte_index);
    begin
      case (byte_index)
        0, 1, 2, 3, 4, 5: expected_frame_byte = 8'hFF;
        6:  expected_frame_byte = 8'h02;
        7:  expected_frame_byte = 8'h12;
        8:  expected_frame_byte = 8'h34;
        9:  expected_frame_byte = 8'h56;
        10: expected_frame_byte = 8'h78;
        11: expected_frame_byte = 8'hFF;
        12: expected_frame_byte = 8'h88;
        13: expected_frame_byte = 8'hB5;
        default: expected_frame_byte = byte_index - 14;
      endcase
    end
  endfunction

  integer mac_byte_index = 0;
  integer mac_frame_index = 0;
  integer error_count = 0;
  reg saw_rgmii_activity = 1'b0;

  always @(posedge dut.tx_mac_aclk) begin
    if (dut.tx_reset) begin
      mac_byte_index <= 0;
      mac_frame_index <= 0;
    end
    else if (dut.mac_fifo_i.tx_axis_mac_tvalid &&
             dut.mac_fifo_i.tx_axis_mac_tready) begin
      if (dut.mac_fifo_i.tx_axis_mac_tdata !==
          expected_frame_byte(mac_byte_index)) begin
        $error("TX MAC byte mismatch frame=%0d byte=%0d expected=%02h actual=%02h",
               mac_frame_index, mac_byte_index,
               expected_frame_byte(mac_byte_index),
               dut.mac_fifo_i.tx_axis_mac_tdata);
        error_count <= error_count + 1;
      end

      if (dut.mac_fifo_i.tx_axis_mac_tlast !==
          (mac_byte_index == 77)) begin
        $error("TX MAC TLAST mismatch frame=%0d byte=%0d tlast=%b",
               mac_frame_index, mac_byte_index,
               dut.mac_fifo_i.tx_axis_mac_tlast);
        error_count <= error_count + 1;
      end

      if (dut.mac_fifo_i.tx_axis_mac_tuser !== 1'b0) begin
        $error("TX MAC TUSER asserted on frame=%0d byte=%0d",
               mac_frame_index, mac_byte_index);
        error_count <= error_count + 1;
      end

      if (mac_byte_index == 77) begin
        mac_byte_index <= 0;
        mac_frame_index <= mac_frame_index + 1;
      end
      else begin
        mac_byte_index <= mac_byte_index + 1;
      end
    end
  end

  always @(posedge rgmii_txc or negedge rgmii_txc) begin
    if (system_resetn && rgmii_tx_ctl === 1'b1)
      saw_rgmii_activity <= 1'b1;
  end

  initial begin
    repeat (20) @(posedge s_axi_aclk);
    system_resetn = 1'b1;

    fork
      begin : timeout_block
        #2_000_000;
        $fatal(1, "Timeout waiting for ten transmitted frames");
      end
      begin : completion_block
        wait (mac_frame_index == 10);
        wait (tx_mac_frame_count == 4'd10);
        repeat (20) @(posedge s_axi_aclk);
        disable timeout_block;

        if (!mac_config_done || mac_config_error) begin
          $error("TEMAC configuration failed done=%b error=%b",
                 mac_config_done, mac_config_error);
          error_count = error_count + 1;
        end
        if (!phy_init_done || !phy_init_success || phy_init_error != 0) begin
          $error("PHY initialization status failed done=%b success=%b error=%h",
                 phy_init_done, phy_init_success, phy_init_error);
          error_count = error_count + 1;
        end
        if (!tx_control_done || tx_control_status[1:0] != 2'b01) begin
          $error("TX ATG programming failed done=%b status=%h",
                 tx_control_done, tx_control_status);
          error_count = error_count + 1;
        end
        if (tx_fifo_frame_count != 4'd10 || tx_mac_frame_count != 4'd10) begin
          $error("Frame counts incorrect fifo=%0d mac=%0d",
                 tx_fifo_frame_count, tx_mac_frame_count);
          error_count = error_count + 1;
        end
        if (tx_atg_error || tx_fifo_overflow || tx_length_error) begin
          $error("TX status error atg=%b overflow=%b length=%b",
                 tx_atg_error, tx_fifo_overflow, tx_length_error);
          error_count = error_count + 1;
        end
        if (!saw_rgmii_activity) begin
          $error("No RGMII transmit activity observed");
          error_count = error_count + 1;
        end

        if (error_count == 0) begin
          $display("ETH_TX_FRONT_SIM_PASS frames=10 bytes_per_frame=78 ethertype=88B5");
          $finish;
        end
        else begin
          $fatal(1, "ETH_TX_FRONT_SIM_FAIL errors=%0d", error_count);
        end
      end
    join
  end

endmodule
