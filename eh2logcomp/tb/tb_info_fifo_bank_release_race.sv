`timescale 1ns/1ps

module tb_bank_release_race_base #(
  parameter bit EXPECT_FIXED = 1'b0
);
  logic wr_clk = 1'b0;
  logic rd_clk = 1'b0;
  logic rst_l = 1'b0;
  logic [3:0] wr_valid = '0;
  logic [3:0][255:0] wr_data = '0;
  logic [3:0] wr_ready;
  logic wr_overflow;
  logic wr_init_done;
  logic [11:0] wr_occupancy;
  logic wr_flush = 1'b0;
  logic batch_valid;
  logic [9:0] batch_record_count;
  logic batch_claim = 1'b0;
  logic batch_done = 1'b0;
  logic rd_valid;
  logic [511:0] rd_data;
  logic [1:0] rd_record_count;
  logic rd_ready = 1'b0;
  logic all_empty;

  always #10 wr_clk = ~wr_clk;
  always #1.876 rd_clk = ~rd_clk;

  info_fifo_pingpong_4w2r dut (
    .wr_clk, .rd_clk, .rst_l,
    .wr_valid, .wr_data, .wr_ready, .wr_overflow,
    .wr_init_done, .wr_occupancy, .wr_flush,
    .batch_valid, .batch_record_count, .batch_claim, .batch_done,
    .rd_valid, .rd_data, .rd_record_count, .rd_ready, .all_empty
  );

  task automatic push_four(input integer base);
    begin
      @(negedge wr_clk);
      for (int slot = 0; slot < 4; slot++)
        wr_data[slot] = {224'b0, (base + slot)};
      wr_valid = 4'b1111;
      #1;
      if (wr_ready !== 4'b1111)
        $fatal(1, "unexpected backpressure before race base=%0d ready=%b", base,
               wr_ready);
      @(posedge wr_clk);
      #1;
      wr_valid = '0;
    end
  endtask

  initial begin
    repeat (8) @(posedge wr_clk);
    rst_l = 1'b1;
    wait (wr_init_done === 1'b1);
    repeat (4) @(posedge wr_clk);

    // Fill bank0..bank2 completely and bank3 to 508/512 records.
    for (int bundle = 0; bundle < 511; bundle++)
      push_four(bundle * 4);

    if ((dut.bank_owned_core !== 4'b0111) ||
        (dut.bank_record_count_core[3] !== 10'd508) ||
        !dut.wr_bank_valid || (dut.wr_bank !== 2'd3))
      $fatal(1,
        "bad precondition owned=%b counts=%h wr_bank=%0d valid=%b",
        dut.bank_owned_core, dut.bank_record_count_core,
        dut.wr_bank, dut.wr_bank_valid);

    // Model a DMA-complete release arriving on exactly the edge that the
    // current fourth bank receives its final four records.
    @(negedge wr_clk);
    for (int slot = 0; slot < 4; slot++)
      wr_data[slot] = {224'b0, (2044 + slot)};
    wr_valid = 4'b1111;
    force dut.release_core = 4'b0001;
    #1;
    if (wr_ready !== 4'b1111)
      $fatal(1, "last bundle was not accepted ready=%b", wr_ready);
    @(posedge wr_clk);
    #1;
    release dut.release_core;
    wr_valid = '0;

    $display(
      "AFTER_COLLISION owned=%b counts=%h wr_bank=%0d wr_bank_valid=%b overflow=%b",
      dut.bank_owned_core, dut.bank_record_count_core,
      dut.wr_bank, dut.wr_bank_valid, wr_overflow);

    if ((dut.bank_owned_core !== 4'b1110) ||
        (dut.bank_record_count_core[0] !== 10'd0))
      $fatal(1, "released bank0 did not become physically available");

    // Bank0 is now free.  A correct selector must immediately accept this
    // record.  The current RTL remains invalid until a future release event.
    @(negedge wr_clk);
    wr_data[0] = {224'b0, 32'd2048};
    wr_valid = 4'b0001;
    #1;
    $display("NEXT_WRITE ready=%b free_bank0=%b wr_bank_valid=%b",
             wr_ready, !dut.bank_owned_core[0], dut.wr_bank_valid);
    if (wr_ready[0] !== 1'b0)
      $fatal(1, "expected one selector-recovery cycle");
    @(posedge wr_clk);
    #1;
    if (!EXPECT_FIXED) begin
      if (!wr_overflow)
        $fatal(1, "temporary selector stall did not latch wr_overflow");
      $display(
        "BANK_RELEASE_COLLISION_REPRODUCED free_bank_exists=1 accepted=0 overflow=1");
    end else begin
      if (wr_overflow)
        $fatal(1, "recoverable backpressure was still reported as overflow");
      if (!dut.wr_bank_valid || (dut.wr_bank != 2'd0) || !wr_ready[0])
        $fatal(1,
          "selector did not recover bank0 valid=%b bank=%0d ready=%b",
          dut.wr_bank_valid, dut.wr_bank, wr_ready);
      @(posedge wr_clk);
      #1;
      if (dut.bank_record_count_core[0] != 10'd1)
        $fatal(1, "held record was not accepted after recovery");
      $display(
        "BANK_RELEASE_COLLISION_FIXED free_bank_selected=0 accepted=1 overflow=0");
    end
    $finish;
  end
endmodule

module tb_info_fifo_bank_release_race;
  tb_bank_release_race_base #(.EXPECT_FIXED(1'b1)) run_i();
endmodule
