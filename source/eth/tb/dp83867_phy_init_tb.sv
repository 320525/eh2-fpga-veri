`timescale 1ns / 1ps

// Focused verification for dp83867_phy_init.  This test supplies a compact
// behavioral model of the TEMAC management registers and a DP83867 at PHY
// address 3; it is intentionally independent of the full Ethernet/DMA test.
module dp83867_phy_init_tb;

  reg clk = 1'b0;
  reg resetn = 1'b0;
  reg start = 1'b0;
  always #5 clk = ~clk;

  wire phy_resetn;
  wire init_busy;
  wire init_done;
  wire init_success;
  wire [3:0] init_error;
  wire [4:0] detected_phy_addr;
  wire [15:0] phy_id1;
  wire [15:0] phy_id2;
  wire phy_link_up;
  wire phy_autoneg_complete;

  wire [11:0] awaddr;
  wire awvalid;
  reg awready = 1'b1;
  wire [31:0] wdata;
  wire wvalid;
  reg wready = 1'b1;
  reg [1:0] bresp = 2'b00;
  reg bvalid = 1'b0;
  wire bready;
  wire [11:0] araddr;
  wire arvalid;
  reg arready = 1'b1;
  reg [31:0] rdata = 32'd0;
  reg [1:0] rresp = 2'b00;
  reg rvalid = 1'b0;
  wire rready;

  dp83867_phy_init #(
    .PHY_RESET_HOLD_CYCLES(4),
    .PHY_POST_RESET_CYCLES(3),
    .SW_RESET_WAIT_CYCLES(4),
    .MDIO_POLL_LIMIT(64)
  ) dut (
    .clk(clk),
    .resetn(resetn),
    .start(start),
    .phy_resetn(phy_resetn),
    .init_busy(init_busy),
    .init_done(init_done),
    .init_success(init_success),
    .init_error(init_error),
    .detected_phy_addr(detected_phy_addr),
    .phy_id1(phy_id1),
    .phy_id2(phy_id2),
    .phy_link_up(phy_link_up),
    .phy_autoneg_complete(phy_autoneg_complete),
    .m_axi_awaddr(awaddr),
    .m_axi_awvalid(awvalid),
    .m_axi_awready(awready),
    .m_axi_wdata(wdata),
    .m_axi_wvalid(wvalid),
    .m_axi_wready(wready),
    .m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .m_axi_araddr(araddr),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rdata(rdata),
    .m_axi_rresp(rresp),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready)
  );

  reg [11:0] captured_awaddr;
  reg [31:0] captured_wdata;
  reg aw_captured = 1'b0;
  reg w_captured = 1'b0;
  reg read_pending = 1'b0;
  reg [11:0] captured_araddr;

  reg [15:0] temac_mdio_wdata = 16'd0;
  reg [15:0] temac_mdio_rdata = 16'd0;
  reg temac_mdio_ready = 1'b1;
  integer mdio_busy_count = 0;
  reg mdio_op_write = 1'b0;
  reg [4:0] mdio_op_phy = 5'd0;
  reg [4:0] mdio_op_reg = 5'd0;

  reg [15:0] bmcr = 16'h1140;
  reg [15:0] bmsr = 16'h782D;
  reg [15:0] mmd_ctrl = 16'd0;
  reg [15:0] mmd_addr = 16'd0;
  reg [15:0] rgmii_ctl = 16'h0083;
  reg [15:0] rgmii_delay = 16'h0000;

  task complete_mdio_operation;
    begin
      if (mdio_op_phy != 5'd3) begin
        temac_mdio_rdata = 16'hFFFF;
      end
      else if (mdio_op_write) begin
        case (mdio_op_reg)
          5'h00: bmcr = temac_mdio_wdata;
          5'h0D: mmd_ctrl = temac_mdio_wdata;
          5'h0E: begin
            if (!mmd_ctrl[14]) begin
              mmd_addr = temac_mdio_wdata;
            end
            else begin
              case (mmd_addr)
                16'h0032: rgmii_ctl = temac_mdio_wdata;
                16'h0086: rgmii_delay = temac_mdio_wdata;
                default: ;
              endcase
            end
          end
          5'h1F: begin
            if (temac_mdio_wdata[15]) begin
              bmcr        = 16'h1140;
              mmd_ctrl    = 16'd0;
              mmd_addr    = 16'd0;
              rgmii_ctl   = 16'h0083;
              rgmii_delay = 16'h0000;
            end
          end
          default: ;
        endcase
      end
      else begin
        case (mdio_op_reg)
          5'h00: temac_mdio_rdata = bmcr;
          5'h01: temac_mdio_rdata = bmsr;
          5'h02: temac_mdio_rdata = 16'h2000;
          5'h03: temac_mdio_rdata = 16'hA231;
          5'h0D: temac_mdio_rdata = mmd_ctrl;
          5'h0E: begin
            case (mmd_addr)
              16'h0032: temac_mdio_rdata = rgmii_ctl;
              16'h0086: temac_mdio_rdata = rgmii_delay;
              default:  temac_mdio_rdata = 16'h0000;
            endcase
          end
          default: temac_mdio_rdata = 16'h0000;
        endcase
      end
      temac_mdio_ready = 1'b1;
    end
  endtask

  task execute_axi_write;
    input [11:0] address;
    input [31:0] data;
    begin
      case (address)
        12'h508: temac_mdio_wdata = data[15:0];
        12'h504: begin
          mdio_op_phy    = data[28:24];
          mdio_op_reg    = data[20:16];
          mdio_op_write  = (data[15:14] == 2'b01);
          temac_mdio_ready = 1'b0;
          mdio_busy_count  = 3;
        end
        default: ;
      endcase
    end
  endtask

  always @(posedge clk) begin
    if (!resetn) begin
      bvalid <= 1'b0;
      rvalid <= 1'b0;
      aw_captured <= 1'b0;
      w_captured <= 1'b0;
      read_pending <= 1'b0;
      temac_mdio_ready <= 1'b1;
      mdio_busy_count <= 0;
    end
    else begin
      if (awvalid && awready) begin
        captured_awaddr <= awaddr;
        aw_captured <= 1'b1;
      end
      if (wvalid && wready) begin
        captured_wdata <= wdata;
        w_captured <= 1'b1;
      end
      if (aw_captured && w_captured && !bvalid) begin
        execute_axi_write(captured_awaddr, captured_wdata);
        aw_captured <= 1'b0;
        w_captured <= 1'b0;
        bvalid <= 1'b1;
        bresp <= 2'b00;
      end
      if (bvalid && bready)
        bvalid <= 1'b0;

      if (arvalid && arready && !read_pending && !rvalid) begin
        captured_araddr <= araddr;
        read_pending <= 1'b1;
      end
      if (read_pending && !rvalid) begin
        read_pending <= 1'b0;
        case (captured_araddr)
          12'h50C: rdata <= {15'd0, temac_mdio_ready,
                             temac_mdio_rdata};
          default:   rdata <= 32'd0;
        endcase
        rresp <= 2'b00;
        rvalid <= 1'b1;
      end
      if (rvalid && rready)
        rvalid <= 1'b0;

      if (!temac_mdio_ready) begin
        if (mdio_busy_count == 0)
          complete_mdio_operation();
        else
          mdio_busy_count <= mdio_busy_count - 1;
      end
    end
  end

  initial begin
    repeat (4) @(posedge clk);
    resetn <= 1'b1;
    start  <= 1'b1;

    fork
      begin
        wait (init_done);
        if (!init_success)
          $fatal(1, "PHY initialization failed, error=%0h", init_error);
        if (detected_phy_addr != 5'd3)
          $fatal(1, "Wrong detected PHY address: %0d", detected_phy_addr);
        if ((phy_id1 != 16'h2000) || (phy_id2[15:4] != 12'hA23))
          $fatal(1, "Wrong PHY ID: %04h_%04h", phy_id1, phy_id2);
        if ((rgmii_ctl & 16'h0083) != 16'h0083)
          $fatal(1, "RGMIICTL mismatch: %04h", rgmii_ctl);
        if (rgmii_delay != 16'h0075)
          $fatal(1, "RGMIIDCTL mismatch: %04h", rgmii_delay);
        if (!bmcr[12] || !bmcr[9] || bmcr[11] || bmcr[10])
          $fatal(1, "BMCR auto-negotiation configuration mismatch: %04h",
                 bmcr);
        $display("PASS: DP83867 found at address %0d, ID=%04h_%04h, RGMIICTL=%04h, RGMIIDCTL=%04h",
                 detected_phy_addr, phy_id1, phy_id2,
                 rgmii_ctl, rgmii_delay);
        $finish;
      end
      begin
        repeat (20000) @(posedge clk);
        $fatal(1, "Timeout waiting for PHY initialization");
      end
    join_any
    disable fork;
  end

endmodule
