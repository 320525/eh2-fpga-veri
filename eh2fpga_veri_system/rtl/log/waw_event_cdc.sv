`timescale 1ns/1ps

// One asynchronous FIFO per EH2 cancel lane preserves two simultaneous WAW
// events while crossing from the 50 MHz core clock to the 100 MHz log store.
module waw_event_cdc (
  input  logic src_clk,
  input  logic dst_clk,
  input  logic resetn,
  input  logic [1:0]       src_valid,
  input  logic [1:0]       src_hart,
  input  logic [1:0][15:0] src_package,
  input  logic [1:0][15:0] src_sequence,
  output logic [1:0]       src_overflow_hart,
  output logic [1:0]       dst_valid,
  output logic [1:0]       dst_hart,
  output logic [1:0][15:0] dst_package,
  output logic [1:0][15:0] dst_sequence
);
  logic [1:0][32:0] fifo_din, fifo_dout;
  logic [1:0] fifo_full, fifo_empty;

  generate
    for (genvar lane = 0; lane < 2; lane = lane + 1) begin : g_lane
      assign fifo_din[lane] = {
        src_hart[lane],src_package[lane],src_sequence[lane]
      };
      assign dst_valid[lane] = !fifo_empty[lane];
      assign {
        dst_hart[lane],dst_package[lane],dst_sequence[lane]
      } = fifo_dout[lane];

      xpm_fifo_async #(
        .CDC_SYNC_STAGES(2),
        .DOUT_RESET_VALUE("0"),
        .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("distributed"),
        .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(16),
        .FULL_RESET_VALUE(0),
        .READ_DATA_WIDTH(33),
        .READ_MODE("fwft"),
        .RELATED_CLOCKS(0),
        .USE_ADV_FEATURES("0000"),
        .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(33)
      ) fifo_i (
        .rst(!resetn),
        .wr_clk(src_clk), .wr_en(src_valid[lane] && !fifo_full[lane]),
        .din(fifo_din[lane]), .full(fifo_full[lane]),
        .overflow(), .wr_ack(), .almost_full(), .prog_full(),
        .wr_data_count(), .wr_rst_busy(),
        .rd_clk(dst_clk), .rd_en(!fifo_empty[lane]),
        .dout(fifo_dout[lane]), .empty(fifo_empty[lane]),
        .underflow(), .data_valid(), .almost_empty(), .prog_empty(),
        .rd_data_count(), .rd_rst_busy(),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0),
        .sbiterr(), .dbiterr()
      );
    end
  endgenerate

  always_ff @(posedge src_clk or negedge resetn) begin
    if (!resetn) begin
      src_overflow_hart <= 2'b0;
    end else begin
      for (integer lane = 0; lane < 2; lane = lane + 1)
        if (src_valid[lane] && fifo_full[lane])
          src_overflow_hart[src_hart[lane]] <= 1'b1;
    end
  end
endmodule

