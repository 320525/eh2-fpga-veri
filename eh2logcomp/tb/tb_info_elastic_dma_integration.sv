`timescale 1ns/1ps

module tb_info_elastic_dma_integration;
  localparam integer H0_BEATS = 130;
  localparam integer H1_BEATS = 75;
  localparam integer H0_RECORDS = H0_BEATS * 2 - 1;
  localparam integer H1_RECORDS = H1_BEATS * 2;

  logic clk = 1'b0;
  logic rst_l = 1'b0;
  always #1.8765 clk = ~clk;

  logic [1:0] src_valid;
  logic [1:0][511:0] src_data;
  logic [1:0][1:0] src_records;
  logic [1:0] src_ready;
  logic [1:0] dma_valid;
  logic [1:0][511:0] dma_data;
  logic [1:0][1:0] dma_records;
  logic [1:0] dma_ready;
  logic [1:0] elastic_empty;
  logic [1:0][2:0] elastic_buffered;
  logic [1:0][10:0] source_occupancy;
  logic [1:0][10:0] dma_occupancy;
  logic [1:0] dma_empty;
  integer source_index [0:1];

  for (genvar hart = 0; hart < 2; hart = hart + 1) begin : g_elastic
    info_fifo_read_elastic elastic_i (
      .clk, .rst_l,
      .in_valid(src_valid[hart]), .in_data(src_data[hart]),
      .in_record_count(src_records[hart]), .in_ready(src_ready[hart]),
      .out_valid(dma_valid[hart]), .out_data(dma_data[hart]),
      .out_record_count(dma_records[hart]), .out_ready(dma_ready[hart]),
      .empty(elastic_empty[hart]),
      .buffered_records(elastic_buffered[hart])
    );
    // Match the production connection: the upstream count alone is used for
    // burst planning.  It is deliberately conservative because a registered
    // FIFO count can temporarily include data already held by the elastic
    // queue; adding both values can advertise a burst longer than reality.
    assign dma_occupancy[hart] = source_occupancy[hart];
    assign dma_empty[hart] = !src_valid[hart] && elastic_empty[hart];
  end

  always_comb begin
    src_valid[0] = rst_l && (source_index[0] < H0_BEATS);
    src_valid[1] = rst_l && (source_index[1] < H1_BEATS);
    src_data[0] = {224'd0, 32'hA000_0000 + source_index[0],
                   224'd0, source_index[0][31:0]};
    src_data[1] = {224'd0, 32'hB000_0000 + source_index[1],
                   224'd0, source_index[1][31:0]};
    src_records[0] = (source_index[0] == H0_BEATS-1) ? 2'd1 : 2'd2;
    src_records[1] = 2'd2;
    source_occupancy[0] = H0_RECORDS -
                          ((source_index[0] * 2 > H0_RECORDS) ?
                           H0_RECORDS : source_index[0] * 2);
    source_occupancy[1] = H1_RECORDS - source_index[1] * 2;
  end

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) axi();
  logic [31:0] h0_written_records;
  logic [31:0] h1_written_records;
  logic busy;
  logic all_writes_done;
  logic axi_error;
  logic region_overflow;

  info_ddr_write_dma dut (
    .clk, .rst_l, .capture_done(1'b1),
    .h0_valid(dma_valid[0]), .h0_data(dma_data[0]),
    .h0_record_count(dma_records[0]), .h0_occupancy(dma_occupancy[0]),
    .h0_empty(dma_empty[0]), .h0_ready(dma_ready[0]),
    .h1_valid(dma_valid[1]), .h1_data(dma_data[1]),
    .h1_record_count(dma_records[1]), .h1_occupancy(dma_occupancy[1]),
    .h1_empty(dma_empty[1]), .h1_ready(dma_ready[1]),
    .axi, .h0_written_records, .h1_written_records,
    .busy, .all_writes_done, .axi_error, .region_overflow
  );

  logic [31:0] lfsr;
  logic aw_active;
  logic active_hart_model;
  integer burst_left;
  integer expected_beat [0:1];
  integer cycle_count;
  integer aw_count;
  logic first_aw_hart;

  always_ff @(posedge clk) begin
    if (!rst_l) begin
      source_index[0] <= 0;
      source_index[1] <= 0;
      expected_beat[0] <= 0;
      expected_beat[1] <= 0;
      lfsr <= 32'h5203_A55A;
      axi.awready <= 1'b0;
      axi.wready <= 1'b0;
      axi.bvalid <= 1'b0;
      axi.bresp <= 2'b00;
      axi.bid <= '0;
      axi.arready <= 1'b0;
      axi.rid <= '0;
      axi.rdata <= '0;
      axi.rresp <= '0;
      axi.rlast <= 1'b0;
      axi.rvalid <= 1'b0;
      aw_active <= 1'b0;
      active_hart_model <= 1'b0;
      burst_left <= 0;
      cycle_count <= 0;
      aw_count <= 0;
      first_aw_hart <= 1'b0;
    end else begin
      cycle_count <= cycle_count + 1;
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      axi.awready <= lfsr[0] | lfsr[3];
      axi.wready <= lfsr[1] | lfsr[5];

      for (integer h = 0; h < 2; h = h + 1)
        if (src_valid[h] && src_ready[h])
          source_index[h] <= source_index[h] + 1;

      if (axi.awvalid && axi.awready) begin
        if (aw_active)
          $fatal(1, "second AW accepted before prior burst completed");
        if ((axi.awlen + 1) > 64)
          $fatal(1, "burst exceeds 64 beats: %0d", axi.awlen + 1);
        if ((axi.awaddr[11:0] + ((axi.awlen + 1) << 6)) > 4096)
          $fatal(1, "burst crosses 4 KiB: addr=%h len=%0d",
                 axi.awaddr, axi.awlen + 1);
        aw_active <= 1'b1;
        active_hart_model <= !axi.awaddr[32]; // hart0 high 4 GiB
        burst_left <= axi.awlen + 1;
        if (aw_count == 0)
          first_aw_hart <= !axi.awaddr[32];
        else if ((aw_count == 1) &&
                 (first_aw_hart == !axi.awaddr[32]))
          $fatal(1, "both harts had data but DMA did not rotate burst priority");
        aw_count <= aw_count + 1;
      end

      if (axi.wvalid && axi.wready) begin
        if (!aw_active)
          $fatal(1, "W beat without active AW");
        if (axi.wdata[31:0] !== expected_beat[active_hart_model][31:0])
          $fatal(1, "hart%0d data order error expected=%0d got=%0d",
                 active_hart_model, expected_beat[active_hart_model],
                 axi.wdata[31:0]);
        if (axi.wlast !== (burst_left == 1))
          $fatal(1, "WLAST mismatch left=%0d", burst_left);
        if ((active_hart_model == 0) &&
            (expected_beat[0] == H0_BEATS-1) &&
            ((axi.wstrb !== 64'hFFFF_FFFF_FFFF_FFFF) ||
             (axi.wdata[511:256] !== 256'b0)))
          $fatal(1, "final odd hart0 ECC-line initialization mismatch");
        expected_beat[active_hart_model] <=
          expected_beat[active_hart_model] + 1;
        burst_left <= burst_left - 1;
        if (burst_left == 1) begin
          aw_active <= 1'b0;
          axi.bvalid <= 1'b1;
        end
      end

      if (axi.bvalid && axi.bready)
        axi.bvalid <= 1'b0;

      if (all_writes_done) begin
        if (expected_beat[0] != H0_BEATS || expected_beat[1] != H1_BEATS)
          $fatal(1, "beat totals h0=%0d h1=%0d",
                 expected_beat[0], expected_beat[1]);
        if (h0_written_records != H0_RECORDS ||
            h1_written_records != H1_RECORDS)
          $fatal(1, "record totals h0=%0d h1=%0d",
                 h0_written_records, h1_written_records);
        if (axi_error || region_overflow)
          $fatal(1, "unexpected DMA error");
        $display("INFO_ELASTIC_DMA_INTEGRATION_PASS h0_records=%0d h1_records=%0d cycles=%0d",
                 h0_written_records, h1_written_records, cycle_count);
        $finish;
      end
      if (cycle_count > 20000)
        $fatal(1, "elastic DMA integration timeout");
    end
  end

  initial begin
    repeat (8) @(posedge clk);
    rst_l <= 1'b1;
  end
endmodule
