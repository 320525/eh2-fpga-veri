`timescale 1ns/1ps

// Four independent mailbox handshakes carry the wide reduction records from
// the 125 MHz CRC domain into the 100 MHz system/log packetizer domain.
module log_result_cdc (
  input  logic src_clk,
  input  logic dst_clk,
  input  logic resetn,

  input  logic [1:0][1:0]       src_valid,
  input  logic [1:0][1:0][15:0] src_package,
  input  logic [1:0][1:0][63:0] src_xor0,
  input  logic [1:0][1:0][63:0] src_xor1,
  input  logic [1:0][1:0][63:0] src_sum0,
  input  logic [1:0][1:0][63:0] src_sum1,
  input  logic [1:0][1:0][63:0] src_sum2,
  input  logic [1:0][1:0][63:0] src_sum3,
  input  logic [1:0][1:0][31:0] src_count,
  output logic                   src_overflow,

  output logic [1:0][1:0]       dst_valid,
  output logic [1:0][1:0][15:0] dst_package,
  output logic [1:0][1:0][63:0] dst_xor0,
  output logic [1:0][1:0][63:0] dst_xor1,
  output logic [1:0][1:0][63:0] dst_sum0,
  output logic [1:0][1:0][63:0] dst_sum1,
  output logic [1:0][1:0][63:0] dst_sum2,
  output logic [1:0][1:0][63:0] dst_sum3,
  output logic [1:0][1:0][31:0] dst_count
);
  localparam integer RECORD_W = 16 + 6*64 + 32;
  logic [1:0][1:0][RECORD_W-1:0] holding;
  logic [1:0][1:0] req_toggle;
  logic [1:0][1:0] ack_toggle;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [1:0][1:0][1:0] req_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
  logic [1:0][1:0][1:0] ack_sync;

  always_ff @(posedge src_clk or negedge resetn) begin
    if (!resetn) begin
      holding      <= '0;
      req_toggle   <= '0;
      ack_sync     <= '0;
      src_overflow <= 1'b0;
    end else begin
      ack_sync[0][0] <= {ack_sync[0][0][0],ack_toggle[0][0]};
      ack_sync[0][1] <= {ack_sync[0][1][0],ack_toggle[0][1]};
      ack_sync[1][0] <= {ack_sync[1][0][0],ack_toggle[1][0]};
      ack_sync[1][1] <= {ack_sync[1][1][0],ack_toggle[1][1]};
      for (integer h = 0; h < 2; h = h + 1)
        for (integer b = 0; b < 2; b = b + 1)
          if (src_valid[h][b]) begin
            if (req_toggle[h][b] != ack_sync[h][b][1]) begin
              src_overflow <= 1'b1;
            end else begin
              holding[h][b] <= {
                src_package[h][b], src_xor0[h][b], src_xor1[h][b],
                src_sum0[h][b], src_sum1[h][b], src_sum2[h][b],
                src_sum3[h][b], src_count[h][b]
              };
              req_toggle[h][b] <= ~req_toggle[h][b];
            end
          end
    end
  end

  always_ff @(posedge dst_clk or negedge resetn) begin
    if (!resetn) begin
      req_sync   <= '0;
      ack_toggle <= '0;
      dst_valid  <= '0;
      dst_package <= '0;
      dst_xor0 <= '0; dst_xor1 <= '0;
      dst_sum0 <= '0; dst_sum1 <= '0; dst_sum2 <= '0; dst_sum3 <= '0;
      dst_count <= '0;
    end else begin
      dst_valid <= '0;
      req_sync[0][0] <= {req_sync[0][0][0],req_toggle[0][0]};
      req_sync[0][1] <= {req_sync[0][1][0],req_toggle[0][1]};
      req_sync[1][0] <= {req_sync[1][0][0],req_toggle[1][0]};
      req_sync[1][1] <= {req_sync[1][1][0],req_toggle[1][1]};
      for (integer h = 0; h < 2; h = h + 1)
        for (integer b = 0; b < 2; b = b + 1)
          if (req_sync[h][b][1] != ack_toggle[h][b]) begin
            {
              dst_package[h][b], dst_xor0[h][b], dst_xor1[h][b],
              dst_sum0[h][b], dst_sum1[h][b], dst_sum2[h][b],
              dst_sum3[h][b], dst_count[h][b]
            } <= holding[h][b];
            dst_valid[h][b] <= 1'b1;
            ack_toggle[h][b] <= req_sync[h][b][1];
          end
    end
  end
endmodule

