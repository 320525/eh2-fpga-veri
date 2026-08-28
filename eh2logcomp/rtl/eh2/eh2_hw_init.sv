`timescale 1ns/1ps

// Synthesizable replacement for the Cores-VeeR-EH2 testbench's
// init_dccm()/init_iccm() tasks. The core is configured to halt on reset;
// while it is in debug halt this master clears both 64 KiB tightly-coupled
// memories through the EH2 DMA slave port. Writes use the normal EH2 memory
// path, so the core generates the required SECDED ECC bits itself.
module eh2_hw_init #(
  parameter logic [31:0] DCCM_FIRST = 32'hf004_0000,
  parameter logic [31:0] DCCM_LAST  = 32'hf004_fff8,
  parameter logic [31:0] ICCM_FIRST = 32'hee00_0000,
  parameter logic [31:0] ICCM_LAST  = 32'hee00_fff8
) (
  input  logic        clk,
  input  logic        resetn,
  input  logic        debug_halted,
  input  logic        run_ack,
  output logic        run_req,
  output logic        init_busy,
  output logic        init_done,
  output logic        init_error,

  output logic        dma_awvalid,
  input  logic        dma_awready,
  output logic [0:0]  dma_awid,
  output logic [31:0] dma_awaddr,
  output logic [2:0]  dma_awsize,
  output logic [2:0]  dma_awprot,
  output logic [7:0]  dma_awlen,
  output logic [1:0]  dma_awburst,
  output logic        dma_wvalid,
  input  logic        dma_wready,
  output logic [63:0] dma_wdata,
  output logic [7:0]  dma_wstrb,
  output logic        dma_wlast,
  input  logic        dma_bvalid,
  output logic        dma_bready,
  input  logic [1:0]  dma_bresp,
  input  logic [0:0]  dma_bid
);
  typedef enum logic [2:0] {
    WAIT_HALT, SEND_WRITE, WAIT_B, RESUME_CORE, COMPLETE, FAILED
  } state_t;
  state_t state;

  logic [31:0] address;
  logic        clearing_iccm;
  logic        aw_sent;
  logic        w_sent;

  always_comb begin
    dma_awvalid = (state == SEND_WRITE) && !aw_sent;
    dma_awid    = 1'b0;
    dma_awaddr  = address;
    dma_awsize  = 3'd3;
    dma_awprot  = 3'b000;
    dma_awlen   = 8'd0;
    dma_awburst = 2'b01;
    dma_wvalid  = (state == SEND_WRITE) && !w_sent;
    dma_wdata   = 64'd0;
    dma_wstrb   = 8'hff;
    dma_wlast   = 1'b1;
    dma_bready  = (state == WAIT_B);
    run_req     = (state == RESUME_CORE);
    init_busy   = (state != WAIT_HALT) && (state != COMPLETE) &&
                  (state != FAILED);
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state         <= WAIT_HALT;
      address       <= DCCM_FIRST;
      clearing_iccm <= 1'b0;
      aw_sent       <= 1'b0;
      w_sent        <= 1'b0;
      init_done     <= 1'b0;
      init_error    <= 1'b0;
    end else begin
      case (state)
        WAIT_HALT: begin
          if (debug_halted) begin
            address       <= DCCM_FIRST;
            clearing_iccm <= 1'b0;
            aw_sent       <= 1'b0;
            w_sent        <= 1'b0;
            state         <= SEND_WRITE;
          end
        end

        SEND_WRITE: begin
          if (dma_awvalid && dma_awready)
            aw_sent <= 1'b1;
          if (dma_wvalid && dma_wready)
            w_sent <= 1'b1;
          if ((aw_sent || (dma_awvalid && dma_awready)) &&
              (w_sent  || (dma_wvalid  && dma_wready)))
            state <= WAIT_B;
        end

        WAIT_B: begin
          if (dma_bvalid && dma_bready) begin
            if ((dma_bresp != 2'b00) || (dma_bid != 1'b0)) begin
              init_error <= 1'b1;
              state      <= FAILED;
            end else if (!clearing_iccm && (address == DCCM_LAST)) begin
              clearing_iccm <= 1'b1;
              address       <= ICCM_FIRST;
              aw_sent       <= 1'b0;
              w_sent        <= 1'b0;
              state         <= SEND_WRITE;
            end else if (clearing_iccm && (address == ICCM_LAST)) begin
              state <= RESUME_CORE;
            end else begin
              address <= address + 32'd8;
              aw_sent <= 1'b0;
              w_sent  <= 1'b0;
              state   <= SEND_WRITE;
            end
          end
        end

        RESUME_CORE: begin
          if (run_ack) begin
            init_done <= 1'b1;
            state     <= COMPLETE;
          end
        end

        COMPLETE: state <= COMPLETE;
        default:  state <= FAILED;
      endcase
    end
  end
endmodule
