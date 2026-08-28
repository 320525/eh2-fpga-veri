`timescale 1ns/1ps

module tb_info_ddr_read_dma_fixed30;
  logic clk = 0;
  logic resetn = 0;
  always #1.876 clk = ~clk;

  axi4_if axi();
  logic start, hart, busy, done, axi_error, protocol_error;
  logic [31:0] frame_number;
  logic [5:0] valid_records;
  logic data_valid, data_ready, data_last;
  logic [511:0] data;
  logic [4:0] data_index;
  logic memory_protocol_error;
  logic [31:0] write_beats, read_beats;

  info_ddr_read_dma dut (.*);
  axi512_memory_model #(.LINE_COUNT(256)) memory_i (
    .clk, .resetn,
    .awid(axi.awid), .awaddr(axi.awaddr), .awlen(axi.awlen),
    .awsize(axi.awsize), .awburst(axi.awburst),
    .awvalid(axi.awvalid), .awready(axi.awready),
    .wdata(axi.wdata), .wstrb(axi.wstrb), .wlast(axi.wlast),
    .wvalid(axi.wvalid), .wready(axi.wready),
    .bid(axi.bid), .bresp(axi.bresp), .bvalid(axi.bvalid),
    .bready(axi.bready), .arid(axi.arid), .araddr(axi.araddr),
    .arlen(axi.arlen), .arsize(axi.arsize), .arburst(axi.arburst),
    .arvalid(axi.arvalid), .arready(axi.arready),
    .rid(axi.rid), .rdata(axi.rdata), .rresp(axi.rresp),
    .rlast(axi.rlast), .rvalid(axi.rvalid), .rready(axi.rready),
    .protocol_error(memory_protocol_error),
    .write_beat_count(write_beats), .read_beat_count(read_beats)
  );

  int burst_count = 0;
  int data_count = 0;
  logic [32:0] expected_araddr = 33'h0_0000_0f00;

  always @(negedge clk) begin
    if (resetn && axi.arvalid && axi.arready) begin
      if (axi.araddr !== expected_araddr)
        $fatal(1, "AR address %h expected %h", axi.araddr, expected_araddr);
      if ((axi.araddr[11:0] + ((axi.arlen + 1) << 6)) > 4096)
        $fatal(1, "burst crossed 4 KiB boundary");
      expected_araddr = expected_araddr + ((axi.arlen + 1) << 6);
      burst_count = burst_count + 1;
    end
    if (data_valid && data_ready) begin
      if (data_index != data_count[4:0])
        $fatal(1, "data index %0d expected %0d", data_index, data_count);
      if (data_last != (data_count == 29))
        $fatal(1, "data_last mismatch at beat %0d", data_count);
      data_count = data_count + 1;
    end
  end

  initial begin
    start = 0;
    hart = 1;
    // frame 2 begins at byte 0xF00, requiring 4 + 26 beat bursts.
    frame_number = 2;
    valid_records = 53;
    data_ready = 1;
    repeat (8) @(posedge clk);
    resetn = 1;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    wait (done);
    @(negedge clk);
    if (data_count != 30 || burst_count != 2 || read_beats != 27)
      $fatal(1, "beats=%0d memory=%0d bursts=%0d expected 30/27/2",
             data_count, read_beats, burst_count);
    if (axi_error || protocol_error || memory_protocol_error)
      $fatal(1, "unexpected DMA/model error %b/%b/%b", axi_error,
             protocol_error, memory_protocol_error);
    $display("TB_PASS: 27 DDR beats plus 3 local zero pads, fixed 30-beat output and 4-KiB split passed");
    $finish;
  end

  initial begin
    #100us;
    $fatal(1, "timeout");
  end
endmodule
