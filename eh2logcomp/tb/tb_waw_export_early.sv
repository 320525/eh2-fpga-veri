`timescale 1ns/1ps

// Focused regression for the WAW sideband exported by the exact CRC/hash RTL
// used by the integrated system.  The stress image puts all expected WAW
// cancellations before hart1 sequence 524, so stopping after 600 commits
// avoids repeating the full 200k-instruction system simulation.
module tb_waw_export_early;
  logic core_clk = 1'b0;
  logic crc_rd_clk = 1'b0;
  logic infra_rst_l = 1'b0;
  always #10 core_clk = ~core_clk;
  always #4 crc_rd_clk = ~crc_rd_clk;

  logic core_rst_l, crc_system_ready;
  logic pass_latched, fail_latched, activity_seen, hart1_commit_seen;
  logic [1:0] stopped;
  logic [1:0][31:0] commit_count, generated_count;
  logic [1:0][1:0] result_valid;
  logic [1:0][1:0][15:0] result_package_number;
  logic [1:0][1:0][63:0] result_xor0, result_xor1;
  logic [1:0][1:0][63:0] result_sum0, result_sum1, result_sum2, result_sum3;
  logic [1:0][1:0][31:0] result_item_count;

  integer waw_count;
  integer waw_count_hart [0:1];
  logic observed_hart [0:255];
  logic [15:0] observed_package [0:255];
  logic [15:0] observed_sequence [0:255];

  eh2_crc_soc #(
    .MEM_BYTES(1_048_576),
    .MEM_FILE("../../programs/stress_200k_dualhart_system/build/stress_200k_dualhart_system.mem64"),
    .RUN_HART_MASK(2'b11),
    .ENABLE_GOLDEN_CHECK(1'b0)
  ) dut (.*);

  always @(posedge core_clk) begin
    if (infra_rst_l) begin
      for (integer lane = 0; lane < 4; lane = lane + 1) begin
        if (dut.crc_i.waw_cancel_valid[lane]) begin
          integer local_index;
          logic [15:0] expected_sequence;
          if (waw_count >= 256)
            $fatal(1, "too many WAW events");
          if (dut.crc_i.waw_cancel_package[lane] != 16'd0)
            $fatal(1, "WAW package=%0d expected=0",
                   dut.crc_i.waw_cancel_package[lane]);
          local_index = waw_count_hart[dut.crc_i.waw_cancel_hart[lane]];
          if (dut.crc_i.waw_cancel_hart[lane] == 1'b0) begin
            case (local_index)
              0: expected_sequence = 16'd18;
              1: expected_sequence = 16'd20;
              2: expected_sequence = 16'd26;
              3: expected_sequence = 16'd28;
              default: $fatal(1, "unexpected extra hart0 WAW");
            endcase
          end else begin
            expected_sequence = 16'd17 +
                                ((local_index >> 1) * 16'd8) +
                                ((local_index & 1) * 16'd2);
          end
          if (dut.crc_i.waw_cancel_sequence[lane] != expected_sequence)
            $fatal(1, "WAW hart=%0d index=%0d sequence=%0d expected=%0d",
                   dut.crc_i.waw_cancel_hart[lane], local_index,
                   dut.crc_i.waw_cancel_sequence[lane], expected_sequence);
          observed_hart[waw_count] = dut.crc_i.waw_cancel_hart[lane];
          observed_package[waw_count] = dut.crc_i.waw_cancel_package[lane];
          observed_sequence[waw_count] = dut.crc_i.waw_cancel_sequence[lane];
          waw_count_hart[dut.crc_i.waw_cancel_hart[lane]] =
            waw_count_hart[dut.crc_i.waw_cancel_hart[lane]] + 1;
          $display("WAW_EXPORT index=%0d slot=%0d hart=%0d package=%0d sequence=%0d time=%0t",
                   waw_count, lane, dut.crc_i.waw_cancel_hart[lane],
                   dut.crc_i.waw_cancel_package[lane],
                   dut.crc_i.waw_cancel_sequence[lane], $time);
          waw_count = waw_count + 1;
        end
      end
    end
  end

  initial begin
    waw_count = 0;
    waw_count_hart[0] = 0;
    waw_count_hart[1] = 0;
    repeat (12) @(posedge core_clk);
    infra_rst_l = 1'b1;
    wait (core_rst_l);
    fork
      begin
        wait (commit_count[1] >= 32'd600);
      end
      begin
        repeat (2_000_000) @(posedge core_clk);
        $fatal(1, "timeout commit=%0d/%0d WAW=%0d",
               commit_count[0], commit_count[1], waw_count);
      end
    join_any
    disable fork;
    repeat (20) @(posedge core_clk);
    if ((waw_count != 132) || (waw_count_hart[0] != 4) ||
        (waw_count_hart[1] != 128))
      $fatal(1, "WAW count=%0d hart0=%0d hart1=%0d expected=132/4/128",
             waw_count, waw_count_hart[0], waw_count_hart[1]);
    $display("TB_PASS WAW export count=%0d hart0=%0d hart1=%0d",
             waw_count, waw_count_hart[0], waw_count_hart[1]);
    $finish;
  end
endmodule
