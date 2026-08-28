// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// DDR1-to-Ethernet instruction-info dump path.
//
// Each data frame reserves one of two complete 1458-byte frame slots, reads a
// fixed 30 x 512-bit block from DDR1, removes the 64 reserved bits from each
// 256-bit DDR record, and atomically publishes 60 x 192-bit records.  The
// final data frame still reads 30 beats; records beyond the valid count are
// stored as zero.  Hart completion frames retain their separate 46-byte
// format and are sent only after all data slots for that hart are empty.
module info_log_dump_subsystem (
    input logic ui_clk,
    input logic tx_clk,
    input logic ui_resetn,
    input logic tx_resetn,
    // Common asynchronous assertion source for toggle-event CDC blocks;
    // those blocks synchronize release internally in both clock domains.
    input logic cdc_resetn,
    input logic start,
    input logic [31:0] h0_total_records,
    input logic [31:0] h1_total_records,
    axi4_if.master axi,
    output logic [7:0] tx_tdata,
    output logic tx_tvalid,
    output logic tx_tlast,
    input logic tx_tready,
    output logic frame_done_tx,
    output logic all_done_ui,
    output logic busy_ui,
    output logic error_ui,
    // Sticky, independently reportable causes.  The old board image folded
    // all four into C4, which made a captured C4 frame impossible to debug.
    // [0] AXI RRESP, [1] AXI RLAST/length, [2] frame builder, [3] release count.
    output logic [3:0] error_cause_ui
);
    localparam integer RECORDS_PER_FRAME = 60;

    typedef enum logic [3:0] {
      ST_IDLE,
      ST_H0_DATA, ST_H0_DRAIN, ST_H0_DONE_START, ST_H0_DONE_WAIT,
      ST_H1_DATA, ST_H1_DRAIN, ST_H1_DONE_START, ST_H1_DONE_WAIT,
      ST_DONE
    } state_t;
    state_t state;

    logic read_start, read_hart;
    logic [31:0] read_frame_number;
    logic [5:0] read_valid_records;
    logic read_busy, read_done, read_axi_error, read_protocol_error;
    logic dma_data_valid, dma_data_ready, dma_data_last;
    logic [511:0] dma_data;
    logic [4:0] dma_data_index;
    logic read_dma_data_valid, read_dma_data_ready, read_dma_data_last;
    logic [511:0] read_dma_data;
    logic [4:0] read_dma_data_index;

    logic build_start, build_hart, build_ready;
    logic [31:0] build_frame_number;
    logic [5:0] build_valid_records;
    logic frame_fifo_full_ui, frame_released_ui, frame_protocol_error_ui;
    logic [1:0] frame_dirty_ui, frame_valid_ui;
    logic frame_fifo_empty_tx;
    logic [0:0] frame_fifo_empty_ui;
    logic [2:0] frames_outstanding;
    // Retained as an internal diagnostic name for the existing verification
    // environment.  In the two-slot implementation an attempted overrun is
    // reported as a frame protocol error.
    logic data_overflow;
    logic [7:0] data_tx_tdata;
    logic data_tx_tvalid, data_tx_tlast, data_tx_tready;
    logic data_frame_done_tx;

    logic [31:0] records_remaining;
    logic [31:0] active_total;
    logic [5:0] active_frame_records;

    logic done_start_ui, done_start_tx;
    logic done_hart_ui;
    logic [31:0] done_total_ui;
    logic [0:0] done_hart_tx;
    logic [31:0] done_total_tx;
    logic [7:0] done_tx_tdata;
    logic done_tx_tvalid, done_tx_tlast, done_tx_tready;
    logic done_busy_tx, done_done_tx, done_done_ui;

    info_ddr_read_dma read_dma_i (
      .clk(ui_clk), .resetn(ui_resetn), .start(read_start), .hart(read_hart),
      .frame_number(read_frame_number), .valid_records(read_valid_records),
      .busy(read_busy), .done(read_done),
      .axi_error(read_axi_error), .protocol_error(read_protocol_error),
      .axi, .data_valid(read_dma_data_valid), .data(read_dma_data),
      .data_index(read_dma_data_index), .data_last(read_dma_data_last),
      .data_ready(read_dma_data_ready)
    );

    info_dma_data_elastic read_data_elastic_i (
      .clk(ui_clk), .resetn(ui_resetn),
      .in_valid(read_dma_data_valid), .in_data(read_dma_data),
      .in_index(read_dma_data_index), .in_last(read_dma_data_last),
      .in_ready(read_dma_data_ready),
      .out_valid(dma_data_valid), .out_data(dma_data),
      .out_index(dma_data_index), .out_last(dma_data_last),
      .out_ready(dma_data_ready)
    );

    info_tx_frame_fifo_2slot frame_fifo_i (
      .ui_clk, .tx_clk, .ui_resetn, .tx_resetn,
      .build_start, .build_hart, .build_frame_number,
      .build_valid_records, .build_ready,
      .dma_data_valid, .dma_data, .dma_data_index, .dma_data_last,
      .dma_data_ready,
      .full_ui(frame_fifo_full_ui), .dirty_ui(frame_dirty_ui),
      .valid_ui(frame_valid_ui), .frame_released_ui,
      .protocol_error_ui(frame_protocol_error_ui),
      .m_axis_tdata(data_tx_tdata), .m_axis_tvalid(data_tx_tvalid),
      .m_axis_tlast(data_tx_tlast), .m_axis_tready(data_tx_tready),
      .frame_done_tx(data_frame_done_tx), .empty_tx(frame_fifo_empty_tx)
    );

    sync_bits #(.WIDTH(1), .STAGES(3)) empty_sync_i (
      .clk(ui_clk), .resetn(ui_resetn),
      .async_in(frame_fifo_empty_tx), .sync_out(frame_fifo_empty_ui)
    );
    assign data_overflow = frame_protocol_error_ui;

    // Completion metadata is registered in the UI domain before the start
    // event crosses, then held unchanged until the completion event returns.
    event_toggle_cdc done_start_cdc_i (
      .src_clk(ui_clk), .dst_clk(tx_clk), .resetn(cdc_resetn),
      .src_event(done_start_ui), .dst_pulse(done_start_tx)
    );
    sync_bits #(.WIDTH(33), .STAGES(3)) done_metadata_sync_i (
      .clk(tx_clk), .resetn(tx_resetn),
      .async_in({done_hart_ui,done_total_ui}),
      .sync_out({done_hart_tx,done_total_tx})
    );

    info_log_done_formatter done_formatter_i (
      .clk(tx_clk), .resetn(tx_resetn), .start(done_start_tx),
      .hart(done_hart_tx[0]), .total_records(done_total_tx),
      .m_axis_tdata(done_tx_tdata), .m_axis_tvalid(done_tx_tvalid),
      .m_axis_tlast(done_tx_tlast), .m_axis_tready(done_tx_tready),
      .busy(done_busy_tx), .done(done_done_tx)
    );

    event_toggle_cdc done_complete_cdc_i (
      .src_clk(tx_clk), .dst_clk(ui_clk), .resetn(cdc_resetn),
      .src_event(done_done_tx), .dst_pulse(done_done_ui)
    );

    // Data slots and the completion formatter never overlap by construction.
    // Keeping this mux inside the log source preserves the top-level
    // frame-boundary arbiter between log traffic and unmodified system frames.
    always_comb begin
      if (done_busy_tx || done_tx_tvalid) begin
        tx_tdata = done_tx_tdata;
        tx_tvalid = done_tx_tvalid;
        tx_tlast = done_tx_tlast;
        done_tx_tready = tx_tready;
        data_tx_tready = 1'b0;
      end else begin
        tx_tdata = data_tx_tdata;
        tx_tvalid = data_tx_tvalid;
        tx_tlast = data_tx_tlast;
        done_tx_tready = 1'b0;
        data_tx_tready = tx_tready;
      end
    end
    assign frame_done_tx = tx_tvalid && tx_tready && tx_tlast;

    always_ff @(posedge ui_clk or negedge ui_resetn) begin
      if (!ui_resetn) begin
        state <= ST_IDLE;
        read_start <= 1'b0;
        read_hart <= 1'b0;
        read_frame_number <= 32'b0;
        read_valid_records <= 6'b0;
        build_start <= 1'b0;
        build_hart <= 1'b0;
        build_frame_number <= 32'b0;
        build_valid_records <= 6'b0;
        records_remaining <= 32'b0;
        active_total <= 32'b0;
        active_frame_records <= 6'b0;
        done_start_ui <= 1'b0;
        done_hart_ui <= 1'b0;
        done_total_ui <= 32'b0;
        all_done_ui <= 1'b0;
        busy_ui <= 1'b0;
        error_ui <= 1'b0;
        error_cause_ui <= 4'b0000;
        frames_outstanding <= 3'b0;
      end else begin
        read_start <= 1'b0;
        build_start <= 1'b0;
        done_start_ui <= 1'b0;

        if (read_axi_error) begin
          error_ui <= 1'b1;
          error_cause_ui[0] <= 1'b1;
        end
        if (read_protocol_error) begin
          error_ui <= 1'b1;
          error_cause_ui[1] <= 1'b1;
        end
        if (frame_protocol_error_ui) begin
          error_ui <= 1'b1;
          error_cause_ui[2] <= 1'b1;
        end

        // Count reservations in the UI domain and releases returned from the
        // TX domain.  This bundled-data acknowledgement is the authoritative
        // drain test; the synchronized TX empty indication is diagnostic only
        // because it can briefly retain its old value while a newly published
        // final frame is crossing clock domains.
        case ({build_start && build_ready, frame_released_ui})
          2'b10: frames_outstanding <= frames_outstanding + 3'd1;
          2'b01: begin
            if (frames_outstanding != 0)
              frames_outstanding <= frames_outstanding - 3'd1;
            else begin
              error_ui <= 1'b1;
              error_cause_ui[3] <= 1'b1;
            end
          end
          default: ;
        endcase

        case (state)
          ST_IDLE: if (start) begin
            all_done_ui <= 1'b0;
            busy_ui <= 1'b1;
            read_hart <= 1'b0;
            build_hart <= 1'b0;
            read_frame_number <= 32'b0;
            build_frame_number <= 32'b0;
            records_remaining <= h0_total_records;
            active_total <= h0_total_records;
            frames_outstanding <= 3'b0;
            state <= h0_total_records == 0 ? ST_H0_DRAIN : ST_H0_DATA;
          end

          ST_H0_DATA, ST_H1_DATA: begin
            // read_start/build_start are registered request pulses.  Do not
            // plan another frame while either pulse is being accepted by its
            // downstream block, and give read_done priority so the next
            // request uses the incremented frame number and remaining count.
            if (!read_done && !read_busy && !read_start && !build_start &&
                build_ready && !frame_fifo_full_ui &&
                records_remaining != 0) begin
              active_frame_records <=
                records_remaining >= RECORDS_PER_FRAME ?
                  RECORDS_PER_FRAME : records_remaining[5:0];
              build_valid_records <=
                records_remaining >= RECORDS_PER_FRAME ?
                  RECORDS_PER_FRAME : records_remaining[5:0];
              read_valid_records <=
                records_remaining >= RECORDS_PER_FRAME ?
                  RECORDS_PER_FRAME : records_remaining[5:0];
              build_frame_number <= read_frame_number;
              build_start <= 1'b1;
              read_start <= 1'b1;
            end

            if (read_done) begin
              read_frame_number <= read_frame_number + 32'd1;
              if (records_remaining <= active_frame_records) begin
                records_remaining <= 32'b0;
                state <= (state == ST_H0_DATA) ? ST_H0_DRAIN : ST_H1_DRAIN;
              end else begin
                records_remaining <= records_remaining - active_frame_records;
              end
            end
          end

          ST_H0_DRAIN: if (frames_outstanding == 0 && !read_busy) begin
            done_hart_ui <= 1'b0;
            done_total_ui <= active_total;
            state <= ST_H0_DONE_START;
          end
          ST_H0_DONE_START: begin
            done_start_ui <= 1'b1;
            state <= ST_H0_DONE_WAIT;
          end
          ST_H0_DONE_WAIT: if (done_done_ui) begin
            read_hart <= 1'b1;
            build_hart <= 1'b1;
            read_frame_number <= 32'b0;
            build_frame_number <= 32'b0;
            records_remaining <= h1_total_records;
            active_total <= h1_total_records;
            state <= h1_total_records == 0 ? ST_H1_DRAIN : ST_H1_DATA;
          end

          ST_H1_DRAIN: if (frames_outstanding == 0 && !read_busy) begin
            done_hart_ui <= 1'b1;
            done_total_ui <= active_total;
            state <= ST_H1_DONE_START;
          end
          ST_H1_DONE_START: begin
            done_start_ui <= 1'b1;
            state <= ST_H1_DONE_WAIT;
          end
          ST_H1_DONE_WAIT: if (done_done_ui)
            state <= ST_DONE;

          ST_DONE: begin
            all_done_ui <= 1'b1;
            busy_ui <= 1'b0;
            // DDR1 remains valid after END.  A host request therefore needs
            // no reset and no record regeneration: restart the same ordered
            // h0-then-h1 read sequence from byte zero of each region.  Clear
            // all_done before any new read so the controller can distinguish
            // this replay's completion from the prior dump's sticky level.
            if (start) begin
              all_done_ui <= 1'b0;
              busy_ui <= 1'b1;
              read_hart <= 1'b0;
              build_hart <= 1'b0;
              read_frame_number <= 32'b0;
              build_frame_number <= 32'b0;
              records_remaining <= h0_total_records;
              active_total <= h0_total_records;
              active_frame_records <= 6'b0;
              frames_outstanding <= 3'b0;
              state <= h0_total_records == 0 ? ST_H0_DRAIN : ST_H0_DATA;
            end
          end
          default: state <= ST_IDLE;
        endcase
      end
    end
endmodule
