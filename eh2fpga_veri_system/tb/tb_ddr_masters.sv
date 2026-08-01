`timescale 1ns/1ps

module tb_ddr_masters;
  logic clk = 1'b0;
  logic resetn = 1'b0;
  always #2 clk = ~clk;

  logic fill_start, fill_busy, fill_done, fill_error;
  logic [32:0] fill_bytes;
  logic check_start, check_busy, check_done, check_pass, check_error;
  logic [31:0] mismatch_count;
  logic select_check;

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) fill_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) check_axi();
  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) mem_axi();

  ddr_fill_master #(
    .BASE_ADDR(33'h0000_01000),
    .LENGTH_BYTES(33'd1024),
    .FILL_DATA({512{1'b1}})
  ) fill_i (
    .clk, .resetn, .start(fill_start), .busy(fill_busy),
    .done(fill_done), .error(fill_error), .bytes_completed(fill_bytes),
    .m_axi(fill_axi)
  );

  ddr_read_compare_master #(
    .BASE_ADDR(33'h0000_01000),
    .LENGTH_BYTES(1024),
    .EXPECT_DATA({512{1'b1}})
  ) check_i (
    .clk, .resetn, .start(check_start), .busy(check_busy),
    .done(check_done), .pass(check_pass), .error(check_error),
    .mismatch_count, .m_axi(check_axi)
  );

  axi_owner_mux2 mux_i (
    .select_b(select_check), .master_a(fill_axi),
    .master_b(check_axi), .slave_out(mem_axi)
  );

  logic [511:0] memory [0:63];
  logic aw_active;
  logic [32:0] aw_addr;
  logic [7:0] aw_len;
  logic [7:0] w_index;
  logic bvalid;
  logic [3:0] bid;
  logic ar_active;
  logic [32:0] ar_addr;
  logic [7:0] ar_len;
  logic [7:0] r_index;
  logic rvalid;

  assign mem_axi.awready = !aw_active;
  assign mem_axi.wready  = aw_active;
  assign mem_axi.bid     = bid;
  assign mem_axi.bresp   = 2'b00;
  assign mem_axi.bvalid  = bvalid;
  assign mem_axi.arready = !ar_active;
  assign mem_axi.rid     = mem_axi.arid;
  assign mem_axi.rdata   = memory[(ar_addr - 33'h1000)/64 + r_index];
  assign mem_axi.rresp   = 2'b00;
  assign mem_axi.rlast   = ar_active && (r_index == ar_len);
  assign mem_axi.rvalid  = rvalid;

  always_ff @(posedge clk) begin
    if (!resetn) begin
      aw_active <= 1'b0;
      aw_addr <= 33'b0;
      aw_len <= 8'b0;
      w_index <= 8'b0;
      bvalid <= 1'b0;
      bid <= 4'b0;
      ar_active <= 1'b0;
      ar_addr <= 33'b0;
      ar_len <= 8'b0;
      r_index <= 8'b0;
      rvalid <= 1'b0;
      for (integer i = 0; i < 64; i = i + 1)
        memory[i] <= 512'b0;
    end else begin
      if (mem_axi.awvalid && mem_axi.awready) begin
        aw_active <= 1'b1;
        aw_addr <= mem_axi.awaddr;
        aw_len <= mem_axi.awlen;
        w_index <= 8'b0;
        bid <= mem_axi.awid;
      end
      if (mem_axi.wvalid && mem_axi.wready) begin
        for (integer byte_lane = 0; byte_lane < 64; byte_lane = byte_lane + 1)
          if (mem_axi.wstrb[byte_lane])
            memory[(aw_addr - 33'h1000)/64 + w_index][byte_lane*8 +: 8] <=
              mem_axi.wdata[byte_lane*8 +: 8];
        if (mem_axi.wlast) begin
          if (w_index != aw_len)
            $fatal(1, "write WLAST mismatch");
          aw_active <= 1'b0;
          bvalid <= 1'b1;
        end else begin
          w_index <= w_index + 8'd1;
        end
      end
      if (bvalid && mem_axi.bready)
        bvalid <= 1'b0;

      if (mem_axi.arvalid && mem_axi.arready) begin
        ar_active <= 1'b1;
        ar_addr <= mem_axi.araddr;
        ar_len <= mem_axi.arlen;
        r_index <= 8'b0;
        rvalid <= 1'b1;
      end
      if (rvalid && mem_axi.rready) begin
        if (r_index == ar_len) begin
          ar_active <= 1'b0;
          rvalid <= 1'b0;
        end else begin
          r_index <= r_index + 8'd1;
        end
      end
    end
  end

  initial begin
    fill_start = 1'b0;
    check_start = 1'b0;
    select_check = 1'b0;
    repeat (5) @(posedge clk);
    resetn <= 1'b1;
    repeat (3) @(posedge clk);
    fill_start <= 1'b1;
    @(posedge clk);
    fill_start <= 1'b0;
    wait (fill_done);
    if (fill_error || (fill_bytes != 1024))
      $fatal(1, "fill failed bytes=%0d error=%0b", fill_bytes, fill_error);
    select_check <= 1'b1;
    check_start <= 1'b1;
    @(posedge clk);
    check_start <= 1'b0;
    wait (check_done);
    if (check_error || !check_pass || (mismatch_count != 0))
      $fatal(1, "read compare failed pass=%0b mismatch=%0d",
             check_pass, mismatch_count);
    $display("TB_PASS DDR fill/check bytes=%0d", fill_bytes);
    $finish;
  end

  initial begin
    #1ms;
    $fatal(1, "global simulation timeout");
  end
endmodule

