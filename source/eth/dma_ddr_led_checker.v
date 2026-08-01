`timescale 1ps / 1ps

// Minimal receive-path indication logic.
//
// LED-T1 latches on after a frame destination matches 02:12:34:56:78:FF.
// LED-T2 reports whether the first complete 32-bit DMA write beat observed
// since reset is 32'hFFFF_FFFF.
// After the first successful MIG write response, one 512-bit AXI read is
// issued at byte address zero; LED-T3 reports the low 32-bit comparison.
// LED-T4 reports that PHY initialization and DDR4 calibration are complete.
module dma_ddr_led_checker (
  input  wire         dma_clk,
  input  wire         dma_resetn,
  input  wire         rx_frame_accepted,
  input  wire [31:0]  dma_wdata,
  input  wire [3:0]   dma_wstrb,
  input  wire         dma_wvalid,
  input  wire         dma_wready,

  input  wire         mig_clk,
  input  wire         mig_resetn,
  input  wire [1:0]   mig_bresp,
  input  wire         mig_bvalid,
  input  wire         mig_bready,

  output wire [3:0]   mig_arid,
  output wire [32:0]  mig_araddr,
  output wire [7:0]   mig_arlen,
  output wire [2:0]   mig_arsize,
  output wire [1:0]   mig_arburst,
  output wire         mig_arlock,
  output wire [3:0]   mig_arcache,
  output wire [2:0]   mig_arprot,
  output wire [3:0]   mig_arqos,
  output wire         mig_arvalid,
  input  wire         mig_arready,

  output wire         mig_rready,
  input  wire [3:0]   mig_rid,
  input  wire [511:0] mig_rdata,
  input  wire [1:0]   mig_rresp,
  input  wire         mig_rlast,
  input  wire         mig_rvalid,

  output wire [3:0]   led_t,
  output reg          ddr_read_done,
  output reg          ddr_read_error
);

  reg rx_frame_accepted_seen;
  reg dma_word_seen;
  reg dma_all_ffff;

  always @(posedge dma_clk) begin
    if (!dma_resetn) begin
      rx_frame_accepted_seen <= 1'b0;
      dma_word_seen <= 1'b0;
      dma_all_ffff  <= 1'b0;
    end
    else begin
      if (rx_frame_accepted)
        rx_frame_accepted_seen <= 1'b1;

      if (dma_wvalid && dma_wready && (dma_wstrb == 4'hF)) begin
        dma_word_seen <= 1'b1;
        if (!dma_word_seen)
          dma_all_ffff <= (dma_wdata == 32'hFFFF_FFFF);
      end
    end
  end

  localparam [1:0] WAIT_WRITE = 2'd0;
  localparam [1:0] SEND_AR    = 2'd1;
  localparam [1:0] WAIT_R     = 2'd2;
  localparam [1:0] DONE       = 2'd3;

  reg [1:0] read_state;
  reg       ddr_first_word_ffff;

  assign mig_arid    = 4'd0;
  assign mig_araddr  = 33'd0;
  assign mig_arlen   = 8'd0;
  assign mig_arsize  = 3'd6;
  assign mig_arburst = 2'b01;
  assign mig_arlock  = 1'b0;
  assign mig_arcache = 4'b0011;
  assign mig_arprot  = 3'b000;
  assign mig_arqos   = 4'b0000;
  assign mig_arvalid = (read_state == SEND_AR);
  assign mig_rready  = (read_state == WAIT_R);

  always @(posedge mig_clk) begin
    if (!mig_resetn) begin
      read_state          <= WAIT_WRITE;
      ddr_first_word_ffff <= 1'b0;
      ddr_read_done       <= 1'b0;
      ddr_read_error      <= 1'b0;
    end
    else begin
      case (read_state)
        WAIT_WRITE: begin
          if (mig_bvalid && mig_bready) begin
            if (mig_bresp == 2'b00)
              read_state <= SEND_AR;
            else begin
              ddr_read_error <= 1'b1;
              read_state     <= DONE;
            end
          end
        end

        SEND_AR: begin
          if (mig_arready)
            read_state <= WAIT_R;
        end

        WAIT_R: begin
          if (mig_rvalid) begin
            ddr_first_word_ffff <=
              (mig_rid == 4'd0) && (mig_rresp == 2'b00) && mig_rlast &&
              (mig_rdata[31:0] == 32'hFFFF_FFFF);
            ddr_read_error <=
              (mig_rid != 4'd0) || (mig_rresp != 2'b00) || !mig_rlast;
            ddr_read_done <= 1'b1;
            read_state    <= DONE;
          end
        end

        default: read_state <= DONE;
      endcase
    end
  end

  // The four LEDs on this board are active high.
  assign led_t[0] = rx_frame_accepted_seen;        // LED-T1
  assign led_t[1] = dma_word_seen && dma_all_ffff; // LED-T2
  assign led_t[2] = ddr_read_done &&
                    ddr_first_word_ffff && !ddr_read_error; // LED-T3
  assign led_t[3] = dma_resetn;                    // LED-T4

endmodule
