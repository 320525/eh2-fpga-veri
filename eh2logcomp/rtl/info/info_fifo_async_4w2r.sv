// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// One logical record FIFO with four 256-bit write ports and one 512-bit read
// port.  Records are striped over four FWFT XPM FIFOs.  The read pointer always
// consumes the next two lanes in sequence, preserving commit order while
// meeting the four-record-per-core-cycle input requirement.
module info_fifo_async_4w2r #(
    parameter integer RECORD_DEPTH = 1024
) (
    input  logic                     wr_clk,
    input  logic                     rd_clk,
    input  logic                     rst_l,
    input  logic [3:0]               wr_valid,
    input  logic [3:0][255:0]        wr_data,
    output logic [3:0]               wr_ready,
    output logic                     wr_overflow,
    output logic                     wr_init_done,
    output logic [$clog2(RECORD_DEPTH+1)-1:0] wr_occupancy,

    // Hold flush high after EH2 has stopped.  It permits the final odd record
    // to be emitted as a half-full beat with rd_record_count == 1.
    input  logic                     wr_flush,
    output logic                     rd_valid,
    output logic [511:0]             rd_data,
    output logic [1:0]               rd_record_count,
    input  logic                     rd_ready,
    output logic                     rd_empty,
    output logic [$clog2(RECORD_DEPTH+1)-1:0] rd_occupancy
);
    localparam integer LANE_DEPTH = RECORD_DEPTH / 4;
    localparam integer LANE_COUNT_WIDTH = $clog2(LANE_DEPTH + 1);
    localparam integer TOTAL_COUNT_WIDTH = $clog2(RECORD_DEPTH + 1);

    initial begin
      if ((RECORD_DEPTH < 64) || ((RECORD_DEPTH & (RECORD_DEPTH-1)) != 0))
        $error("RECORD_DEPTH must be a power of two and at least 64");
      if ((RECORD_DEPTH % 4) != 0)
        $error("RECORD_DEPTH must be divisible by four");
    end

    logic [1:0] wr_pointer;
    // One-hot form of the next read lane.  Keeping the lane selection already
    // decoded avoids putting a binary-pointer decoder in front of every XPM
    // BRAM read enable at 266.5 MHz.
    logic [3:0] rd_lane_select;
    logic [3:0] lane_wr_en;
    logic [3:0][255:0] lane_din;
    logic [3:0] lane_full;
    logic [3:0] lane_overflow;
    logic [3:0] lane_wr_rst_busy;
    logic [3:0][LANE_COUNT_WIDTH-1:0] lane_wr_count;
    logic [3:0] lane_rd_en;
    logic [3:0][255:0] lane_dout;
    logic [3:0] lane_empty;
    logic [3:0] lane_underflow;
    logic [3:0] lane_rd_rst_busy;
    logic [3:0][LANE_COUNT_WIDTH-1:0] lane_rd_count;
    // XPM_FIFO_ASYNC requires rst to be synchronous to wr_clk.  Keep one
    // write-domain reset synchronizer per lane so the local reset fanout stays
    // small without launching a read-clock signal into XPM's write-reset FSM.
    (* DONT_TOUCH = "TRUE", KEEP = "TRUE", MAX_FANOUT = 1 *)
    logic [3:0] xpm_rst_lane;
    logic flush_rd;
    logic rd_init_done;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [2:0] wr_reset_pipe;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [2:0] rd_reset_pipe;
    wire wr_resetn_local = wr_reset_pipe[2];
    wire rd_resetn_local = rd_reset_pipe[2];

    integer slot;
    integer lane_index;
    integer accepted;
    integer wr_total;
    integer rd_total;
    logic write_blocked;
    logic tail_single_ready;
    logic head_valid;
    logic [511:0] head_data;
    logic [1:0] head_record_count;
    logic [3:0] head_lane_mask;
    logic output_valid_reg;
    logic [511:0] output_data_reg;
    logic [1:0] output_record_count_reg;
    logic pop_pending;
    logic [1:0] pop_record_count;

    // XPM owns the memory/pointer reset crossing.  These local pipes protect
    // the surrounding lane-selection state: reset asserts asynchronously but
    // is released only on a clock edge in the domain that consumes it.
    always_ff @(posedge wr_clk or negedge rst_l) begin
      if (!rst_l)
        wr_reset_pipe <= 3'b000;
      else
        wr_reset_pipe <= {wr_reset_pipe[1:0],1'b1};
    end
    always_ff @(posedge rd_clk or negedge rst_l) begin
      if (!rst_l)
        rd_reset_pipe <= 3'b000;
      else
        rd_reset_pipe <= {rd_reset_pipe[1:0],1'b1};
    end

    sync_bits #(.WIDTH(1), .STAGES(3)) flush_sync_i (
      .clk      (rd_clk),
      .resetn   (rd_resetn_local),
      .async_in (wr_flush),
      .sync_out (flush_rd)
    );

    always_comb begin
      lane_wr_en = '0;
      lane_din = '0;
      wr_ready = '0;
      accepted = 0;
      write_blocked = 1'b0;
      // wr_valid is compact: no valid slot may follow an invalid slot.
      for (slot = 0; slot < 4; slot = slot + 1) begin
        lane_index = (wr_pointer + accepted) & 3;
        if (wr_valid[slot]) begin
          wr_ready[slot] = !write_blocked && !lane_full[lane_index] &&
                           !lane_wr_rst_busy[lane_index];
          if (wr_ready[slot]) begin
            lane_wr_en[lane_index] = 1'b1;
            lane_din[lane_index] = wr_data[slot];
            accepted = accepted + 1;
          end else
            write_blocked = 1'b1;
        end
      end
    end

    always_ff @(posedge wr_clk or negedge wr_resetn_local) begin
      if (!wr_resetn_local) begin
        wr_pointer <= 2'b00;
        wr_overflow <= 1'b0;
      end else begin
        wr_pointer <= wr_pointer + accepted[1:0];
        // valid/ready backpressure is handled by the capture block.  Only an
        // actual write attempt reported by XPM is a physical FIFO overflow.
        if (|lane_overflow)
          wr_overflow <= 1'b1;
      end
    end

    always_comb begin
      wr_total = lane_wr_count[0] + lane_wr_count[1] +
                 lane_wr_count[2] + lane_wr_count[3];
      rd_total = lane_rd_count[0] + lane_rd_count[1] +
                 lane_rd_count[2] + lane_rd_count[3];
      wr_occupancy = wr_total[TOTAL_COUNT_WIDTH-1:0];
      wr_init_done = !(|lane_wr_rst_busy);
    end

    // Register the cross-lane total-count decision before it reaches any XPM
    // FIFO read enable.  The extra cycle is harmless after capture_done, while
    // preserving the strict guarantee that no later lane still owns a record.
    always_ff @(posedge rd_clk or negedge rd_resetn_local) begin
      if (!rd_resetn_local) begin
        tail_single_ready <= 1'b0;
        rd_init_done <= 1'b0;
        rd_occupancy <= '0;
        rd_empty <= 1'b1;
      end else begin
        tail_single_ready <= flush_rd && (rd_total == 1);
        rd_occupancy <= rd_total[TOTAL_COUNT_WIDTH-1:0];
        rd_empty <= (rd_total == 0);
        if (!(|lane_rd_rst_busy))
          rd_init_done <= 1'b1;
      end
    end

    // Decode the next one/two records, but do not let this combinational cone
    // reach an XPM BRAM enable.  The selected data is first captured in a
    // local 512-bit output register and the corresponding pop mask is then
    // driven by a dedicated register for one complete read-clock cycle.
    always_comb begin
      head_valid = 1'b0;
      head_data = '0;
      head_record_count = 2'd0;
      head_lane_mask = '0;

      case (rd_lane_select)
        4'b0001: begin
          if (rd_init_done && !lane_empty[0]) begin
            if (!lane_empty[1]) begin
              head_valid = 1'b1;
              head_record_count = 2'd2;
              head_data = {lane_dout[1], lane_dout[0]};
              head_lane_mask = 4'b0011;
            end else if (tail_single_ready) begin
              head_valid = 1'b1;
              head_record_count = 2'd1;
              head_data = {256'b0, lane_dout[0]};
              head_lane_mask = 4'b0001;
            end
          end
        end
        4'b0010: begin
          if (rd_init_done && !lane_empty[1]) begin
            if (!lane_empty[2]) begin
              head_valid = 1'b1;
              head_record_count = 2'd2;
              head_data = {lane_dout[2], lane_dout[1]};
              head_lane_mask = 4'b0110;
            end else if (tail_single_ready) begin
              head_valid = 1'b1;
              head_record_count = 2'd1;
              head_data = {256'b0, lane_dout[1]};
              head_lane_mask = 4'b0010;
            end
          end
        end
        4'b0100: begin
          if (rd_init_done && !lane_empty[2]) begin
            if (!lane_empty[3]) begin
              head_valid = 1'b1;
              head_record_count = 2'd2;
              head_data = {lane_dout[3], lane_dout[2]};
              head_lane_mask = 4'b1100;
            end else if (tail_single_ready) begin
              head_valid = 1'b1;
              head_record_count = 2'd1;
              head_data = {256'b0, lane_dout[2]};
              head_lane_mask = 4'b0100;
            end
          end
        end
        default: begin
          if (rd_init_done && !lane_empty[3]) begin
            if (!lane_empty[0]) begin
              head_valid = 1'b1;
              head_record_count = 2'd2;
              head_data = {lane_dout[0], lane_dout[3]};
              head_lane_mask = 4'b1001;
            end else if (tail_single_ready) begin
              head_valid = 1'b1;
              head_record_count = 2'd1;
              head_data = {256'b0, lane_dout[3]};
              head_lane_mask = 4'b1000;
            end
          end
        end
      endcase

      rd_valid = output_valid_reg;
      rd_data = output_data_reg;
      rd_record_count = output_record_count_reg;
    end

    always_ff @(posedge rd_clk or negedge rd_resetn_local) begin
      if (!rd_resetn_local) begin
        rd_lane_select <= 4'b0001;
        lane_rd_en <= '0;
        output_valid_reg <= 1'b0;
        output_data_reg <= '0;
        output_record_count_reg <= '0;
        pop_pending <= 1'b0;
        pop_record_count <= '0;
      end else begin
        // lane_rd_en was registered in the previous cycle and is consumed by
        // XPM on this edge.  Advance only after that physical pop occurs.
        lane_rd_en <= '0;
        if (output_valid_reg && rd_ready)
          output_valid_reg <= 1'b0;

        if (pop_pending) begin
          if (pop_record_count == 2)
            rd_lane_select <= {rd_lane_select[1:0], rd_lane_select[3:2]};
          else
            rd_lane_select <= {rd_lane_select[2:0], rd_lane_select[3]};
          pop_pending <= 1'b0;
        // rd_ready is also the bank-claim permission from the parent.  Do not
        // prefetch/pop any record while a producer-owned bank is merely being
        // filled; otherwise XPM's visible occupancy would be two records
        // smaller before the exact batch count is frozen.
        end else if (rd_ready && head_valid) begin
          output_valid_reg <= 1'b1;
          output_data_reg <= head_data;
          output_record_count_reg <= head_record_count;
          lane_rd_en <= head_lane_mask;
          pop_record_count <= head_record_count;
          pop_pending <= 1'b1;
        end
      end
    end

    genvar lane;
    generate
      for (lane = 0; lane < 4; lane = lane + 1) begin : g_lane
        xpm_cdc_sync_rst #(
          .DEST_SYNC_FF(4),
          .INIT(1),
          .INIT_SYNC_FF(1),
          .SIM_ASSERT_CHK(1)
        ) xpm_wr_reset_sync_i (
          .src_rst (~rst_l),
          .dest_clk(wr_clk),
          .dest_rst(xpm_rst_lane[lane])
        );

        xpm_fifo_async #(
          .CDC_SYNC_STAGES(3),
          .DOUT_RESET_VALUE("0"),
          .ECC_MODE("no_ecc"),
          .FIFO_MEMORY_TYPE("block"),
          .FIFO_READ_LATENCY(0),
          .FIFO_WRITE_DEPTH(LANE_DEPTH),
          .FULL_RESET_VALUE(0),
          .PROG_EMPTY_THRESH(8),
          .PROG_FULL_THRESH(LANE_DEPTH-8),
          .RD_DATA_COUNT_WIDTH(LANE_COUNT_WIDTH),
          .READ_DATA_WIDTH(256),
          .READ_MODE("fwft"),
          .RELATED_CLOCKS(0),
          .SIM_ASSERT_CHK(1),
          .USE_ADV_FEATURES("0707"),
          .WAKEUP_TIME(0),
          .WRITE_DATA_WIDTH(256),
          .WR_DATA_COUNT_WIDTH(LANE_COUNT_WIDTH)
        ) lane_fifo_i (
          .rst(xpm_rst_lane[lane]),
          .wr_clk(wr_clk),
          .wr_en(lane_wr_en[lane]),
          .din(lane_din[lane]),
          .full(lane_full[lane]),
          .overflow(lane_overflow[lane]),
          .wr_data_count(lane_wr_count[lane]),
          .wr_rst_busy(lane_wr_rst_busy[lane]),
          .wr_ack(), .almost_full(), .prog_full(),
          .rd_clk(rd_clk),
          .rd_en(lane_rd_en[lane]),
          .dout(lane_dout[lane]),
          .empty(lane_empty[lane]),
          .underflow(lane_underflow[lane]),
          .rd_data_count(lane_rd_count[lane]),
          .rd_rst_busy(lane_rd_rst_busy[lane]),
          .almost_empty(), .prog_empty(), .data_valid(),
          .sleep(1'b0),
          .injectsbiterr(1'b0), .injectdbiterr(1'b0),
          .sbiterr(), .dbiterr()
        );
      end
    endgenerate
endmodule
