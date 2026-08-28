// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Two AXI4 masters share one MIG slave.  Read and write paths arbitrate
// independently, but an owner is held for an entire burst/response so IDs and
// data can never be routed to the other processor port.
module axi_burst_arbiter_2x1 (
    input logic clk,
    input logic resetn,
    axi4_if.slave master_a,
    axi4_if.slave master_b,
    axi4_if.master slave_out
);
    typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
    typedef enum logic       {R_IDLE, R_DATA} rstate_t;
    wstate_t wstate;
    rstate_t rstate;
    logic write_owner, read_owner;
    logic write_prefer_b, read_prefer_b;
    logic write_select, read_select;

    always_comb begin
      if (master_a.awvalid && master_b.awvalid)
        write_select = write_prefer_b;
      else
        write_select = master_b.awvalid;
      if (master_a.arvalid && master_b.arvalid)
        read_select = read_prefer_b;
      else
        read_select = master_b.arvalid;
    end

    always_comb begin
      slave_out.awid = '0; slave_out.awaddr = '0; slave_out.awlen = '0;
      slave_out.awsize = '0; slave_out.awburst = '0; slave_out.awlock = 1'b0;
      slave_out.awcache = '0; slave_out.awprot = '0; slave_out.awregion = '0;
      slave_out.awqos = '0; slave_out.awvalid = 1'b0;
      slave_out.wdata = '0; slave_out.wstrb = '0; slave_out.wlast = 1'b0;
      slave_out.wvalid = 1'b0; slave_out.bready = 1'b0;
      slave_out.arid = '0; slave_out.araddr = '0; slave_out.arlen = '0;
      slave_out.arsize = '0; slave_out.arburst = '0; slave_out.arlock = 1'b0;
      slave_out.arcache = '0; slave_out.arprot = '0; slave_out.arregion = '0;
      slave_out.arqos = '0; slave_out.arvalid = 1'b0;
      slave_out.rready = 1'b0;

      master_a.awready = 1'b0; master_a.wready = 1'b0;
      master_a.bid = slave_out.bid; master_a.bresp = slave_out.bresp;
      master_a.bvalid = 1'b0; master_a.arready = 1'b0;
      master_a.rid = slave_out.rid; master_a.rdata = slave_out.rdata;
      master_a.rresp = slave_out.rresp; master_a.rlast = slave_out.rlast;
      master_a.rvalid = 1'b0;
      master_b.awready = 1'b0; master_b.wready = 1'b0;
      master_b.bid = slave_out.bid; master_b.bresp = slave_out.bresp;
      master_b.bvalid = 1'b0; master_b.arready = 1'b0;
      master_b.rid = slave_out.rid; master_b.rdata = slave_out.rdata;
      master_b.rresp = slave_out.rresp; master_b.rlast = slave_out.rlast;
      master_b.rvalid = 1'b0;

      if (wstate == W_IDLE) begin
        if (write_select) begin
          slave_out.awid = master_b.awid;
          slave_out.awaddr = master_b.awaddr;
          slave_out.awlen = master_b.awlen;
          slave_out.awsize = master_b.awsize;
          slave_out.awburst = master_b.awburst;
          slave_out.awlock = master_b.awlock;
          slave_out.awcache = master_b.awcache;
          slave_out.awprot = master_b.awprot;
          slave_out.awregion = master_b.awregion;
          slave_out.awqos = master_b.awqos;
          slave_out.awvalid = master_b.awvalid;
          master_b.awready = slave_out.awready;
        end else begin
          slave_out.awid = master_a.awid;
          slave_out.awaddr = master_a.awaddr;
          slave_out.awlen = master_a.awlen;
          slave_out.awsize = master_a.awsize;
          slave_out.awburst = master_a.awburst;
          slave_out.awlock = master_a.awlock;
          slave_out.awcache = master_a.awcache;
          slave_out.awprot = master_a.awprot;
          slave_out.awregion = master_a.awregion;
          slave_out.awqos = master_a.awqos;
          slave_out.awvalid = master_a.awvalid;
          master_a.awready = slave_out.awready;
        end
      end else if (wstate == W_DATA) begin
        if (write_owner) begin
          slave_out.wdata = master_b.wdata;
          slave_out.wstrb = master_b.wstrb;
          slave_out.wlast = master_b.wlast;
          slave_out.wvalid = master_b.wvalid;
          master_b.wready = slave_out.wready;
        end else begin
          slave_out.wdata = master_a.wdata;
          slave_out.wstrb = master_a.wstrb;
          slave_out.wlast = master_a.wlast;
          slave_out.wvalid = master_a.wvalid;
          master_a.wready = slave_out.wready;
        end
      end else begin
        if (write_owner) begin
          master_b.bvalid = slave_out.bvalid;
          slave_out.bready = master_b.bready;
        end else begin
          master_a.bvalid = slave_out.bvalid;
          slave_out.bready = master_a.bready;
        end
      end

      if (rstate == R_IDLE) begin
        if (read_select) begin
          slave_out.arid = master_b.arid;
          slave_out.araddr = master_b.araddr;
          slave_out.arlen = master_b.arlen;
          slave_out.arsize = master_b.arsize;
          slave_out.arburst = master_b.arburst;
          slave_out.arlock = master_b.arlock;
          slave_out.arcache = master_b.arcache;
          slave_out.arprot = master_b.arprot;
          slave_out.arregion = master_b.arregion;
          slave_out.arqos = master_b.arqos;
          slave_out.arvalid = master_b.arvalid;
          master_b.arready = slave_out.arready;
        end else begin
          slave_out.arid = master_a.arid;
          slave_out.araddr = master_a.araddr;
          slave_out.arlen = master_a.arlen;
          slave_out.arsize = master_a.arsize;
          slave_out.arburst = master_a.arburst;
          slave_out.arlock = master_a.arlock;
          slave_out.arcache = master_a.arcache;
          slave_out.arprot = master_a.arprot;
          slave_out.arregion = master_a.arregion;
          slave_out.arqos = master_a.arqos;
          slave_out.arvalid = master_a.arvalid;
          master_a.arready = slave_out.arready;
        end
      end else if (read_owner) begin
        master_b.rvalid = slave_out.rvalid;
        slave_out.rready = master_b.rready;
      end else begin
        master_a.rvalid = slave_out.rvalid;
        slave_out.rready = master_a.rready;
      end
    end

    always_ff @(posedge clk or negedge resetn) begin
      if (!resetn) begin
        wstate <= W_IDLE;
        rstate <= R_IDLE;
        write_owner <= 1'b0;
        read_owner <= 1'b0;
        write_prefer_b <= 1'b0;
        read_prefer_b <= 1'b0;
      end else begin
        case (wstate)
          W_IDLE: if (slave_out.awvalid && slave_out.awready) begin
            write_owner <= write_select;
            wstate <= W_DATA;
          end
          W_DATA: if (slave_out.wvalid && slave_out.wready &&
                     slave_out.wlast)
            wstate <= W_RESP;
          W_RESP: if (slave_out.bvalid && slave_out.bready) begin
            write_prefer_b <= ~write_owner;
            wstate <= W_IDLE;
          end
          default: wstate <= W_IDLE;
        endcase

        case (rstate)
          R_IDLE: if (slave_out.arvalid && slave_out.arready) begin
            read_owner <= read_select;
            rstate <= R_DATA;
          end
          R_DATA: if (slave_out.rvalid && slave_out.rready &&
                      slave_out.rlast) begin
            read_prefer_b <= ~read_owner;
            rstate <= R_IDLE;
          end
          default: rstate <= R_IDLE;
        endcase
      end
    end
endmodule
