`timescale 1ns/1ps

// Per-hart, per-package-parity WAW sequence storage.  The reduction engine
// already prevents a package parity bank from being reused too early.  This
// companion store applies the same rule and raises a hard error rather than
// fragmenting the 1024-byte payload when more than 483 sequence numbers occur.
module waw_sequence_store #(
  parameter integer MAX_WAW = 483
) (
  input  logic clk,
  input  logic resetn,
  input  logic clear_all,

  input  logic [3:0]       event_valid,
  input  logic [3:0]       event_hart,
  input  logic [3:0][15:0] event_package,
  input  logic [3:0][15:0] event_sequence,

  input  logic              read_hart,
  input  logic              read_bank,
  input  logic [8:0]        read_index,
  input  logic [15:0]       read_package,
  output logic [15:0]       read_sequence,
  output logic [8:0]        read_count,
  output logic              read_package_match,

  input  logic [1:0][1:0]   clear_bank,
  output logic [1:0]        overflow_hart,
  output logic [1:0]        bank_conflict_hart
);
  logic [15:0] sequence_mem [0:1][0:1][0:MAX_WAW-1];
  logic [8:0] count [0:1][0:1];
  logic [15:0] bank_package [0:1][0:1];
  logic bank_valid [0:1][0:1];

  always_comb begin
    read_package_match = bank_valid[read_hart][read_bank] &&
                         (bank_package[read_hart][read_bank] == read_package);
    read_count = read_package_match ? count[read_hart][read_bank] : 9'd0;
    if (read_package_match && (read_index < count[read_hart][read_bank]))
      read_sequence = sequence_mem[read_hart][read_bank][read_index];
    else
      read_sequence = 16'b0;
  end

  always_ff @(posedge clk) begin
    if (!resetn || clear_all) begin
      overflow_hart      <= 2'b0;
      bank_conflict_hart <= 2'b0;
      for (integer h = 0; h < 2; h = h + 1)
        for (integer b = 0; b < 2; b = b + 1) begin
          count[h][b]        <= 9'd0;
          bank_package[h][b] <= 16'd0;
          bank_valid[h][b]   <= 1'b0;
        end
    end else begin
      for (integer h = 0; h < 2; h = h + 1)
        for (integer b = 0; b < 2; b = b + 1)
          if (clear_bank[h][b]) begin
            count[h][b]        <= 9'd0;
            bank_package[h][b] <= 16'd0;
            bank_valid[h][b]   <= 1'b0;
          end

      for (integer lane = 0; lane < 4; lane = lane + 1) begin
        if (event_valid[lane]) begin
          logic h;
          logic b;
          logic [2:0] prior_same_count;
          logic [2:0] total_same_count;
          logic [9:0] target_index;
          h = event_hart[lane];
          b = event_package[lane][0];
          prior_same_count = 3'd0;
          total_same_count = 3'd0;
          for (integer other = 0; other < 4; other = other + 1) begin
            if (event_valid[other] && (event_hart[other] == h) &&
                (event_package[other] == event_package[lane])) begin
              total_same_count = total_same_count + 3'd1;
              if (other < lane)
                prior_same_count = prior_same_count + 3'd1;
            end
          end
          target_index = count[h][b] + prior_same_count;

          if (bank_valid[h][b] &&
              (bank_package[h][b] != event_package[lane])) begin
            bank_conflict_hart[h] <= 1'b1;
          end else if (target_index >= MAX_WAW) begin
            overflow_hart[h] <= 1'b1;
          end else begin
            sequence_mem[h][b][target_index] <= event_sequence[lane];
            if (!bank_valid[h][b]) begin
              bank_valid[h][b]   <= 1'b1;
              bank_package[h][b] <= event_package[lane];
            end
            count[h][b] <= count[h][b] + total_same_count;
          end
        end
      end
    end
  end
endmodule
