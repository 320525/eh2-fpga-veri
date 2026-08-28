`timescale 1ns/1ps

module tb_axi_w_channel_register_slice;
  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #1.876 clk = ~clk;

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) source();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) sink();
  axi_w_channel_register_slice dut (.clk, .resetn, .source, .sink);

  integer sent;
  integer received;
  integer cycle_count;
  integer lfsr;
  localparam integer BEATS = 2000;

  always_comb begin
    source.awid = 0; source.awaddr = 0; source.awlen = 0;
    source.awsize = 3'd6; source.awburst = 2'b01; source.awlock = 0;
    source.awcache = 0; source.awprot = 0; source.awregion = 0;
    source.awqos = 0; source.awvalid = 0;
    source.wvalid = resetn && (sent < BEATS);
    source.wdata = {{480{1'b0}}, sent[31:0]};
    source.wstrb = {64{1'b1}};
    source.wlast = (sent % 30) == 29;
    source.bready = 1'b1;
    source.arid = 0; source.araddr = 0; source.arlen = 0;
    source.arsize = 3'd6; source.arburst = 2'b01; source.arlock = 0;
    source.arcache = 0; source.arprot = 0; source.arregion = 0;
    source.arqos = 0; source.arvalid = 0; source.rready = 1'b1;

    sink.awready = 1'b0;
    sink.wready = resetn && (lfsr[3:0] != 4'h0) &&
                  (lfsr[8:5] != 4'hf);
    sink.bid = 0; sink.bresp = 0; sink.bvalid = 0;
    sink.arready = 0; sink.rid = 0; sink.rdata = 0;
    sink.rresp = 0; sink.rlast = 0; sink.rvalid = 0;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      sent <= 0;
      received <= 0;
      cycle_count <= 0;
      lfsr <= 32'h3205_2501;
    end else begin
      cycle_count <= cycle_count + 1;
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      if (source.wvalid && source.wready)
        sent <= sent + 1;
      if (sink.wvalid && sink.wready) begin
        if (sink.wdata[31:0] !== received[31:0])
          $fatal(1, "W data order mismatch got=%0d expected=%0d",
                 sink.wdata[31:0], received);
        if (sink.wstrb !== {64{1'b1}})
          $fatal(1, "WSTRB mismatch at beat %0d", received);
        if (sink.wlast !== ((received % 30) == 29))
          $fatal(1, "WLAST mismatch at beat %0d", received);
        received <= received + 1;
      end
      if (received == BEATS) begin
        $display("AXI_W_REGISTER_SLICE_PRESSURE_PASS beats=%0d cycles=%0d",
                 received, cycle_count);
        $finish;
      end
      if (cycle_count > 10000)
        $fatal(1, "timeout sent=%0d received=%0d", sent, received);
    end
  end

  initial begin
    repeat (8) @(posedge clk);
    resetn = 1'b1;
  end
endmodule
