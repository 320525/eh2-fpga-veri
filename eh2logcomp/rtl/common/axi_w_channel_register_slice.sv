// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// One-deep elastic register for the AXI write-data channel.  The remaining
// four AXI channels are transparent.  AXI permits AW and W to advance
// independently, so registering WDATA/WSTRB/WLAST/WVALID here preserves the
// protocol while removing a long phase-mux-to-MIG combinational path.
//
// The ready equation permits simultaneous dequeue/enqueue.  Consequently the
// slice sustains one 512-bit beat per clock once a burst is in progress.
module axi_w_channel_register_slice (
    input  logic  clk,
    input  logic  resetn,
    axi4_if.slave  source,
    axi4_if.master sink
);
    logic         w_valid_reg;
    logic [511:0] w_data_reg;
    logic [63:0]  w_strb_reg;
    logic         w_last_reg;
    logic         take_source;

    assign take_source = !w_valid_reg || sink.wready;

    always_ff @(posedge clk or negedge resetn) begin
      if (!resetn) begin
        w_valid_reg <= 1'b0;
        w_data_reg  <= '0;
        w_strb_reg  <= '0;
        w_last_reg  <= 1'b0;
      end else if (take_source) begin
        w_valid_reg <= source.wvalid;
        if (source.wvalid) begin
          w_data_reg <= source.wdata;
          w_strb_reg <= source.wstrb;
          w_last_reg <= source.wlast;
        end
      end
    end

    always_comb begin
      sink.awid     = source.awid;
      sink.awaddr   = source.awaddr;
      sink.awlen    = source.awlen;
      sink.awsize   = source.awsize;
      sink.awburst  = source.awburst;
      sink.awlock   = source.awlock;
      sink.awcache  = source.awcache;
      sink.awprot   = source.awprot;
      sink.awregion = source.awregion;
      sink.awqos    = source.awqos;
      sink.awvalid  = source.awvalid;
      source.awready = sink.awready;

      sink.wdata    = w_data_reg;
      sink.wstrb    = w_strb_reg;
      sink.wlast    = w_last_reg;
      sink.wvalid   = w_valid_reg;
      source.wready = resetn && take_source;

      source.bid    = sink.bid;
      source.bresp  = sink.bresp;
      source.bvalid = sink.bvalid;
      sink.bready   = source.bready;

      sink.arid     = source.arid;
      sink.araddr   = source.araddr;
      sink.arlen    = source.arlen;
      sink.arsize   = source.arsize;
      sink.arburst  = source.arburst;
      sink.arlock   = source.arlock;
      sink.arcache  = source.arcache;
      sink.arprot   = source.arprot;
      sink.arregion = source.arregion;
      sink.arqos    = source.arqos;
      sink.arvalid  = source.arvalid;
      source.arready = sink.arready;

      source.rid    = sink.rid;
      source.rdata  = sink.rdata;
      source.rresp  = sink.rresp;
      source.rlast  = sink.rlast;
      source.rvalid = sink.rvalid;
      sink.rready   = source.rready;
    end
endmodule
