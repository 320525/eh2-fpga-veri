`timescale 1ns/1ps

// Phase-based two-master mux. select_b may change only after master A's final
// response has completed. The system controller makes that change sticky, so
// there is no transaction interleaving and no route back to the initializer.
module axi_owner_mux2 (
  input  logic         select_b,
  axi4_if.slave        master_a,
  axi4_if.slave        master_b,
  axi4_if.master       slave_out
);
  always_comb begin
    slave_out.awid     = select_b ? master_b.awid     : master_a.awid;
    slave_out.awaddr   = select_b ? master_b.awaddr   : master_a.awaddr;
    slave_out.awlen    = select_b ? master_b.awlen    : master_a.awlen;
    slave_out.awsize   = select_b ? master_b.awsize   : master_a.awsize;
    slave_out.awburst  = select_b ? master_b.awburst  : master_a.awburst;
    slave_out.awlock   = select_b ? master_b.awlock   : master_a.awlock;
    slave_out.awcache  = select_b ? master_b.awcache  : master_a.awcache;
    slave_out.awprot   = select_b ? master_b.awprot   : master_a.awprot;
    slave_out.awregion = select_b ? master_b.awregion : master_a.awregion;
    slave_out.awqos    = select_b ? master_b.awqos    : master_a.awqos;
    slave_out.awvalid  = select_b ? master_b.awvalid  : master_a.awvalid;

    slave_out.wdata    = select_b ? master_b.wdata    : master_a.wdata;
    slave_out.wstrb    = select_b ? master_b.wstrb    : master_a.wstrb;
    slave_out.wlast    = select_b ? master_b.wlast    : master_a.wlast;
    slave_out.wvalid   = select_b ? master_b.wvalid   : master_a.wvalid;
    slave_out.bready   = select_b ? master_b.bready   : master_a.bready;

    slave_out.arid     = select_b ? master_b.arid     : master_a.arid;
    slave_out.araddr   = select_b ? master_b.araddr   : master_a.araddr;
    slave_out.arlen    = select_b ? master_b.arlen    : master_a.arlen;
    slave_out.arsize   = select_b ? master_b.arsize   : master_a.arsize;
    slave_out.arburst  = select_b ? master_b.arburst  : master_a.arburst;
    slave_out.arlock   = select_b ? master_b.arlock   : master_a.arlock;
    slave_out.arcache  = select_b ? master_b.arcache  : master_a.arcache;
    slave_out.arprot   = select_b ? master_b.arprot   : master_a.arprot;
    slave_out.arregion = select_b ? master_b.arregion : master_a.arregion;
    slave_out.arqos    = select_b ? master_b.arqos    : master_a.arqos;
    slave_out.arvalid  = select_b ? master_b.arvalid  : master_a.arvalid;
    slave_out.rready   = select_b ? master_b.rready   : master_a.rready;

    master_a.awready = select_b ? 1'b0 : slave_out.awready;
    master_a.wready  = select_b ? 1'b0 : slave_out.wready;
    master_a.bid     = slave_out.bid;
    master_a.bresp   = slave_out.bresp;
    master_a.bvalid  = select_b ? 1'b0 : slave_out.bvalid;
    master_a.arready = select_b ? 1'b0 : slave_out.arready;
    master_a.rid     = slave_out.rid;
    master_a.rdata   = slave_out.rdata;
    master_a.rresp   = slave_out.rresp;
    master_a.rlast   = slave_out.rlast;
    master_a.rvalid  = select_b ? 1'b0 : slave_out.rvalid;

    master_b.awready = select_b ? slave_out.awready : 1'b0;
    master_b.wready  = select_b ? slave_out.wready  : 1'b0;
    master_b.bid     = slave_out.bid;
    master_b.bresp   = slave_out.bresp;
    master_b.bvalid  = select_b ? slave_out.bvalid : 1'b0;
    master_b.arready = select_b ? slave_out.arready : 1'b0;
    master_b.rid     = slave_out.rid;
    master_b.rdata   = slave_out.rdata;
    master_b.rresp   = slave_out.rresp;
    master_b.rlast   = slave_out.rlast;
    master_b.rvalid  = select_b ? slave_out.rvalid : 1'b0;
  end
endmodule

