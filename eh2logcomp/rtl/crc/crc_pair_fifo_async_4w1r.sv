// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// One logical 128 x 129-bit FIFO implemented as four independent 32-entry
// asynchronous XPM lanes. Consecutive writes are striped across the lanes, so
// up to four entries can be accepted on one 50 MHz write-clock edge. The read
// side emits at most one entry per 125 MHz cycle.
module crc_pair_fifo_async_4w1r (
    input  logic                 wr_clk,
    input  logic                 rd_clk,
    input  logic                 rst_l,
    input  logic [3:0]           wr_valid,
    input  logic [3:0][128:0]    wr_data,
    output logic [3:0]           wr_ready,
    output logic [7:0]           wr_free_count,
    output logic                 wr_overflow,
    output logic                 wr_init_done,

    output logic                 rd_valid,
    output logic [128:0]         rd_data,
    output logic [7:0]           rd_occupancy,
    output logic                 rd_empty
);
    logic [1:0] wr_round_robin;
    logic [1:0] rd_round_robin;

    logic [3:0] lane_wr_en;
    logic [3:0][128:0] lane_din;
    logic [3:0] lane_full;
    logic [3:0][5:0] lane_wr_count;
    logic [3:0] lane_wr_overflow;
    logic [3:0] lane_wr_rst_busy;

    logic [3:0] lane_rd_en;
    logic [3:0][128:0] lane_dout;
    logic [3:0] lane_empty;
    logic [3:0][5:0] lane_rd_count;
    logic [3:0] lane_rd_underflow;
    logic [3:0] lane_rd_rst_busy;

    integer write_slot;
    integer write_lane;
    integer read_offset;
    integer read_lane;
    integer selected_lane;
    integer write_accepted;
    integer wr_used_total;
    integer read_total;
    logic read_selected;

    always_comb begin
        lane_wr_en = 4'b0;
        lane_din = '0;
        wr_ready = 4'b0;
        write_accepted = 0;
        for (write_slot = 0; write_slot < 4; write_slot = write_slot + 1) begin
            write_lane = (wr_round_robin + write_slot) & 3;
            if (wr_valid[write_slot]) begin
                wr_ready[write_slot] = ~lane_full[write_lane] &
                                       ~lane_wr_rst_busy[write_lane];
                if (wr_ready[write_slot]) begin
                    lane_wr_en[write_lane] = 1'b1;
                    lane_din[write_lane] = wr_data[write_slot];
                    write_accepted = write_accepted + 1;
                end
            end else begin
                // Inputs are compacted; later slots are not used after a hole.
                wr_ready[write_slot] = 1'b0;
            end
        end
    end

    always_ff @(posedge wr_clk or negedge rst_l) begin
        if (!rst_l) begin
            wr_round_robin <= 2'b0;
            wr_overflow <= 1'b0;
        end else begin
            wr_round_robin <= wr_round_robin + write_accepted;
            wr_overflow <= |(wr_valid & ~wr_ready) | |lane_wr_overflow;
        end
    end

    always_comb begin
        read_total = lane_rd_count[0] + lane_rd_count[1] +
                     lane_rd_count[2] + lane_rd_count[3];
        rd_occupancy = read_total[7:0];
        rd_empty = (read_total == 0);
        lane_rd_en = 4'b0;
        rd_valid = 1'b0;
        rd_data = 129'b0;
        read_selected = 1'b0;
        selected_lane = 0;

        // A last entry is held until it is the only remaining entry in this
        // logical FIFO. This keeps package termination correct even though the
        // four physical lanes may be drained in a different order.
        for (read_offset = 0; read_offset < 4; read_offset = read_offset + 1) begin
            read_lane = (rd_round_robin + read_offset) & 3;
            if (!read_selected && !lane_empty[read_lane] &&
                !lane_rd_rst_busy[read_lane] &&
                (!lane_dout[read_lane][128] || (read_total == 1))) begin
                read_selected = 1'b1;
                selected_lane = read_lane;
                rd_valid = 1'b1;
                rd_data = lane_dout[read_lane];
                lane_rd_en[read_lane] = 1'b1;
            end
        end
    end

    always_ff @(posedge rd_clk or negedge rst_l) begin
        if (!rst_l)
            rd_round_robin <= 2'b0;
        else if (rd_valid)
            rd_round_robin <= (selected_lane + 1) & 3;
    end

    always_comb begin
        wr_used_total = lane_wr_count[0] + lane_wr_count[1] +
                        lane_wr_count[2] + lane_wr_count[3];
        wr_init_done = ~(|lane_wr_rst_busy);
        // Do not advertise storage while XPM is completing reset. The FPGA
        // top keeps EH2 in reset until all four logical FIFOs report ready.
        wr_free_count = wr_init_done ? (8'd128 - wr_used_total) : 8'd0;
    end

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_fifo_lane
            xpm_fifo_async #(
                .CDC_SYNC_STAGES      (3),
                .DOUT_RESET_VALUE     ("0"),
                .ECC_MODE             ("no_ecc"),
                .FIFO_MEMORY_TYPE     ("block"),
                .FIFO_READ_LATENCY    (0),
                .FIFO_WRITE_DEPTH     (32),
                .FULL_RESET_VALUE     (0),
                // These flags are not consumed, but XPM still validates the
                // thresholds when USE_ADV_FEATURES enables their ports.
                .PROG_EMPTY_THRESH    (8),
                .PROG_FULL_THRESH     (24),
                .RD_DATA_COUNT_WIDTH  (6),
                .READ_DATA_WIDTH      (129),
                .READ_MODE            ("fwft"),
                .RELATED_CLOCKS       (0),
                .SIM_ASSERT_CHK       (1),
                .USE_ADV_FEATURES     ("0707"),
                .WAKEUP_TIME          (0),
                .WRITE_DATA_WIDTH     (129),
                .WR_DATA_COUNT_WIDTH  (6)
            ) lane_fifo_i (
                .rst           (~rst_l),
                .wr_clk        (wr_clk),
                .wr_en         (lane_wr_en[lane]),
                .din           (lane_din[lane]),
                .full          (lane_full[lane]),
                .overflow      (lane_wr_overflow[lane]),
                .wr_data_count (lane_wr_count[lane]),
                .wr_rst_busy   (lane_wr_rst_busy[lane]),
                .almost_full   (),
                .prog_full     (),

                .rd_clk        (rd_clk),
                .rd_en         (lane_rd_en[lane]),
                .dout          (lane_dout[lane]),
                .empty         (lane_empty[lane]),
                .underflow     (lane_rd_underflow[lane]),
                .rd_data_count (lane_rd_count[lane]),
                .rd_rst_busy   (lane_rd_rst_busy[lane]),
                .almost_empty  (),
                .prog_empty    (),
                .data_valid    (),

                .sleep         (1'b0),
                .injectsbiterr (1'b0),
                .injectdbiterr (1'b0),
                .sbiterr       (),
                .dbiterr       ()
            );
        end
    endgenerate
endmodule
