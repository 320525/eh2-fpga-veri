`timescale 1ns/1ps

// Single-port AXI4 functional memory used only by the behavioral pre-sim.
// It accepts one read and one write transaction at a time, supports INCR
// bursts and byte strobes, and intentionally applies backpressure so that the
// CDC and data-width-converter IPs are exercised rather than bypassed.
module axi_ram_model_512 #(
  parameter integer MEM_BYTES = 131072
) (
  input  logic         clk,
  input  logic         resetn,
  input  logic [3:0]   s_axi_awid,
  input  logic [32:0]  s_axi_awaddr,
  input  logic [7:0]   s_axi_awlen,
  input  logic [2:0]   s_axi_awsize,
  input  logic [1:0]   s_axi_awburst,
  input  logic         s_axi_awvalid,
  output logic         s_axi_awready,
  input  logic [511:0] s_axi_wdata,
  input  logic [63:0]  s_axi_wstrb,
  input  logic         s_axi_wlast,
  input  logic         s_axi_wvalid,
  output logic         s_axi_wready,
  output logic [3:0]   s_axi_bid,
  output logic [1:0]   s_axi_bresp,
  output logic         s_axi_bvalid,
  input  logic         s_axi_bready,
  input  logic [3:0]   s_axi_arid,
  input  logic [32:0]  s_axi_araddr,
  input  logic [7:0]   s_axi_arlen,
  input  logic [2:0]   s_axi_arsize,
  input  logic [1:0]   s_axi_arburst,
  input  logic         s_axi_arvalid,
  output logic         s_axi_arready,
  output logic [3:0]   s_axi_rid,
  output logic [511:0] s_axi_rdata,
  output logic [1:0]   s_axi_rresp,
  output logic         s_axi_rlast,
  output logic         s_axi_rvalid,
  input  logic         s_axi_rready
);
  localparam integer BEATS = MEM_BYTES / 64;
  logic [511:0] mem [0:BEATS-1];

  logic        wr_active;
  logic [32:0] wr_addr;
  logic [7:0]  wr_beats_left;
  logic [2:0]  wr_size;
  logic [1:0]  wr_burst;
  logic [3:0]  wr_id;

  logic        rd_active;
  logic [32:0] rd_addr;
  logic [7:0]  rd_beats_left;
  logic [2:0]  rd_size;
  logic [1:0]  rd_burst;
  logic [3:0]  rd_id;

  integer init_i;
  integer wr_i;
  integer wr_word_index;
  integer rd_word_index;
  initial begin
    for (init_i = 0; init_i < BEATS; init_i = init_i + 1)
      mem[init_i] = '0;
  end

  always_comb begin
    s_axi_awready = resetn && !wr_active && !s_axi_bvalid;
    s_axi_wready  = resetn && wr_active && !s_axi_bvalid;
    s_axi_arready = resetn && !rd_active && !s_axi_rvalid;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      wr_active     <= 1'b0;
      wr_addr       <= '0;
      wr_beats_left <= '0;
      wr_size       <= '0;
      wr_burst      <= '0;
      wr_id         <= '0;
      s_axi_bid     <= '0;
      s_axi_bresp   <= 2'b00;
      s_axi_bvalid  <= 1'b0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        wr_active     <= 1'b1;
        wr_addr       <= s_axi_awaddr;
        wr_beats_left <= s_axi_awlen;
        wr_size       <= s_axi_awsize;
        wr_burst      <= s_axi_awburst;
        wr_id         <= s_axi_awid;
      end

      if (s_axi_wvalid && s_axi_wready) begin
        wr_word_index = wr_addr[32:6];
        if (wr_word_index >= 0 && wr_word_index < BEATS) begin
          for (wr_i = 0; wr_i < 64; wr_i = wr_i + 1)
            if (s_axi_wstrb[wr_i])
              mem[wr_word_index][wr_i*8 +: 8] <= s_axi_wdata[wr_i*8 +: 8];
        end
        if (s_axi_wlast || (wr_beats_left == 0)) begin
          wr_active    <= 1'b0;
          s_axi_bid    <= wr_id;
          s_axi_bresp  <= (wr_word_index >= 0 && wr_word_index < BEATS) ? 2'b00 : 2'b10;
          s_axi_bvalid <= 1'b1;
        end else begin
          wr_beats_left <= wr_beats_left - 1'b1;
          if (wr_burst == 2'b01)
            wr_addr <= wr_addr + (33'd1 << wr_size);
        end
      end

      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      rd_active     <= 1'b0;
      rd_addr       <= '0;
      rd_beats_left <= '0;
      rd_size       <= '0;
      rd_burst      <= '0;
      rd_id         <= '0;
      s_axi_rid     <= '0;
      s_axi_rdata   <= '0;
      s_axi_rresp   <= 2'b00;
      s_axi_rlast   <= 1'b0;
      s_axi_rvalid  <= 1'b0;
    end else begin
      if (s_axi_arvalid && s_axi_arready) begin
        rd_active     <= 1'b1;
        rd_addr       <= s_axi_araddr;
        rd_beats_left <= s_axi_arlen;
        rd_size       <= s_axi_arsize;
        rd_burst      <= s_axi_arburst;
        rd_id         <= s_axi_arid;
      end

      if (rd_active && !s_axi_rvalid) begin
        rd_word_index = rd_addr[32:6];
        s_axi_rid    <= rd_id;
        s_axi_rdata  <= (rd_word_index >= 0 && rd_word_index < BEATS) ? mem[rd_word_index] : '0;
        s_axi_rresp  <= (rd_word_index >= 0 && rd_word_index < BEATS) ? 2'b00 : 2'b10;
        s_axi_rlast  <= (rd_beats_left == 0);
        s_axi_rvalid <= 1'b1;
      end

      if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
        if (s_axi_rlast) begin
          rd_active <= 1'b0;
        end else begin
          rd_beats_left <= rd_beats_left - 1'b1;
          if (rd_burst == 2'b01)
            rd_addr <= rd_addr + (33'd1 << rd_size);
        end
      end
    end
  end
endmodule
