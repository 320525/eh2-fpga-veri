`timescale 1ns/1ps

module tb_info_fifo_read_elastic;
  logic clk = 1'b0;
  logic rst_l = 1'b0;
  always #1.8765 clk = ~clk; // DDR1 UI: approximately 266.525 MHz

  logic in_valid;
  logic [511:0] in_data;
  logic [1:0] in_record_count;
  logic in_ready;
  logic out_valid;
  logic [511:0] out_data;
  logic [1:0] out_record_count;
  logic out_ready;
  logic empty;
  logic [2:0] buffered_records;

  info_fifo_read_elastic dut (.*);

  integer produced;
  integer consumed;
  integer cycle_count;
  integer expected_records;
  logic [31:0] lfsr;

  always_comb begin
    in_valid = rst_l && (produced < 1000);
    in_data = {256'hCAFE_0000 + produced, 224'd0, produced[31:0]};
    in_record_count = (produced == 999) ? 2'd1 : 2'd2;
  end

  always_ff @(posedge clk) begin
    if (!rst_l) begin
      produced <= 0;
      consumed <= 0;
      cycle_count <= 0;
      expected_records <= 0;
      lfsr <= 32'h1ACE_B00C;
      out_ready <= 1'b0;
    end else begin
      cycle_count <= cycle_count + 1;
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      out_ready <= lfsr[0] | lfsr[4];

      if (in_valid && in_ready)
        produced <= produced + 1;

      if (out_valid && out_ready) begin
        if (out_data[31:0] !== consumed[31:0])
          $fatal(1, "elastic order error expected=%0d got=%0d",
                 consumed, out_data[31:0]);
        if (out_record_count !== ((consumed == 999) ? 2'd1 : 2'd2))
          $fatal(1, "record count error at beat %0d", consumed);
        consumed <= consumed + 1;
        expected_records <= expected_records + out_record_count;
      end

      if (buffered_records > 4)
        $fatal(1, "buffered record count overflow: %0d", buffered_records);
      if ((produced == 1000) && (consumed == 1000) && empty) begin
        if (expected_records != 1999)
          $fatal(1, "total record mismatch: %0d", expected_records);
        $display("INFO_FIFO_READ_ELASTIC_PRESSURE_PASS beats=%0d records=%0d cycles=%0d",
                 consumed, expected_records, cycle_count);
        $finish;
      end
      if (cycle_count > 10000)
        $fatal(1, "elastic pressure test timeout");
    end
  end

  initial begin
    repeat (8) @(posedge clk);
    rst_l <= 1'b1;
  end
endmodule
