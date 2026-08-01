`timescale 1ns/1ps

module eh2_hw_init_tb;
  logic clk = 1'b0;
  logic resetn = 1'b0;
  logic debug_halted = 1'b0;
  logic run_ack = 1'b0;
  wire run_req;
  wire init_busy;
  wire init_done;
  wire init_error;
  wire dma_awvalid;
  logic dma_awready = 1'b1;
  wire [0:0] dma_awid;
  wire [31:0] dma_awaddr;
  wire [2:0] dma_awsize;
  wire [2:0] dma_awprot;
  wire [7:0] dma_awlen;
  wire [1:0] dma_awburst;
  wire dma_wvalid;
  logic dma_wready = 1'b1;
  wire [63:0] dma_wdata;
  wire [7:0] dma_wstrb;
  wire dma_wlast;
  logic dma_bvalid = 1'b0;
  wire dma_bready;
  logic [1:0] dma_bresp = 2'b00;
  logic [0:0] dma_bid = 1'b0;

  logic aw_seen;
  logic w_seen;
  logic [31:0] accepted_addr;
  logic [31:0] expected_addr;
  integer response_count;
  integer run_wait;

  always #10 clk = ~clk;

  eh2_hw_init dut (.*);

  always_ff @(posedge clk) begin
    if (!resetn) begin
      aw_seen       <= 1'b0;
      w_seen        <= 1'b0;
      accepted_addr <= '0;
      expected_addr <= 32'hf004_0000;
      response_count <= 0;
      dma_bvalid    <= 1'b0;
      run_ack       <= 1'b0;
      run_wait      <= 0;
    end else begin
      if (dma_awvalid && dma_awready) begin
        if (dma_awaddr !== expected_addr || dma_awsize !== 3'd3 ||
            dma_awlen !== 8'd0 || dma_awburst !== 2'b01)
          $fatal(1, "Unexpected scrub AW: expected=%h actual=%h", expected_addr, dma_awaddr);
        accepted_addr <= dma_awaddr;
        aw_seen <= 1'b1;
      end
      if (dma_wvalid && dma_wready) begin
        if (dma_wdata !== 64'd0 || dma_wstrb !== 8'hff || !dma_wlast)
          $fatal(1, "Unexpected scrub W payload");
        w_seen <= 1'b1;
      end

      if (!dma_bvalid &&
          (aw_seen || (dma_awvalid && dma_awready)) &&
          (w_seen  || (dma_wvalid && dma_wready))) begin
        dma_bvalid <= 1'b1;
        aw_seen <= 1'b0;
        w_seen  <= 1'b0;
      end else if (dma_bvalid && dma_bready) begin
        dma_bvalid <= 1'b0;
        response_count <= response_count + 1;
        if (expected_addr == 32'hf004_fff8)
          expected_addr <= 32'hee00_0000;
        else
          expected_addr <= expected_addr + 32'd8;
      end

      if (run_req && !run_ack) begin
        run_wait <= run_wait + 1;
        if (run_wait == 3)
          run_ack <= 1'b1;
      end
    end
  end

  initial begin
    repeat (5) @(posedge clk);
    resetn <= 1'b1;
    repeat (4) @(posedge clk);
    debug_halted <= 1'b1;
    wait (init_done);
    if (init_error || response_count != 16384 ||
        expected_addr != 32'hee01_0000)
      $fatal(1, "Production scrub failed: count=%0d next=%h error=%b",
             response_count, expected_addr, init_error);
    $display("PASS: production EH2 scrub issued 16384 ordered 64-bit zero writes across full DCCM and ICCM ranges");
    $finish;
  end

  initial begin
    #5_000_000;
    $fatal(1, "TIMEOUT: production EH2 scrub unit test");
  end
endmodule
