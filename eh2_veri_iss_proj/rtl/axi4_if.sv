`timescale 1ns/1ps

interface axi4_if #(
  parameter integer ADDR_WIDTH = 33,
  parameter integer DATA_WIDTH = 512,
  parameter integer ID_WIDTH   = 4
);
  logic [ID_WIDTH-1:0]   awid;
  logic [ADDR_WIDTH-1:0] awaddr;
  logic [7:0]            awlen;
  logic [2:0]            awsize;
  logic [1:0]            awburst;
  logic                  awlock;
  logic [3:0]            awcache;
  logic [2:0]            awprot;
  logic [3:0]            awregion;
  logic [3:0]            awqos;
  logic                  awvalid;
  logic                  awready;

  logic [DATA_WIDTH-1:0]   wdata;
  logic [DATA_WIDTH/8-1:0] wstrb;
  logic                    wlast;
  logic                    wvalid;
  logic                    wready;

  logic [ID_WIDTH-1:0] bid;
  logic [1:0]          bresp;
  logic                bvalid;
  logic                bready;

  logic [ID_WIDTH-1:0]   arid;
  logic [ADDR_WIDTH-1:0] araddr;
  logic [7:0]            arlen;
  logic [2:0]            arsize;
  logic [1:0]            arburst;
  logic                  arlock;
  logic [3:0]            arcache;
  logic [2:0]            arprot;
  logic [3:0]            arregion;
  logic [3:0]            arqos;
  logic                  arvalid;
  logic                  arready;

  logic [ID_WIDTH-1:0] rid;
  logic [DATA_WIDTH-1:0] rdata;
  logic [1:0]            rresp;
  logic                  rlast;
  logic                  rvalid;
  logic                  rready;

  modport master (
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot,
           awregion, awqos, awvalid, wdata, wstrb, wlast, wvalid, bready,
           arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot,
           arregion, arqos, arvalid, rready,
    input  awready, wready, bid, bresp, bvalid, arready, rid, rdata, rresp,
           rlast, rvalid
  );

  modport slave (
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot,
           awregion, awqos, awvalid, wdata, wstrb, wlast, wvalid, bready,
           arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot,
           arregion, arqos, arvalid, rready,
    output awready, wready, bid, bresp, bvalid, arready, rid, rdata, rresp,
           rlast, rvalid
  );
endinterface

