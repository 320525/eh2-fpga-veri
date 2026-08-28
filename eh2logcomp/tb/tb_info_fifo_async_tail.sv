`timescale 1ns/1ps

module tb_info_fifo_async_tail;
  logic wr_clk = 0;
  logic rd_clk = 0;
  logic rst_l = 0;
  always #10 wr_clk = ~wr_clk;
  always #1.876 rd_clk = ~rd_clk;

  logic [3:0] wr_valid;
  logic [3:0][255:0] wr_data;
  logic [3:0] wr_ready;
  logic wr_overflow, wr_init_done;
  logic [6:0] wr_occupancy;
  logic wr_flush;
  logic rd_valid;
  logic [511:0] rd_data;
  logic [1:0] rd_record_count;
  logic rd_ready;
  logic rd_empty;
  logic [6:0] rd_occupancy;
  integer sent;
  integer received;
  integer cycle_count;
  localparam integer RECORDS = 17;

  info_fifo_async_4w2r #(.RECORD_DEPTH(64)) dut (
    .wr_clk, .rd_clk, .rst_l, .wr_valid, .wr_data, .wr_ready,
    .wr_overflow, .wr_init_done, .wr_occupancy, .wr_flush,
    .rd_valid, .rd_data, .rd_record_count, .rd_ready,
    .rd_empty, .rd_occupancy
  );

  always_comb begin
    wr_valid = '0;
    wr_data = '0;
    for (integer slot = 0; slot < 4; slot = slot + 1) begin
      if ((sent + slot) < RECORDS) begin
        wr_valid[slot] = 1'b1;
        wr_data[slot][31:0] = sent + slot;
      end
    end
    rd_ready = rst_l && (cycle_count[2:0] != 3'b111);
  end

  always_ff @(posedge wr_clk) begin
    if (!rst_l)
      sent <= 0;
    else if (wr_valid != 0) begin
      integer accepted;
      accepted = 0;
      for (integer slot = 0; slot < 4; slot = slot + 1)
        if (wr_valid[slot] && wr_ready[slot]) accepted = accepted + 1;
      sent <= sent + accepted;
    end
  end

  always_ff @(posedge rd_clk) begin
    if (!rst_l) begin
      received <= 0;
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (rd_valid && rd_ready) begin
        if (rd_data[31:0] !== received[31:0])
          $fatal(1, "first record mismatch got=%0d exp=%0d",
                 rd_data[31:0], received);
        if (rd_record_count == 2 &&
            rd_data[287:256] !== (received+1))
          $fatal(1, "second record mismatch got=%0d exp=%0d",
                 rd_data[287:256], received+1);
        if ((received + rd_record_count) > RECORDS)
          $fatal(1, "too many records");
        if ((received + rd_record_count) == RECORDS &&
            rd_record_count != 1)
          $fatal(1, "odd tail was not emitted singly");
        received <= received + rd_record_count;
      end
      if (received == RECORDS && rd_empty) begin
        if (wr_overflow) $fatal(1, "unexpected overflow");
        $display("INFO_FIFO_ASYNC_ODD_TAIL_PASS records=%0d cycles=%0d",
                 received, cycle_count);
        $finish;
      end
      if (cycle_count > 5000)
        $fatal(1, "timeout sent=%0d received=%0d occ=%0d",
               sent, received, rd_occupancy);
    end
  end

  initial begin
    wr_flush = 0;
    repeat (12) @(posedge wr_clk);
    rst_l = 1;
    wait (sent == RECORDS);
    repeat (8) @(posedge wr_clk);
    wr_flush = 1;
  end
endmodule
