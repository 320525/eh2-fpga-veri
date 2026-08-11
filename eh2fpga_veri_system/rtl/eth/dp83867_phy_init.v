`timescale 1ns / 1ps

// DP83867IR startup controller for the MDIO interface contained in the
// Tri-Mode Ethernet MAC.  All PHY transactions are performed by accessing
// the TEMAC MDIO registers through its AXI4-Lite management interface.
//
// The controller intentionally scans all Clause-22 PHY addresses.  The
// HSPI2-057-UTEH-A20 schematic does not strap a fixed address and explicitly
// requires the host to discover the device through MDIO.
module dp83867_phy_init #(
  // Defaults assume the existing 100 MHz TEMAC AXI4-Lite clock.
  parameter integer PHY_RESET_HOLD_CYCLES = 1024,
  // DP83867 requires at least 195 us from RESET_N deassertion to the first
  // MDIO preamble.  At the board's 100 MHz management clock, 20,000 cycles
  // provide a 200 us guard interval.
  parameter integer PHY_POST_RESET_CYCLES = 20000,
  parameter integer SW_RESET_WAIT_CYCLES  = 100000,
  // After restarting auto-negotiation, poll BMSR every 10 ms and require
  // link plus auto-negotiation complete to remain asserted for 100 ms.
  // This prevents the one-shot TX generator from exhausting all ten frames
  // while the copper link is still renegotiating.
  parameter integer LINK_POLL_INTERVAL_CYCLES = 1000000,
  parameter integer LINK_STABLE_WAIT_CYCLES   = 10000000,
  parameter integer MDIO_POLL_LIMIT       = 65535
) (
  input  wire        clk,
  input  wire        resetn,
  input  wire        start,

  // Active-low signal connected to HSPI2 REST_F.  The daughter card ANDs
  // this with its local RC reset before driving the DP83867 RESET_N pin.
  output reg         phy_resetn,

  output wire        init_busy,
  output reg         init_done,
  output reg         init_success,
  output reg  [3:0]  init_error,
  output reg  [4:0]  detected_phy_addr,
  output reg  [15:0] phy_id1,
  output reg  [15:0] phy_id2,
  output reg         phy_link_up,
  output reg         phy_autoneg_complete,

  // AXI4-Lite master connection to the TEMAC management register space.
  output wire [11:0] m_axi_awaddr,
  output wire        m_axi_awvalid,
  input  wire        m_axi_awready,
  output wire [31:0] m_axi_wdata,
  output wire        m_axi_wvalid,
  input  wire        m_axi_wready,
  input  wire [1:0]  m_axi_bresp,
  input  wire        m_axi_bvalid,
  output wire        m_axi_bready,
  output wire [11:0] m_axi_araddr,
  output wire        m_axi_arvalid,
  input  wire        m_axi_arready,
  input  wire [31:0] m_axi_rdata,
  input  wire [1:0]  m_axi_rresp,
  input  wire        m_axi_rvalid,
  output wire        m_axi_rready
);

  // Error values are kept stable after init_done so they can be routed to
  // an ILA or status register without decoding the internal state machine.
  localparam [3:0] ERR_NONE          = 4'h0;
  localparam [3:0] ERR_AXI_RESPONSE  = 4'h1;
  localparam [3:0] ERR_MDIO_TIMEOUT  = 4'h2;
  localparam [3:0] ERR_PHY_NOT_FOUND = 4'h3;
  localparam [3:0] ERR_ID_AFTER_RST  = 4'h4;
  localparam [3:0] ERR_RGMIICTL      = 4'h5;
  localparam [3:0] ERR_RGMIIDCTL     = 4'h6;

  // DP83867 Clause-22 registers.
  localparam [4:0] REG_BMCR  = 5'h00;
  localparam [4:0] REG_BMSR  = 5'h01;
  localparam [4:0] REG_ID1   = 5'h02;
  localparam [4:0] REG_ID2   = 5'h03;
  localparam [4:0] REG_MMDCR = 5'h0D;
  localparam [4:0] REG_MMDDR = 5'h0E;
  localparam [4:0] REG_CTRL  = 5'h1F;

  // TI extended register addresses accessed through MMD device 0x1F.
  localparam [15:0] EXT_RGMIICTL  = 16'h0032;
  localparam [15:0] EXT_RGMIIDCTL = 16'h0086;

  reg [31:0] reset_counter;
  reg [31:0] post_reset_counter;
  reg        phy_mdio_ready;

  // Assert PHY reset asynchronously with the board-wide reset.  After
  // release, keep MDIO inactive for longer than one MDC period as required
  // by the DP83867 serial-management timing specification.
  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      phy_resetn         <= 1'b0;
      phy_mdio_ready     <= 1'b0;
      reset_counter      <= 32'd0;
      post_reset_counter <= 32'd0;
    end
    else if (!phy_resetn) begin
      phy_mdio_ready     <= 1'b0;
      post_reset_counter <= 32'd0;
      if (reset_counter >= PHY_RESET_HOLD_CYCLES - 1) begin
        phy_resetn    <= 1'b1;
        reset_counter <= 32'd0;
      end
      else begin
        reset_counter <= reset_counter + 1'b1;
      end
    end
    else if (!phy_mdio_ready) begin
      if (post_reset_counter >= PHY_POST_RESET_CYCLES - 1) begin
        phy_mdio_ready     <= 1'b1;
        post_reset_counter <= 32'd0;
      end
      else begin
        post_reset_counter <= post_reset_counter + 1'b1;
      end
    end
  end

  // Clause-22 request/response link to the TEMAC MDIO transaction engine.
  reg         mdio_req_valid;
  wire        mdio_req_ready;
  reg         mdio_req_write;
  reg  [4:0]  mdio_req_phy_addr;
  reg  [4:0]  mdio_req_reg_addr;
  reg  [15:0] mdio_req_write_data;
  wire        mdio_rsp_valid;
  wire [15:0] mdio_rsp_read_data;
  wire [1:0]  mdio_rsp_error;

  temac_mdio_axi_master #(
    .POLL_LIMIT(MDIO_POLL_LIMIT)
  ) mdio_master_i (
    .clk(clk),
    .resetn(resetn),
    .req_valid(mdio_req_valid),
    .req_ready(mdio_req_ready),
    .req_write(mdio_req_write),
    .req_phy_addr(mdio_req_phy_addr),
    .req_reg_addr(mdio_req_reg_addr),
    .req_write_data(mdio_req_write_data),
    .rsp_valid(mdio_rsp_valid),
    .rsp_read_data(mdio_rsp_read_data),
    .rsp_error(mdio_rsp_error),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wready(m_axi_wready),
    .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bready(m_axi_bready),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready)
  );

  localparam [6:0]
    ST_WAIT_START          = 7'd0,
    ST_SCAN_ID1_CMD        = 7'd1,
    ST_SCAN_ID1_CHECK      = 7'd2,
    ST_SCAN_ID2_CMD        = 7'd3,
    ST_SCAN_ID2_CHECK      = 7'd4,
    ST_GLOBAL_RESET_CMD    = 7'd5,
    ST_SW_RESET_WAIT       = 7'd6,
    ST_VERIFY_ID1_CMD      = 7'd7,
    ST_VERIFY_ID1_CHECK    = 7'd8,
    ST_VERIFY_ID2_CMD      = 7'd9,
    ST_VERIFY_ID2_CHECK    = 7'd10,
    ST_CTL_RD_MMDCR        = 7'd11,
    ST_CTL_RD_ADDR         = 7'd12,
    ST_CTL_RD_DATA_MODE    = 7'd13,
    ST_CTL_RD_VALUE        = 7'd14,
    ST_CTL_PREP_WRITE      = 7'd15,
    ST_CTL_WR_MMDCR        = 7'd16,
    ST_CTL_WR_ADDR         = 7'd17,
    ST_CTL_WR_DATA_MODE    = 7'd18,
    ST_CTL_WR_VALUE        = 7'd19,
    ST_DLY_WR_MMDCR        = 7'd20,
    ST_DLY_WR_ADDR         = 7'd21,
    ST_DLY_WR_DATA_MODE    = 7'd22,
    ST_DLY_WR_VALUE        = 7'd23,
    ST_BMCR_RD_CMD         = 7'd24,
    ST_BMCR_PREP_WRITE     = 7'd25,
    ST_BMCR_WR_CMD         = 7'd26,
    ST_VCTL_RD_MMDCR       = 7'd27,
    ST_VCTL_RD_ADDR        = 7'd28,
    ST_VCTL_RD_DATA_MODE   = 7'd29,
    ST_VCTL_RD_VALUE       = 7'd30,
    ST_VCTL_CHECK          = 7'd31,
    ST_VDLY_RD_MMDCR       = 7'd32,
    ST_VDLY_RD_ADDR        = 7'd33,
    ST_VDLY_RD_DATA_MODE   = 7'd34,
    ST_VDLY_RD_VALUE       = 7'd35,
    ST_VDLY_CHECK          = 7'd36,
    ST_BMSR_FIRST_CMD      = 7'd37,
    ST_BMSR_SECOND_CMD     = 7'd38,
    ST_BMSR_CAPTURE        = 7'd39,
    ST_SUCCESS             = 7'd40,
    ST_ERROR               = 7'd41,
    ST_HALT                = 7'd42,
    ST_LINK_POLL_WAIT      = 7'd43,
    ST_LINK_STABLE_WAIT    = 7'd44,
    ST_MDIO_LAUNCH         = 7'd126,
    ST_MDIO_WAIT           = 7'd127;

  reg [6:0] state;
  reg [6:0] mdio_return_state;
  reg [4:0] scan_addr;
  reg [15:0] last_mdio_read;
  reg [15:0] rgmii_ctl_new;
  reg [15:0] bmcr_new;
  reg [31:0] sw_reset_counter;
  reg [31:0] link_wait_counter;
  reg        link_stable_pending;

  assign init_busy = start && !init_done;

  // Set up one Clause-22 access.  The shared launch/wait states hold the
  // request until accepted and route the returned data to the requested
  // continuation state.
  task launch_mdio;
    input        write_access;
    input [4:0]  phy_address;
    input [4:0]  register_address;
    input [15:0] write_data;
    input [6:0]  return_state;
    begin
      mdio_req_write      <= write_access;
      mdio_req_phy_addr   <= phy_address;
      mdio_req_reg_addr   <= register_address;
      mdio_req_write_data <= write_data;
      mdio_return_state   <= return_state;
      state               <= ST_MDIO_LAUNCH;
    end
  endtask

  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state                 <= ST_WAIT_START;
      mdio_return_state     <= ST_WAIT_START;
      mdio_req_valid        <= 1'b0;
      mdio_req_write        <= 1'b0;
      mdio_req_phy_addr     <= 5'd0;
      mdio_req_reg_addr     <= 5'd0;
      mdio_req_write_data   <= 16'd0;
      init_done             <= 1'b0;
      init_success          <= 1'b0;
      init_error            <= ERR_NONE;
      detected_phy_addr     <= 5'd0;
      phy_id1               <= 16'd0;
      phy_id2               <= 16'd0;
      phy_link_up           <= 1'b0;
      phy_autoneg_complete  <= 1'b0;
      scan_addr             <= 5'd0;
      last_mdio_read        <= 16'd0;
      rgmii_ctl_new         <= 16'd0;
      bmcr_new              <= 16'd0;
      sw_reset_counter      <= 32'd0;
      link_wait_counter     <= 32'd0;
      link_stable_pending   <= 1'b0;
    end
    else begin
      case (state)
        ST_WAIT_START: begin
          mdio_req_valid <= 1'b0;
          if (start && phy_mdio_ready) begin
            init_done            <= 1'b0;
            init_success         <= 1'b0;
            init_error           <= ERR_NONE;
            phy_link_up          <= 1'b0;
            phy_autoneg_complete <= 1'b0;
            scan_addr            <= 5'd0;
            link_wait_counter    <= 32'd0;
            link_stable_pending  <= 1'b0;
            state                <= ST_SCAN_ID1_CMD;
          end
        end

        // Scan all PHY addresses and identify DP83867 by OUI/model fields.
        ST_SCAN_ID1_CMD:
          launch_mdio(1'b0, scan_addr, REG_ID1, 16'd0,
                      ST_SCAN_ID1_CHECK);

        ST_SCAN_ID1_CHECK: begin
          if (last_mdio_read == 16'h2000) begin
            state <= ST_SCAN_ID2_CMD;
          end
          else if (scan_addr == 5'd31) begin
            init_error <= ERR_PHY_NOT_FOUND;
            state      <= ST_ERROR;
          end
          else begin
            scan_addr <= scan_addr + 1'b1;
            state     <= ST_SCAN_ID1_CMD;
          end
        end

        ST_SCAN_ID2_CMD:
          launch_mdio(1'b0, scan_addr, REG_ID2, 16'd0,
                      ST_SCAN_ID2_CHECK);

        ST_SCAN_ID2_CHECK: begin
          // Ignore the low revision nibble when recognizing DP83867.
          if (last_mdio_read[15:4] == 12'hA23) begin
            detected_phy_addr <= scan_addr;
            phy_id1           <= 16'h2000;
            phy_id2           <= last_mdio_read;
            state             <= ST_GLOBAL_RESET_CMD;
          end
          else if (scan_addr == 5'd31) begin
            init_error <= ERR_PHY_NOT_FOUND;
            state      <= ST_ERROR;
          end
          else begin
            scan_addr <= scan_addr + 1'b1;
            state     <= ST_SCAN_ID1_CMD;
          end
        end

        // Global software reset makes the subsequent configuration
        // independent of stale state left by a warm FPGA reconfiguration.
        ST_GLOBAL_RESET_CMD: begin
          sw_reset_counter <= 32'd0;
          launch_mdio(1'b1, detected_phy_addr, REG_CTRL, 16'h8000,
                      ST_SW_RESET_WAIT);
        end

        ST_SW_RESET_WAIT: begin
          if (sw_reset_counter >= SW_RESET_WAIT_CYCLES - 1) begin
            sw_reset_counter <= 32'd0;
            state            <= ST_VERIFY_ID1_CMD;
          end
          else begin
            sw_reset_counter <= sw_reset_counter + 1'b1;
          end
        end

        ST_VERIFY_ID1_CMD:
          launch_mdio(1'b0, detected_phy_addr, REG_ID1, 16'd0,
                      ST_VERIFY_ID1_CHECK);

        ST_VERIFY_ID1_CHECK: begin
          if (last_mdio_read == 16'h2000)
            state <= ST_VERIFY_ID2_CMD;
          else begin
            init_error <= ERR_ID_AFTER_RST;
            state      <= ST_ERROR;
          end
        end

        ST_VERIFY_ID2_CMD:
          launch_mdio(1'b0, detected_phy_addr, REG_ID2, 16'd0,
                      ST_VERIFY_ID2_CHECK);

        ST_VERIFY_ID2_CHECK: begin
          if (last_mdio_read[15:4] == 12'hA23) begin
            phy_id2 <= last_mdio_read;
            state   <= ST_CTL_RD_MMDCR;
          end
          else begin
            init_error <= ERR_ID_AFTER_RST;
            state      <= ST_ERROR;
          end
        end

        // Read RGMIICTL through the DP83867 indirect MMD access sequence.
        ST_CTL_RD_MMDCR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h001F,
                      ST_CTL_RD_ADDR);
        ST_CTL_RD_ADDR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDDR, EXT_RGMIICTL,
                      ST_CTL_RD_DATA_MODE);
        ST_CTL_RD_DATA_MODE:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h401F,
                      ST_CTL_RD_VALUE);
        ST_CTL_RD_VALUE:
          launch_mdio(1'b0, detected_phy_addr, REG_MMDDR, 16'd0,
                      ST_CTL_PREP_WRITE);

        ST_CTL_PREP_WRITE: begin
          // The TEMAC physical wrapper presents TXC edge-aligned with TXD on
          // the pins.  Configure the DP83867 for RGMII_ID so the PHY supplies
          // the required clock skew in both directions.  Bit 7 keeps RGMII
          // enabled, bit 1 enables the MAC-to-PHY TX clock delay, and bit 0
          // enables the PHY-to-MAC RX clock delay.  Unrelated fields retain
          // their strapped values.
          rgmii_ctl_new <= (last_mdio_read & 16'hFF7C) | 16'h0083;
          state         <= ST_CTL_WR_MMDCR;
        end

        ST_CTL_WR_MMDCR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h001F,
                      ST_CTL_WR_ADDR);
        ST_CTL_WR_ADDR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDDR, EXT_RGMIICTL,
                      ST_CTL_WR_DATA_MODE);
        ST_CTL_WR_DATA_MODE:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h401F,
                      ST_CTL_WR_VALUE);
        ST_CTL_WR_VALUE:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDDR, rgmii_ctl_new,
                      ST_DLY_WR_MMDCR);

        // Keep the MAC-to-PHY transmit clock delay at 2.00 ns (TX code 7).
        // Use 1.25 ns on the PHY-to-MAC receive clock (RX code 4).  The prior
        // 1.50 ns setting left only 0.047 ns routed hold margin. Advancing the
        // receive clock by 0.25 ns transfers that excess setup margin to hold
        // while keeping both sides positive across implementation corners.
        ST_DLY_WR_MMDCR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h001F,
                      ST_DLY_WR_ADDR);
        ST_DLY_WR_ADDR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDDR, EXT_RGMIIDCTL,
                      ST_DLY_WR_DATA_MODE);
        ST_DLY_WR_DATA_MODE:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h401F,
                      ST_DLY_WR_VALUE);
        ST_DLY_WR_VALUE:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDDR, 16'h0074,
                      ST_BMCR_RD_CMD);

        // Preserve negotiated speed/duplex defaults, remove isolate and
        // power-down, enable auto-negotiation and request a new negotiation.
        ST_BMCR_RD_CMD:
          launch_mdio(1'b0, detected_phy_addr, REG_BMCR, 16'd0,
                      ST_BMCR_PREP_WRITE);
        ST_BMCR_PREP_WRITE: begin
          bmcr_new <= (last_mdio_read & 16'hF3FF) | 16'h1200;
          state    <= ST_BMCR_WR_CMD;
        end
        ST_BMCR_WR_CMD:
          launch_mdio(1'b1, detected_phy_addr, REG_BMCR, bmcr_new,
                      ST_VCTL_RD_MMDCR);

        // Read back RGMIICTL and RGMIIDCTL.  Initialization success means
        // the intended values were accepted, not that a cable is present.
        ST_VCTL_RD_MMDCR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h001F,
                      ST_VCTL_RD_ADDR);
        ST_VCTL_RD_ADDR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDDR, EXT_RGMIICTL,
                      ST_VCTL_RD_DATA_MODE);
        ST_VCTL_RD_DATA_MODE:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h401F,
                      ST_VCTL_RD_VALUE);
        ST_VCTL_RD_VALUE:
          launch_mdio(1'b0, detected_phy_addr, REG_MMDDR, 16'd0,
                      ST_VCTL_CHECK);
        ST_VCTL_CHECK: begin
          if ((last_mdio_read & 16'h0083) == 16'h0083)
            state <= ST_VDLY_RD_MMDCR;
          else begin
            init_error <= ERR_RGMIICTL;
            state      <= ST_ERROR;
          end
        end

        ST_VDLY_RD_MMDCR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h001F,
                      ST_VDLY_RD_ADDR);
        ST_VDLY_RD_ADDR:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDDR, EXT_RGMIIDCTL,
                      ST_VDLY_RD_DATA_MODE);
        ST_VDLY_RD_DATA_MODE:
          launch_mdio(1'b1, detected_phy_addr, REG_MMDCR, 16'h401F,
                      ST_VDLY_RD_VALUE);
        ST_VDLY_RD_VALUE:
          launch_mdio(1'b0, detected_phy_addr, REG_MMDDR, 16'd0,
                      ST_VDLY_CHECK);
        ST_VDLY_CHECK: begin
          if (last_mdio_read[7:0] == 8'h74)
            state <= ST_BMSR_FIRST_CMD;
          else begin
            init_error <= ERR_RGMIIDCTL;
            state      <= ST_ERROR;
          end
        end

        // BMSR link status is latched low, so read it twice and retain the
        // second sample.  Do not release the one-shot TX generator until the
        // link and auto-negotiation have both remained complete across the
        // stabilization interval.
        ST_BMSR_FIRST_CMD:
          launch_mdio(1'b0, detected_phy_addr, REG_BMSR, 16'd0,
                      ST_BMSR_SECOND_CMD);
        ST_BMSR_SECOND_CMD:
          launch_mdio(1'b0, detected_phy_addr, REG_BMSR, 16'd0,
                      ST_BMSR_CAPTURE);
        ST_BMSR_CAPTURE: begin
          phy_link_up          <= last_mdio_read[2];
          phy_autoneg_complete <= last_mdio_read[5];
          link_wait_counter    <= 32'd0;
          if (last_mdio_read[2] && last_mdio_read[5]) begin
            if (link_stable_pending) begin
              link_stable_pending <= 1'b0;
              state               <= ST_SUCCESS;
            end
            else begin
              link_stable_pending <= 1'b1;
              state               <= ST_LINK_STABLE_WAIT;
            end
          end
          else begin
            link_stable_pending <= 1'b0;
            state               <= ST_LINK_POLL_WAIT;
          end
        end

        ST_LINK_POLL_WAIT: begin
          if (link_wait_counter >= LINK_POLL_INTERVAL_CYCLES - 1) begin
            link_wait_counter <= 32'd0;
            state             <= ST_BMSR_FIRST_CMD;
          end
          else begin
            link_wait_counter <= link_wait_counter + 1'b1;
          end
        end

        ST_LINK_STABLE_WAIT: begin
          if (link_wait_counter >= LINK_STABLE_WAIT_CYCLES - 1) begin
            link_wait_counter <= 32'd0;
            state             <= ST_BMSR_FIRST_CMD;
          end
          else begin
            link_wait_counter <= link_wait_counter + 1'b1;
          end
        end

        ST_SUCCESS: begin
          init_done    <= 1'b1;
          init_success <= 1'b1;
          init_error   <= ERR_NONE;
          state        <= ST_HALT;
        end

        ST_ERROR: begin
          init_done    <= 1'b1;
          init_success <= 1'b0;
          state        <= ST_HALT;
        end

        ST_HALT: begin
          mdio_req_valid <= 1'b0;
        end

        ST_MDIO_LAUNCH: begin
          mdio_req_valid <= 1'b1;
          if (mdio_req_valid && mdio_req_ready) begin
            mdio_req_valid <= 1'b0;
            state          <= ST_MDIO_WAIT;
          end
        end

        ST_MDIO_WAIT: begin
          if (mdio_rsp_valid) begin
            if (mdio_rsp_error == 2'd0) begin
              last_mdio_read <= mdio_rsp_read_data;
              state          <= mdio_return_state;
            end
            else begin
              init_error <= (mdio_rsp_error == 2'd1) ?
                            ERR_AXI_RESPONSE : ERR_MDIO_TIMEOUT;
              state      <= ST_ERROR;
            end
          end
        end

        default: begin
          init_error <= ERR_AXI_RESPONSE;
          state      <= ST_ERROR;
        end
      endcase
    end
  end

endmodule


// Converts one Clause-22 request into TEMAC AXI4-Lite MDIO register accesses.
// TEMAC register map:
//   0x504 MDIO control, 0x508 write data, 0x50C read data/ready.
module temac_mdio_axi_master #(
  parameter integer POLL_LIMIT = 65535
) (
  input  wire        clk,
  input  wire        resetn,
  input  wire        req_valid,
  output wire        req_ready,
  input  wire        req_write,
  input  wire [4:0]  req_phy_addr,
  input  wire [4:0]  req_reg_addr,
  input  wire [15:0] req_write_data,
  output reg         rsp_valid,
  output reg  [15:0] rsp_read_data,
  output reg  [1:0]  rsp_error,

  output reg  [11:0] m_axi_awaddr,
  output reg         m_axi_awvalid,
  input  wire        m_axi_awready,
  output reg  [31:0] m_axi_wdata,
  output reg         m_axi_wvalid,
  input  wire        m_axi_wready,
  input  wire [1:0]  m_axi_bresp,
  input  wire        m_axi_bvalid,
  output reg         m_axi_bready,
  output reg  [11:0] m_axi_araddr,
  output reg         m_axi_arvalid,
  input  wire        m_axi_arready,
  input  wire [31:0] m_axi_rdata,
  input  wire [1:0]  m_axi_rresp,
  input  wire        m_axi_rvalid,
  output reg         m_axi_rready
);

  localparam [2:0]
    AXI_IDLE       = 3'd0,
    AXI_WRITE      = 3'd1,
    AXI_WRITE_RESP = 3'd2,
    AXI_READ_ADDR  = 3'd3,
    AXI_READ_DATA  = 3'd4;

  localparam AFTER_WRITE_DATA = 1'b0;
  localparam AFTER_CONTROL    = 1'b1;

  reg [2:0] state;
  reg       after_write;
  reg       request_write;
  reg [4:0] request_phy_addr;
  reg [4:0] request_reg_addr;
  reg [31:0] poll_count;
  reg        saw_mdio_busy;

  assign req_ready = (state == AXI_IDLE);

  function [31:0] mdio_control_word;
    input       write_access;
    input [4:0] phy_address;
    input [4:0] register_address;
    begin
      mdio_control_word = {3'd0, phy_address, 3'd0, register_address,
                           (write_access ? 2'b01 : 2'b10),
                           2'b00, 1'b1, 11'd0};
    end
  endfunction

  always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      state              <= AXI_IDLE;
      after_write        <= AFTER_CONTROL;
      request_write      <= 1'b0;
      request_phy_addr   <= 5'd0;
      request_reg_addr   <= 5'd0;
      poll_count         <= 32'd0;
      saw_mdio_busy      <= 1'b0;
      rsp_valid          <= 1'b0;
      rsp_read_data      <= 16'd0;
      rsp_error          <= 2'd0;
      m_axi_awaddr       <= 12'd0;
      m_axi_awvalid      <= 1'b0;
      m_axi_wdata        <= 32'd0;
      m_axi_wvalid       <= 1'b0;
      m_axi_bready       <= 1'b0;
      m_axi_araddr       <= 12'd0;
      m_axi_arvalid      <= 1'b0;
      m_axi_rready       <= 1'b0;
    end
    else begin
      rsp_valid <= 1'b0;

      case (state)
        AXI_IDLE: begin
          m_axi_awvalid <= 1'b0;
          m_axi_wvalid  <= 1'b0;
          m_axi_bready  <= 1'b0;
          m_axi_arvalid <= 1'b0;
          m_axi_rready  <= 1'b0;
          if (req_valid) begin
            request_write    <= req_write;
            request_phy_addr <= req_phy_addr;
            request_reg_addr <= req_reg_addr;
            poll_count       <= 32'd0;
            saw_mdio_busy    <= 1'b0;
            rsp_error        <= 2'd0;
            if (req_write) begin
              m_axi_awaddr  <= 12'h508;
              m_axi_wdata   <= {16'd0, req_write_data};
              after_write   <= AFTER_WRITE_DATA;
            end
            else begin
              m_axi_awaddr  <= 12'h504;
              m_axi_wdata   <= mdio_control_word(
                                  1'b0, req_phy_addr, req_reg_addr);
              after_write   <= AFTER_CONTROL;
            end
            m_axi_awvalid <= 1'b1;
            m_axi_wvalid  <= 1'b1;
            state         <= AXI_WRITE;
          end
        end

        AXI_WRITE: begin
          if (m_axi_awvalid && m_axi_awready)
            m_axi_awvalid <= 1'b0;
          if (m_axi_wvalid && m_axi_wready)
            m_axi_wvalid <= 1'b0;

          if ((!m_axi_awvalid || m_axi_awready) &&
              (!m_axi_wvalid  || m_axi_wready)) begin
            m_axi_bready <= 1'b1;
            state        <= AXI_WRITE_RESP;
          end
        end

        AXI_WRITE_RESP: begin
          if (m_axi_bvalid && m_axi_bready) begin
            m_axi_bready <= 1'b0;
            if (m_axi_bresp != 2'b00) begin
              rsp_error <= 2'd1;
              rsp_valid <= 1'b1;
              state     <= AXI_IDLE;
            end
            else if (after_write == AFTER_WRITE_DATA) begin
              m_axi_awaddr  <= 12'h504;
              m_axi_wdata   <= mdio_control_word(
                                  1'b1, request_phy_addr,
                                  request_reg_addr);
              m_axi_awvalid <= 1'b1;
              m_axi_wvalid  <= 1'b1;
              after_write   <= AFTER_CONTROL;
              state         <= AXI_WRITE;
            end
            else begin
              m_axi_araddr  <= 12'h50C;
              m_axi_arvalid <= 1'b1;
              state         <= AXI_READ_ADDR;
            end
          end
        end

        AXI_READ_ADDR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b1;
            state         <= AXI_READ_DATA;
          end
        end

        AXI_READ_DATA: begin
          if (m_axi_rvalid && m_axi_rready) begin
            m_axi_rready <= 1'b0;
            if (m_axi_rresp != 2'b00) begin
              rsp_error <= 2'd1;
              rsp_valid <= 1'b1;
              state     <= AXI_IDLE;
            end
            else if (!m_axi_rdata[16]) begin
              saw_mdio_busy <= 1'b1;
              if (poll_count >= POLL_LIMIT - 1) begin
                rsp_error <= 2'd2;
                rsp_valid <= 1'b1;
                state     <= AXI_IDLE;
              end
              else begin
                poll_count    <= poll_count + 1'b1;
                m_axi_araddr  <= 12'h50C;
                m_axi_arvalid <= 1'b1;
                state         <= AXI_READ_ADDR;
              end
            end
            else if (saw_mdio_busy) begin
              rsp_read_data <= m_axi_rdata[15:0];
              rsp_error     <= 2'd0;
              rsp_valid     <= 1'b1;
              state         <= AXI_IDLE;
            end
            else if (poll_count >= POLL_LIMIT - 1) begin
              // Requiring a low-to-high ready transition prevents accepting
              // stale read data from the preceding MDIO operation.
              rsp_error <= 2'd2;
              rsp_valid <= 1'b1;
              state     <= AXI_IDLE;
            end
            else begin
              poll_count    <= poll_count + 1'b1;
              m_axi_araddr  <= 12'h50C;
              m_axi_arvalid <= 1'b1;
              state         <= AXI_READ_ADDR;
            end
          end
        end

        default: begin
          rsp_error <= 2'd1;
          rsp_valid <= 1'b1;
          state     <= AXI_IDLE;
        end
      endcase
    end
  end

endmodule
