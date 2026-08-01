`timescale 1ns/1ps

module ddr_result_checker #(
  parameter logic [32:0] READ_ADDR      = 33'h0_0001_0000,
  parameter logic [31:0] EXPECTED_VALUE = 32'h0000_01bc
) (
  input  logic    clk,
  input  logic    resetn,
  input  logic    start,
  output logic    busy,
  output logic    done,
  output logic    pass,
  output logic    error,
  axi4_if.master  m_axi
);
  typedef enum logic [1:0] {IDLE, SEND_AR, WAIT_R, FINISHED} state_t;
  state_t state;

  always_comb begin
    m_axi.awid     = '0;
    m_axi.awaddr   = '0;
    m_axi.awlen    = '0;
    m_axi.awsize   = '0;
    m_axi.awburst  = 2'b01;
    m_axi.awlock   = 1'b0;
    m_axi.awcache  = 4'b0011;
    m_axi.awprot   = 3'b000;
    m_axi.awregion = 4'b0000;
    m_axi.awqos    = 4'b0000;
    m_axi.awvalid  = 1'b0;
    m_axi.wdata    = '0;
    m_axi.wstrb    = '0;
    m_axi.wlast    = 1'b1;
    m_axi.wvalid   = 1'b0;
    m_axi.bready   = 1'b1;

    m_axi.arid     = 4'hf;
    m_axi.araddr   = READ_ADDR;
    m_axi.arlen    = 8'd0;
    m_axi.arsize   = 3'd6; // one complete 512-bit beat
    m_axi.arburst  = 2'b01;
    m_axi.arlock   = 1'b0;
    m_axi.arcache  = 4'b0011;
    m_axi.arprot   = 3'b000;
    m_axi.arregion = 4'b0000;
    m_axi.arqos    = 4'b0000;
    m_axi.arvalid  = (state == SEND_AR);
    m_axi.rready   = (state == WAIT_R);

    busy = (state == SEND_AR) || (state == WAIT_R);
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state <= IDLE;
      done  <= 1'b0;
      pass  <= 1'b0;
      error <= 1'b0;
    end else begin
      case (state)
        IDLE: begin
          if (start)
            state <= SEND_AR;
        end
        SEND_AR: begin
          if (m_axi.arvalid && m_axi.arready)
            state <= WAIT_R;
        end
        WAIT_R: begin
          if (m_axi.rvalid && m_axi.rready) begin
            done  <= 1'b1;
            pass  <= (m_axi.rresp == 2'b00) && m_axi.rlast &&
                     (m_axi.rdata[127:96] == EXPECTED_VALUE);
            error <= (m_axi.rresp != 2'b00) || !m_axi.rlast ||
                     (m_axi.rdata[127:96] != EXPECTED_VALUE);
            state <= FINISHED;
          end
        end
        default: state <= FINISHED;
      endcase
    end
  end
endmodule


// One-shot readback checker for the two ATG initialization images.  It sits
// directly on the 512-bit MIG UI AXI port after the write-only ATG has
// completed.  PROGRAM_IMAGE selects the patched EH2 program in DDR4-1;
// otherwise the four-word input-data block in DDR4-2 is checked.
module ddr_init_readback_checker #(
  parameter bit PROGRAM_IMAGE = 1'b0
) (
  input  logic    clk,
  input  logic    resetn,
  input  logic    start,
  output logic    busy,
  output logic    done,
  output logic    pass,
  output logic    error,
  axi4_if.master  m_axi
);
  typedef enum logic [1:0] {IDLE, SEND_AR, WAIT_R, FINISHED} state_t;
  state_t state;
  logic read_index;

  wire [32:0] read_addr = PROGRAM_IMAGE
    ? (read_index ? 33'h0_0000_0040 : 33'h0_0000_0000)
    : 33'h0_0001_0000;

  logic payload_matches;
  always_comb begin
    if (PROGRAM_IMAGE) begin
      if (!read_index) begin
        // Addresses 0x00..0x3c.  The two external-DDR-incompatible AMOs at
        // 0x38/0x3c are the already-approved ordinary load/add replacement.
        payload_matches = (m_axi.rdata == {
          32'h00b8_08b3, 32'h0007_a803, 32'hfd87_8793, 32'h0001_0797,
          32'h0283_6733, 32'h0283_46b3, 32'h0283_1633, 32'h0283_05b3,
          32'h4083_0533, 32'h00f3_0493, 32'h0003_a403, 32'hff83_8393,
          32'h0001_0397, 32'h0002_a303, 32'h0002_8293, 32'h0001_0297
        });
      end else begin
        // Addresses 0x40..0x58.  Higher lanes in this beat were not written
        // by the ATG and are intentionally excluded from the comparison.
        payload_matches = (m_axi.rdata[223:0] == {
          32'h00a9_a023, 32'hfbc9_8993, 32'h0001_0997, 32'h8d01_050a,
          32'h952e_4531, 32'h00d7_a023, 32'h0117_a023
        });
      end
    end else begin
      // DDR4-2 input block at 0x10000: 25, 4, 100 and 0.
      payload_matches = (m_axi.rdata[127:0] == {
        32'h0000_0000, 32'h0000_0064, 32'h0000_0004, 32'h0000_0019
      });
    end
  end

  always_comb begin
    m_axi.awid     = '0;
    m_axi.awaddr   = '0;
    m_axi.awlen    = '0;
    m_axi.awsize   = '0;
    m_axi.awburst  = 2'b01;
    m_axi.awlock   = 1'b0;
    m_axi.awcache  = 4'b0011;
    m_axi.awprot   = 3'b000;
    m_axi.awregion = 4'b0000;
    m_axi.awqos    = 4'b0000;
    m_axi.awvalid  = 1'b0;
    m_axi.wdata    = '0;
    m_axi.wstrb    = '0;
    m_axi.wlast    = 1'b1;
    m_axi.wvalid   = 1'b0;
    m_axi.bready   = 1'b1;

    m_axi.arid     = 4'he;
    m_axi.araddr   = read_addr;
    m_axi.arlen    = 8'd0;
    m_axi.arsize   = 3'd6;
    m_axi.arburst  = 2'b01;
    m_axi.arlock   = 1'b0;
    m_axi.arcache  = 4'b0011;
    m_axi.arprot   = 3'b000;
    m_axi.arregion = 4'b0000;
    m_axi.arqos    = 4'b0000;
    m_axi.arvalid  = (state == SEND_AR);
    m_axi.rready   = (state == WAIT_R);

    busy = (state == SEND_AR) || (state == WAIT_R);
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state      <= IDLE;
      read_index <= 1'b0;
      done       <= 1'b0;
      pass       <= 1'b0;
      error      <= 1'b0;
    end else begin
      case (state)
        IDLE: begin
          if (start)
            state <= SEND_AR;
        end
        SEND_AR: begin
          if (m_axi.arvalid && m_axi.arready)
            state <= WAIT_R;
        end
        WAIT_R: begin
          if (m_axi.rvalid && m_axi.rready) begin
            if ((m_axi.rresp != 2'b00) || !m_axi.rlast ||
                (m_axi.rid != 4'he) || !payload_matches) begin
              done  <= 1'b1;
              pass  <= 1'b0;
              error <= 1'b1;
              state <= FINISHED;
            end else if (PROGRAM_IMAGE && !read_index) begin
              read_index <= 1'b1;
              state      <= SEND_AR;
            end else begin
              done  <= 1'b1;
              pass  <= 1'b1;
              error <= 1'b0;
              state <= FINISHED;
            end
          end
        end
        default: state <= FINISHED;
      endcase
    end
  end
endmodule
