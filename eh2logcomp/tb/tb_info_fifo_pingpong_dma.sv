`timescale 1ns/1ps

// Directed stress test for the four-bank per-hart information FIFO.
//
// Both harts write four 256-bit records per 50 MHz clock.  DDR acceptance is
// deliberately withheld for more than the time required to fill all four
// 512-record banks.  The test proves that the FIFO reports backpressure
// instead of overwriting data, then releases DDR and checks every resulting
// record, bank order, odd-record tail and final counters.
module tb_info_fifo_pingpong_dma #(
  parameter integer H0_RECORDS = 2305, // 4 full banks + odd final bank
  parameter integer H1_RECORDS = 2306, // 4 full banks + even final bank
  parameter integer DDR_STALL_UI_CYCLES = 5500,
  parameter bit EXPECT_BACKPRESSURE = 1'b1,
  // A deterministic, non-phase-locked AXI backpressure pattern.  It is
  // deliberately not $urandom so a failing waveform is always reproducible.
  parameter bit VARIABLE_AXI_READY = 1'b0,
  parameter integer B_RESPONSE_DELAY = 0,
  parameter integer WRITES_PER_CORE_CYCLE = 4,
  // When enabled, the two harts together present 2..4 records on every
  // 50-MHz producer clock.  The deterministic eight-cycle pattern includes
  // four records to hart0 alone, four to hart1 alone, balanced traffic and
  // asymmetric traffic, matching the complete EH2 logging envelope without
  // instantiating the processor.
  parameter bit VARIABLE_COMBINED_RATE = 1'b0,
  // Offset the DDR UI clock from the producer clock.  Since 266.5 MHz is not
  // phase locked to 50 MHz in this test, a long run visits the complete CDC
  // phase relationship; the explicit offset also prevents reset release from
  // accidentally occurring at a friendly coincident edge.
  parameter time UI_CLOCK_PHASE = 731ps,
  parameter integer TIMEOUT_UI_CYCLES = 160000,
  parameter bit CHECK_DDR_IMAGE = 1'b0
);

  logic core_clk = 1'b0;
  logic ui_clk = 1'b0;
  logic rst_l = 1'b0;
  always #10 core_clk = ~core_clk;       // 50 MHz
  initial begin
    #(UI_CLOCK_PHASE);
    forever #1.87617 ui_clk = ~ui_clk;   // 266.5 MHz, unrelated phase
  end

  logic [1:0][3:0] wr_valid;
  logic [1:0][3:0][255:0] wr_data;
  logic [1:0][3:0] wr_ready;
  logic [1:0][3:0] fifo_wr_valid, fifo_wr_ready;
  logic [1:0][3:0][255:0] fifo_wr_data;
  logic [1:0] write_elastic_empty, write_elastic_overflow;
  logic [1:0][4:0] write_elastic_occupancy;
  logic [1:0] fifo_overflow, fifo_init;
  logic [1:0][11:0] fifo_occupancy;
  logic capture_done_core;
  logic pipeline_done_core;
  logic capture_done_ui;
  logic [1:0] batch_valid, batch_claim, batch_done;
  logic [1:0][9:0] batch_count;
  logic [1:0] fifo_rd_valid, fifo_rd_ready, fifo_empty;
  logic [1:0][511:0] fifo_rd_data;
  logic [1:0][1:0] fifo_rd_count;
  logic [1:0] elastic_valid, elastic_ready, elastic_empty;
  logic [1:0][511:0] elastic_data;
  logic [1:0][1:0] elastic_count;
  integer input_index [0:1];
  integer accepted;
  integer remaining;
  integer slot;
  logic [1:0] saw_backpressure;
  logic [1:0] first_bundle_done;
  integer core_cycle_counter;
  integer write_budget [0:1];

  localparam integer MAX_HART_RECORDS =
      (H0_RECORDS > H1_RECORDS) ? H0_RECORDS :
      ((H1_RECORDS > 0) ? H1_RECORDS : 1);
  logic [255:0] ddr_image [0:1][0:MAX_HART_RECORDS-1];

  for (genvar h = 0; h < 2; h = h + 1) begin : g_fifo
    info_record_elastic_4w4r #(.DEPTH(16)) write_elastic_i (
      .clk(core_clk), .rst_l,
      .in_valid(wr_valid[h]), .in_data(wr_data[h]), .in_ready(wr_ready[h]),
      .out_valid(fifo_wr_valid[h]), .out_data(fifo_wr_data[h]),
      .out_ready(fifo_wr_ready[h]), .empty(write_elastic_empty[h]),
      .overflow(write_elastic_overflow[h]),
      .occupancy(write_elastic_occupancy[h])
    );
    info_fifo_pingpong_4w2r fifo_i (
      .wr_clk(core_clk), .rd_clk(ui_clk), .rst_l,
      .wr_valid(fifo_wr_valid[h]), .wr_data(fifo_wr_data[h]),
      .wr_ready(fifo_wr_ready[h]), .wr_overflow(fifo_overflow[h]),
      .wr_init_done(fifo_init[h]), .wr_occupancy(fifo_occupancy[h]),
      .wr_flush(pipeline_done_core),
      .batch_valid(batch_valid[h]), .batch_record_count(batch_count[h]),
      .batch_claim(batch_claim[h]), .batch_done(batch_done[h]),
      .rd_valid(fifo_rd_valid[h]), .rd_data(fifo_rd_data[h]),
      .rd_record_count(fifo_rd_count[h]), .rd_ready(fifo_rd_ready[h]),
      .all_empty(fifo_empty[h])
    );
    info_fifo_read_elastic elastic_i (
      .clk(ui_clk), .rst_l,
      .in_valid(fifo_rd_valid[h]), .in_data(fifo_rd_data[h]),
      .in_record_count(fifo_rd_count[h]), .in_ready(fifo_rd_ready[h]),
      .out_valid(elastic_valid[h]), .out_data(elastic_data[h]),
      .out_record_count(elastic_count[h]), .out_ready(elastic_ready[h]),
      .empty(elastic_empty[h]), .buffered_records()
    );
  end

  always_comb
    pipeline_done_core = capture_done_core && (&write_elastic_empty);

  axi4_if #(.ADDR_WIDTH(33), .DATA_WIDTH(512), .ID_WIDTH(4)) axi();
  sync_bits #(.WIDTH(1), .STAGES(3)) capture_done_sync_i (
    .clk(ui_clk), .resetn(rst_l),
    .async_in(pipeline_done_core), .sync_out(capture_done_ui)
  );
  logic [31:0] h0_written_records, h1_written_records;
  logic dma_busy, all_writes_done, axi_error, region_overflow;
  info_ddr_pingpong_write_dma dma_i (
    .clk(ui_clk), .rst_l, .capture_done(capture_done_ui),
    .h0_batch_valid(batch_valid[0]), .h0_batch_record_count(batch_count[0]),
    .h0_batch_claim(batch_claim[0]), .h0_batch_done(batch_done[0]),
    .h0_valid(elastic_valid[0]), .h0_data(elastic_data[0]),
    .h0_record_count(elastic_count[0]),
    .h0_empty(fifo_empty[0] && elastic_empty[0]), .h0_ready(elastic_ready[0]),
    .h1_batch_valid(batch_valid[1]), .h1_batch_record_count(batch_count[1]),
    .h1_batch_claim(batch_claim[1]), .h1_batch_done(batch_done[1]),
    .h1_valid(elastic_valid[1]), .h1_data(elastic_data[1]),
    .h1_record_count(elastic_count[1]),
    .h1_empty(fifo_empty[1] && elastic_empty[1]), .h1_ready(elastic_ready[1]),
    .axi, .h0_written_records, .h1_written_records,
    .busy(dma_busy), .all_writes_done, .axi_error, .region_overflow
  );

  always_comb begin
    wr_valid = '0;
    wr_data = '0;
    write_budget[0] = WRITES_PER_CORE_CYCLE;
    write_budget[1] = WRITES_PER_CORE_CYCLE;
    if (VARIABLE_COMBINED_RATE) begin
      // Total records for the eight cases are 4,4,2,3,3,4,4,4.  Four-record
      // single-hart cases exercise every physical write lane, while no cycle
      // exceeds the requested system maximum of four records.
      case (core_cycle_counter[2:0])
        3'd0: begin write_budget[0] = 4; write_budget[1] = 0; end
        3'd1: begin write_budget[0] = 0; write_budget[1] = 4; end
        3'd2: begin write_budget[0] = 1; write_budget[1] = 1; end
        3'd3: begin write_budget[0] = 2; write_budget[1] = 1; end
        3'd4: begin write_budget[0] = 1; write_budget[1] = 2; end
        3'd5: begin write_budget[0] = 2; write_budget[1] = 2; end
        3'd6: begin write_budget[0] = 3; write_budget[1] = 1; end
        default: begin write_budget[0] = 1; write_budget[1] = 3; end
      endcase
    end
    for (integer h = 0; h < 2; h = h + 1) begin
      remaining = ((h == 0) ? H0_RECORDS : H1_RECORDS) - input_index[h];
      for (slot = 0; slot < 4; slot = slot + 1) begin
        // Start each hart with a three-record bundle. Subsequent four-record
        // bundles therefore cross every 512-record bank boundary inside a
        // single core clock, exercising the bank hand-off case directly.
        // The production controller does not release EH2 until long after the
        // XPM write reset-busy interval.  Match that ordering here so this
        // throughput test does not manufacture startup backpressure by
        // filling the timing queue while its downstream FIFO is still reset.
        if (rst_l && (&fifo_init) &&
            (slot < write_budget[h]) && (remaining > slot) &&
            (VARIABLE_COMBINED_RATE || first_bundle_done[h] || (slot < 3))) begin
          wr_valid[h][slot] = 1'b1;
          wr_data[h][slot] = {224'b0,
                               ((h == 0) ? 32'hA000_0000 : 32'hB000_0000) +
                               input_index[h] + slot};
        end
      end
    end
  end

  always_ff @(posedge core_clk) begin
    if (!rst_l) begin
      input_index[0] <= 0;
      input_index[1] <= 0;
      first_bundle_done <= '0;
      capture_done_core <= 1'b0;
      saw_backpressure <= '0;
      core_cycle_counter <= 0;
    end else begin
      core_cycle_counter <= core_cycle_counter + 1;
      for (integer h = 0; h < 2; h = h + 1) begin
        accepted = 0;
        for (integer s = 0; s < 4; s = s + 1)
          if (wr_valid[h][s] && wr_ready[h][s])
            accepted = accepted + 1;
        input_index[h] <= input_index[h] + accepted;
        if (accepted != 0)
          first_bundle_done[h] <= 1'b1;
        if (fifo_init[h] && (|wr_valid[h]) &&
            (|(wr_valid[h] & ~wr_ready[h])))
          saw_backpressure[h] <= 1'b1;
      end
      if ((input_index[0] >= H0_RECORDS) &&
          (input_index[1] >= H1_RECORDS))
        capture_done_core <= 1'b1;
    end
  end

  integer ui_cycles;
  integer expected_record [0:1];
  integer claim_index;
  integer hart_claim_count [0:1];
  integer claim_hart;
  integer claim_total;
  integer expected_claim_records;
  logic aw_active;
  logic aw_hart;
  integer beats_left;
  logic [31:0] expected_word;
  integer pending_b_cycles;
  integer aw_record_index;

  always_comb begin
    axi.awready = rst_l && (ui_cycles >= DDR_STALL_UI_CYCLES) &&
                  (!VARIABLE_AXI_READY ||
                   ((ui_cycles % 11) != 2 && (ui_cycles % 17) != 5));
    axi.wready = rst_l && (ui_cycles >= DDR_STALL_UI_CYCLES) &&
                 (!VARIABLE_AXI_READY ||
                  ((ui_cycles % 7) != 1 && (ui_cycles % 13) != 6));
    axi.arready = 1'b0;
    axi.rid = '0;
    axi.rdata = '0;
    axi.rresp = 2'b00;
    axi.rlast = 1'b0;
    axi.rvalid = 1'b0;
  end

  always_ff @(posedge ui_clk) begin
    if (!rst_l) begin
      ui_cycles <= 0;
      axi.bvalid <= 1'b0;
      axi.bresp <= 2'b00;
      axi.bid <= '0;
      aw_active <= 1'b0;
      aw_hart <= 1'b0;
      beats_left <= 0;
      expected_record[0] <= 0;
      expected_record[1] <= 0;
      claim_index <= 0;
      hart_claim_count[0] <= 0;
      hart_claim_count[1] <= 0;
      pending_b_cycles <= -1;
      aw_record_index <= 0;
    end else begin
      ui_cycles <= ui_cycles + 1;
      if (batch_claim[0] || batch_claim[1]) begin
        if (batch_claim[0] && batch_claim[1])
          $fatal(1, "DMA claimed both harts in one cycle");
        // Both harts have a full bank when the directed DDR stall ends.
        // The whole-bank priority token must choose hart0 first and hart1
        // second; AXI sub-bursts may not switch the selected hart.
        if ((DDR_STALL_UI_CYCLES != 0) && (claim_index == 0) &&
            !batch_claim[0])
          $fatal(1, "first complete-bank DMA claim was not hart0");
        if ((DDR_STALL_UI_CYCLES != 0) && (claim_index == 1) &&
            !batch_claim[1])
          $fatal(1, "second complete-bank DMA claim was not hart1");
        claim_hart = batch_claim[0] ? 0 : 1;
        claim_total = (claim_hart == 0) ? H0_RECORDS : H1_RECORDS;
        if (hart_claim_count[claim_hart] < (claim_total / 512))
          expected_claim_records = 512;
        else
          expected_claim_records = claim_total % 512;
        if ((batch_claim[claim_hart] ? batch_count[claim_hart] : 0) !=
            expected_claim_records)
          $fatal(1, "hart%0d batch %0d count mismatch expected %0d got %0d",
                 claim_hart, hart_claim_count[claim_hart],
                 expected_claim_records, batch_count[claim_hart]);
        hart_claim_count[claim_hart] <= hart_claim_count[claim_hart] + 1;
        claim_index <= claim_index + 1;
      end
      if (axi.awvalid && axi.awready) begin
        if (aw_active)
          $fatal(1, "overlapping AXI write-address bursts");
        if ((axi.awlen + 1) > 64)
          $fatal(1, "DMA issued overlength burst");
        if ((axi.awaddr[11:0] + ((axi.awlen + 1) << 6)) > 4096)
          $fatal(1, "DMA crossed a 4 KiB AXI boundary");
        aw_active <= 1'b1;
        // Source index 0 is hart0 at DDR1 high 4 GiB; source index 1 is
        // hart1 at DDR1 low 4 GiB.
        aw_hart <= !axi.awaddr[32];
        aw_record_index <= axi.awaddr[31:0] >> 5;
        beats_left <= axi.awlen + 1;
      end
      if (axi.wvalid && axi.wready) begin
        if (!aw_active)
          $fatal(1, "AXI W beat without a preceding AW");
        expected_word = (aw_hart ? 32'hB000_0000 : 32'hA000_0000) +
                        expected_record[aw_hart];
        if (axi.wdata[31:0] !== expected_word)
          $fatal(1, "hart%0d record order mismatch expected=%h got=%h",
                 aw_hart, expected_word, axi.wdata[31:0]);
        if (CHECK_DDR_IMAGE) begin
          if (aw_record_index >= MAX_HART_RECORDS)
            $fatal(1, "DDR image index out of range hart%0d index=%0d",
                   aw_hart, aw_record_index);
          ddr_image[aw_hart][aw_record_index] <= axi.wdata[255:0];
          if ((aw_record_index + 1) < MAX_HART_RECORDS)
            ddr_image[aw_hart][aw_record_index + 1] <= axi.wdata[511:256];
        end
        if (axi.wlast !== (beats_left == 1))
          $fatal(1, "AXI WLAST mismatch");
        if (((aw_hart == 0) && (expected_record[0] == H0_RECORDS-1)) ||
            ((aw_hart == 1) && (expected_record[1] == H1_RECORDS-1))) begin
          if (axi.wdata[511:256] !== 256'b0)
            $fatal(1, "odd final record was not zero padded");
          expected_record[aw_hart] <= expected_record[aw_hart] + 1;
        end else begin
          if (axi.wdata[287:256] !== (expected_word + 1'b1))
            $fatal(1, "hart%0d packed second record order mismatch", aw_hart);
          expected_record[aw_hart] <= expected_record[aw_hart] + 2;
        end
        beats_left <= beats_left - 1;
        aw_record_index <= aw_record_index + 2;
        if (beats_left == 1) begin
          aw_active <= 1'b0;
          if (B_RESPONSE_DELAY == 0)
            axi.bvalid <= 1'b1;
          else
            pending_b_cycles <= B_RESPONSE_DELAY;
        end
      end
      if ((pending_b_cycles >= 0) && !axi.bvalid) begin
        if (pending_b_cycles == 0) begin
          axi.bvalid <= 1'b1;
          pending_b_cycles <= -1;
        end else begin
          pending_b_cycles <= pending_b_cycles - 1;
        end
      end
      if (axi.bvalid && axi.bready)
        axi.bvalid <= 1'b0;

      if (all_writes_done) begin
        if (EXPECT_BACKPRESSURE) begin
          if (!saw_backpressure[0] || !saw_backpressure[1])
            $fatal(1, "stall did not fill all four banks and expose backpressure");
          // valid && !ready is a recoverable ready/valid stall: the 16-entry
          // elastic queues retain the compact bundles until a bank is
          // released.  It must not be promoted to the physical XPM overflow
          // error used by the system controller.
          if ((|fifo_overflow) || (|write_elastic_overflow))
            $fatal(1,
              "recoverable full-bank backpressure was misreported as overflow fifo=%b queue=%b",
              fifo_overflow, write_elastic_overflow);
        end else if ((|saw_backpressure) || (|fifo_overflow)) begin
          $fatal(1, "nominal DMA flow unexpectedly backpressured/overflowed saw=%b fifo=%b queue=%b",
                 saw_backpressure, fifo_overflow, write_elastic_overflow);
        end
        if ((expected_record[0] != H0_RECORDS) ||
            (expected_record[1] != H1_RECORDS) ||
            (h0_written_records != H0_RECORDS) ||
            (h1_written_records != H1_RECORDS))
          $fatal(1, "record accounting mismatch h0 %0d/%0d h1 %0d/%0d",
                 h0_written_records, expected_record[0],
                 h1_written_records, expected_record[1]);
        if ((hart_claim_count[0] != ((H0_RECORDS + 511) / 512)) ||
            (hart_claim_count[1] != ((H1_RECORDS + 511) / 512)))
          $fatal(1, "not every frozen bank was claimed exactly once");
        if (axi_error || region_overflow)
          $fatal(1, "DMA reported an unexpected AXI/region error");
        if (CHECK_DDR_IMAGE) begin
          for (integer image_hart = 0; image_hart < 2;
               image_hart = image_hart + 1) begin
            for (integer image_index = 0;
                 image_index < ((image_hart == 0) ? H0_RECORDS : H1_RECORDS);
                 image_index = image_index + 1) begin
              if (ddr_image[image_hart][image_index] !==
                  {224'b0,
                   ((image_hart == 0) ? 32'hA000_0000 : 32'hB000_0000) +
                   image_index})
                $fatal(1,
                       "DDR direct compare failed hart%0d sequence=%0d expected=%h got=%h",
                       image_hart, image_index,
                       ((image_hart == 0) ? 32'hA000_0000 : 32'hB000_0000) +
                       image_index,
                       ddr_image[image_hart][image_index][31:0]);
            end
          end
          $display("INFO_DDR_DIRECT_COMPARE_PASS total=%0d",
                   H0_RECORDS + H1_RECORDS);
        end
        $display("INFO_FIFO_PINGPONG_DMA_PASS cycles=%0d h0=%0d h1=%0d",
                 ui_cycles, h0_written_records, h1_written_records);
        $finish;
      end
      if (ui_cycles > TIMEOUT_UI_CYCLES) begin
        $display("PINGPONG_TIMEOUT in=%0d/%0d,%0d/%0d done=%b occ=%0d,%0d batch_valid=%b count=%0d,%0d claim=%b empty=%b elastic_empty=%b state=%0d",
                 input_index[0], H0_RECORDS, input_index[1], H1_RECORDS,
                 capture_done_core, fifo_occupancy[0], fifo_occupancy[1],
                 batch_valid, batch_count[0], batch_count[1], batch_claim,
                 fifo_empty, elastic_empty, dma_i.state);
        $fatal(1, "pingpong FIFO/DMA stress timeout");
      end
    end
  end

  initial begin
    repeat (10) @(posedge core_clk);
    rst_l <= 1'b1;
  end
endmodule

// Processor-free long CDC/system-throughput test.  Exactly 100,000 records
// enter at the EH2 logging boundary.  Traffic is 2..4 records per producer
// cycle, crosses four asynchronous FIFO banks repeatedly, is written by the
// real whole-bank DMA, and is then compared directly in the modeled DDR
// image rather than reconstructed through Ethernet frames.
module tb_info_fifo_pingpong_dma_100k_cdc;
  tb_info_fifo_pingpong_dma #(
    .H0_RECORDS(50000), .H1_RECORDS(50000),
    .DDR_STALL_UI_CYCLES(0), .EXPECT_BACKPRESSURE(1'b0),
    .VARIABLE_COMBINED_RATE(1'b1),
    .TIMEOUT_UI_CYCLES(1000000), .CHECK_DDR_IMAGE(1'b1)
  ) run_i ();
endmodule

// Same order/count/tail test with DDR permanently ready. This proves the
// normal sustained path has no artificial backpressure or overflow.
module tb_info_fifo_pingpong_dma_nominal;
  tb_info_fifo_pingpong_dma #(
    .DDR_STALL_UI_CYCLES(0), .EXPECT_BACKPRESSURE(1'b0)
  ) run_i ();
endmodule

// The sink periodically denies AW/W and delays B responses while the writers
// remain well below the measured DMA sustainable rate.  This covers AXI
// bubbles at every channel boundary without turning normal flow control into
// a false FIFO overflow.
module tb_info_fifo_pingpong_dma_variable_axi;
  tb_info_fifo_pingpong_dma #(
    .H0_RECORDS(1537), .H1_RECORDS(1538),
    .DDR_STALL_UI_CYCLES(0), .EXPECT_BACKPRESSURE(1'b0),
    .VARIABLE_AXI_READY(1'b1), .B_RESPONSE_DELAY(5),
    .WRITES_PER_CORE_CYCLE(1)
  ) run_i ();
endmodule

// Smallest legal partial tails.  This covers the one-record 512-bit AXI beat
// with a zero upper half and the two-record fully occupied beat.
module tb_info_fifo_pingpong_dma_tiny_tail;
  tb_info_fifo_pingpong_dma #(
    .H0_RECORDS(1), .H1_RECORDS(2),
    .DDR_STALL_UI_CYCLES(0), .EXPECT_BACKPRESSURE(1'b0)
  ) run_i ();
endmodule

// Exact bank boundary versus one record beyond it: hart0 must claim one
// 512-record bank, while hart1 must claim a full bank followed by a one-record
// flushed bank.  Neither case may lose or duplicate the boundary record.
module tb_info_fifo_pingpong_dma_bank_boundary;
  tb_info_fifo_pingpong_dma #(
    .H0_RECORDS(512), .H1_RECORDS(513),
    .DDR_STALL_UI_CYCLES(0), .EXPECT_BACKPRESSURE(1'b0)
  ) run_i ();
endmodule

// DDR is held off until both harts have filled exactly all four banks.  Since
// the producer stops on the final accepted record, full storage is legal and
// must not itself latch overflow; all eight banks must drain after release.
module tb_info_fifo_pingpong_dma_exact_capacity;
  tb_info_fifo_pingpong_dma #(
    .H0_RECORDS(2048), .H1_RECORDS(2048),
    .DDR_STALL_UI_CYCLES(5500), .EXPECT_BACKPRESSURE(1'b0)
  ) run_i ();
endmodule

// Only one hart produces records.  Flushing an empty peer FIFO must not create
// a zero-length batch, disturb arbitration, or prevent all_writes_done.
module tb_info_fifo_pingpong_dma_single_hart;
  tb_info_fifo_pingpong_dma #(
    .H0_RECORDS(777), .H1_RECORDS(0),
    .DDR_STALL_UI_CYCLES(0), .EXPECT_BACKPRESSURE(1'b0)
  ) run_i ();
endmodule
