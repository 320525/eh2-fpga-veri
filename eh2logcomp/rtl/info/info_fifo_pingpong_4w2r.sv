`timescale 1ns/1ps

// Per-hart 2048-record asynchronous information FIFO implemented as four
// ordered 512-record banks.  A write bank is frozen exactly when it reaches
// BANK_RECORDS records; writing then moves to the next free bank.  The read
// side claims one frozen bank at a time and releases it only after the DDR
// writer has received the AXI B response for the complete bank.
//
// A bank is never cleared at DMA start.  That would race the asynchronous
// FIFO read path and lose the data that DMA is about to write.  Instead the
// READY request is consumed at claim, the bank is held DMA_OWNED, and the
// release event clears the producer-side ownership only after DMA completion.
module info_fifo_pingpong_4w2r #(
    parameter integer RECORD_DEPTH = 2048,
    parameter integer BANK_COUNT   = 4,
    parameter integer BANK_RECORDS = RECORD_DEPTH / BANK_COUNT
) (
    input  logic                        wr_clk,
    input  logic                        rd_clk,
    input  logic                        rst_l,
    input  logic [3:0]                  wr_valid,
    input  logic [3:0][255:0]           wr_data,
    output logic [3:0]                  wr_ready,
    output logic                        wr_overflow,
    output logic                        wr_init_done,
    output logic [$clog2(RECORD_DEPTH+1)-1:0] wr_occupancy,

    // Held after the processor has stopped.  A non-full current bank is then
    // frozen and transferred with its exact valid record count.
    input  logic                        wr_flush,

    // One complete bank request.  batch_claim consumes the visible request;
    // the selected bank remains DMA-owned until batch_done.
    output logic                        batch_valid,
    output logic [$clog2(BANK_RECORDS+1)-1:0] batch_record_count,
    input  logic                        batch_claim,
    input  logic                        batch_done,

    output logic                        rd_valid,
    output logic [511:0]                rd_data,
    output logic [1:0]                  rd_record_count,
    input  logic                        rd_ready,
    output logic                        all_empty
);
    localparam integer BANK_INDEX_WIDTH = $clog2(BANK_COUNT);
    localparam integer BANK_COUNT_WIDTH = $clog2(BANK_RECORDS+1);

    initial begin
      if ((BANK_COUNT != 4) || (BANK_RECORDS != 512) ||
          (RECORD_DEPTH != 2048))
        $error("info_fifo_pingpong_4w2r is fixed at four 512-record banks");
    end

    logic [BANK_COUNT-1:0][3:0]          bank_wr_valid;
    logic [BANK_COUNT-1:0][3:0][255:0]   bank_wr_data;
    logic [BANK_COUNT-1:0][3:0]          bank_wr_ready;
    logic [BANK_COUNT-1:0]               bank_wr_overflow;
    logic [BANK_COUNT-1:0]               bank_wr_init_done;
    logic [BANK_COUNT-1:0][BANK_COUNT_WIDTH-1:0] bank_wr_occupancy;

    logic [BANK_COUNT-1:0]               bank_rd_valid;
    logic [BANK_COUNT-1:0][511:0]        bank_rd_data;
    logic [BANK_COUNT-1:0][1:0]          bank_rd_record_count;
    logic [BANK_COUNT-1:0]               bank_rd_ready;
    logic [BANK_COUNT-1:0]               bank_rd_empty;
    logic [BANK_COUNT-1:0][BANK_COUNT_WIDTH-1:0] bank_rd_occupancy;

    // Producer-side ownership: set when a bank becomes full (or is flushed
    // at end of execution); cleared only by the UI-domain DMA-complete event.
    logic [BANK_COUNT-1:0] bank_owned_core;
    logic [BANK_COUNT-1:0] bank_ready_core;
    logic [BANK_COUNT-1:0][BANK_COUNT_WIDTH-1:0] bank_record_count_core;
    logic [BANK_INDEX_WIDTH-1:0] wr_bank;
    logic                        wr_bank_valid;
    logic [BANK_COUNT-1:0]       release_ui;
    logic [BANK_COUNT-1:0]       release_core;

    // UI-side request and ownership state.  completed_ui suppresses a stale
    // synchronized READY level until the producer has observed the release.
    logic [BANK_COUNT-1:0] bank_ready_ui;
    logic [BANK_COUNT-1:0] completed_ui;
    logic [BANK_INDEX_WIDTH-1:0] rd_bank;
    logic                        rd_bank_active;
    logic                        rd_bank_claimed;
    logic [BANK_INDEX_WIDTH-1:0] rd_bank_pointer;
    logic [BANK_COUNT_WIDTH-1:0] rd_count_sample;
    logic [5:0]                  rd_count_stable_cycles;
    // A bank-local child already registers its lane-selected 512-bit beat.
    // This second register boundary captures the selected bank before the
    // stream leaves the four-bank wrapper, so neither the four-bank mux nor
    // downstream DMA backpressure shares a 266.5 MHz cycle with BRAM data.
    logic [511:0]                rd_output_front_data;
    logic [511:0]                rd_output_back_data;
    logic [1:0]                  rd_output_front_count;
    logic [1:0]                  rd_output_back_count;
    logic [1:0]                  rd_output_entry_count;
    logic                        rd_output_push;
    logic                        rd_output_pop;
    // wr_flush is generated in the 50 MHz EH2/capture domain.  It may become
    // high one core clock before this wrapper actually freezes its partial
    // tail bank.  Therefore the UI side must wait for an acknowledgement
    // generated by the write-side state update, not merely synchronize the
    // request itself; otherwise a 1/2-record session can transiently look
    // empty and make the DMA assert all_writes_done too early.
    logic                        flush_ack_core;
    logic                        flush_ack_ui;
    logic [2:0]                  flush_guard;

    // The global reset may assert at any time, but its release is synchronous
    // in each local clock domain.  This prevents the producer and UI-domain
    // ownership state from leaving reset on different physical clock edges.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [2:0] wr_reset_pipe;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [2:0] rd_reset_pipe;
    wire wr_resetn_local = wr_reset_pipe[2];
    wire rd_resetn_local = rd_reset_pipe[2];

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

    // Combinational producer routing.  The current write bank can fill in
    // the middle of a four-record core-clock bundle; remaining records are
    // then placed in the next free bank in the same clock, preserving order.
    integer local_slot;
    integer active_bank_i;
    integer next_bank_i;
    integer recovery_bank_i;
    integer ui_candidate_i;
    integer planned_count [0:BANK_COUNT-1];
    integer write_slots [0:BANK_COUNT-1];
    logic [BANK_COUNT-1:0] planned_owned;
    logic                  routing_blocked;
    logic                  all_bank_init;

    always_comb begin
      all_bank_init = &bank_wr_init_done;
      bank_wr_valid = '0;
      bank_wr_data = '0;
      wr_ready = '0;
      planned_owned = bank_owned_core;
      for (int bank = 0; bank < BANK_COUNT; bank = bank + 1) begin
        planned_count[bank] = bank_record_count_core[bank];
        write_slots[bank] = 0;
      end
      active_bank_i = wr_bank;
      routing_blocked = !wr_bank_valid || !all_bank_init;
      recovery_bank_i = -1;
      for (int bank = 0; bank < BANK_COUNT; bank = bank + 1) begin
        if ((recovery_bank_i < 0) && !bank_owned_core[bank] &&
            (bank_record_count_core[bank] == 0))
          recovery_bank_i = bank;
      end

      for (int slot = 0; slot < 4; slot = slot + 1) begin
        if (wr_valid[slot] && !routing_blocked) begin
          if (planned_owned[active_bank_i] ||
              (planned_count[active_bank_i] >= BANK_RECORDS) ||
              (write_slots[active_bank_i] >= 4)) begin
            routing_blocked = 1'b1;
          end else begin
            local_slot = write_slots[active_bank_i];
            bank_wr_valid[active_bank_i][local_slot] = 1'b1;
            bank_wr_data[active_bank_i][local_slot] = wr_data[slot];
            // Logical bank ownership prevents a write past BANK_RECORDS, so
            // after all XPM write-side reset-busy flags have cleared this
            // transfer is guaranteed to target a non-full physical lane.
            // The child FIFO still latches any unexpected physical overflow.
            wr_ready[slot] = 1'b1;
            write_slots[active_bank_i] = write_slots[active_bank_i] + 1;
            planned_count[active_bank_i] = planned_count[active_bank_i] + 1;
            if (planned_count[active_bank_i] == BANK_RECORDS) begin
              planned_owned[active_bank_i] = 1'b1;
              next_bank_i = -1;
              for (int candidate = 1; candidate <= BANK_COUNT;
                   candidate = candidate + 1) begin
                if ((next_bank_i < 0) &&
                    !planned_owned[(active_bank_i + candidate) % BANK_COUNT] &&
                    (planned_count[(active_bank_i + candidate) % BANK_COUNT] == 0))
                  next_bank_i = (active_bank_i + candidate) % BANK_COUNT;
              end
              if (next_bank_i < 0)
                routing_blocked = 1'b1;
              else
                active_bank_i = next_bank_i;
            end
          end
        end
      end
    end

    for (genvar g = 0; g < BANK_COUNT; g = g + 1) begin : g_bank
      info_fifo_async_4w2r #(.RECORD_DEPTH(BANK_RECORDS)) bank_fifo_i (
        .wr_clk, .rd_clk, .rst_l,
        .wr_valid(bank_wr_valid[g]), .wr_data(bank_wr_data[g]),
        .wr_ready(bank_wr_ready[g]), .wr_overflow(bank_wr_overflow[g]),
        .wr_init_done(bank_wr_init_done[g]),
        .wr_occupancy(bank_wr_occupancy[g]), .wr_flush,
        .rd_valid(bank_rd_valid[g]), .rd_data(bank_rd_data[g]),
        .rd_record_count(bank_rd_record_count[g]),
        .rd_ready(bank_rd_ready[g]), .rd_empty(bank_rd_empty[g]),
        .rd_occupancy(bank_rd_occupancy[g])
      );

      sync_bits #(.WIDTH(1), .STAGES(3)) ready_to_ui_i (
        .clk(rd_clk), .resetn(rd_resetn_local),
        .async_in(bank_ready_core[g]), .sync_out(bank_ready_ui[g])
      );
      event_toggle_cdc release_to_core_i (
        .src_clk(rd_clk), .dst_clk(wr_clk), .resetn(rst_l),
        .src_event(release_ui[g]), .dst_pulse(release_core[g])
      );
    end

    sync_bits #(.WIDTH(1), .STAGES(3)) flush_ack_to_ui_i (
      .clk(rd_clk), .resetn(rd_resetn_local),
      .async_in(flush_ack_core), .sync_out(flush_ack_ui)
    );

    always_ff @(posedge wr_clk or negedge wr_resetn_local) begin
      if (!wr_resetn_local) begin
        bank_owned_core <= '0;
        bank_ready_core <= '0;
        bank_record_count_core <= '0;
        wr_bank <= '0;
        wr_bank_valid <= 1'b1;
        wr_overflow <= 1'b0;
        flush_ack_core <= 1'b0;
      end else begin
        if (|bank_wr_overflow)
          wr_overflow <= 1'b1;

        // A release can arrive on the same edge that the current bank becomes
        // full.  In that case the old selector logic misses the newly free
        // bank because every nonblocking condition observes pre-edge state.
        // Recover from any invalid selector by scanning registered ownership;
        // the upstream elastic queue safely holds its bundle during this one
        // core-clock recovery bubble.
        if (!wr_bank_valid && (recovery_bank_i >= 0)) begin
          wr_bank <= recovery_bank_i[BANK_INDEX_WIDTH-1:0];
          wr_bank_valid <= 1'b1;
        end

        // A release wins over the stale READY level and returns that bank to
        // the producer only after its complete DDR transaction has finished.
        for (int bank = 0; bank < BANK_COUNT; bank = bank + 1) begin
          if (release_core[bank]) begin
            bank_owned_core[bank] <= 1'b0;
            bank_ready_core[bank] <= 1'b0;
            bank_record_count_core[bank] <= '0;
            if (!wr_bank_valid) begin
              wr_bank <= bank[BANK_INDEX_WIDTH-1:0];
              wr_bank_valid <= 1'b1;
            end
          end
        end

        for (int bank = 0; bank < BANK_COUNT; bank = bank + 1) begin
          if (write_slots[bank] != 0) begin
            bank_record_count_core[bank] <=
              bank_record_count_core[bank] + write_slots[bank];
            if ((bank_record_count_core[bank] + write_slots[bank]) ==
                BANK_RECORDS) begin
              bank_owned_core[bank] <= 1'b1;
              bank_ready_core[bank] <= 1'b1;
            end
          end
        end

        // active_bank_i is the bank that would receive the next record after
        // this four-record bundle.  It is valid exactly when a free bank was
        // found by the routing loop.
        if (|wr_ready) begin
          wr_bank <= active_bank_i[BANK_INDEX_WIDTH-1:0];
          wr_bank_valid <= !planned_owned[active_bank_i];
        end

        // The stop/flush event turns a partially filled current bank into a
        // final DMA batch.  No tail record is discarded; the child FIFO emits
        // an odd final record as a padded 512-bit beat when necessary.
        if (wr_flush && wr_bank_valid &&
            ((bank_record_count_core[wr_bank] + write_slots[wr_bank]) != 0) &&
            !bank_owned_core[wr_bank]) begin
          bank_owned_core[wr_bank] <= 1'b1;
          bank_ready_core[wr_bank] <= 1'b1;
          wr_bank_valid <= 1'b0;
        end

        // This acknowledgement is asserted in the same write-clock edge that
        // processes the flush above.  ready/count and acknowledgement then
        // traverse identical three-stage synchronizers, guaranteeing that the
        // UI empty guard cannot get ahead of a newly frozen partial bank.
        if (wr_flush)
          flush_ack_core <= 1'b1;

        // valid && !ready is ordinary ready/valid backpressure.  The upstream
        // 16-entry elastic queue retains the records, so it is not data loss
        // and must not be promoted to the fatal physical-overflow flag.
      end
    end

    always_comb begin
      wr_occupancy = '0;
      for (int bank = 0; bank < BANK_COUNT; bank = bank + 1)
        wr_occupancy = wr_occupancy + bank_record_count_core[bank];
      wr_init_done = all_bank_init;

      batch_valid = 1'b0;
      batch_record_count = '0;
      rd_valid = (rd_output_entry_count != 0);
      // The DMA sees a direct register-Q path.  Avoiding a pointer-selected
      // 512-bit mux here is important on the 266.5 MHz DDR1 UI clock.
      rd_data = rd_output_front_data;
      rd_record_count = rd_output_front_count;
      rd_output_pop = rd_valid && rd_ready;
      bank_rd_ready = '0;
      rd_output_push = 1'b0;
      if (rd_bank_active) begin
        // XPM produces rd_data_count from its Gray-synchronized pointers.
        // Do not transfer the producer's changing binary count as a separate
        // multi-bit CDC bus.  Once READY is visible no further writes may
        // enter this bank.  XPM's data-count path may use a deeper pointer
        // synchronizer than its full/empty flags.  The lane reset replicas
        // add another local release stage, so require thirty-two stable UI
        // samples before DMA can claim the batch.  Any count movement
        // restarts this guard below.
        batch_record_count = rd_count_sample;
        batch_valid = !rd_bank_claimed &&
                      (rd_count_stable_cycles == 6'd32) &&
                      (batch_record_count != 0);
        if (rd_bank_claimed && (rd_output_entry_count != 2)) begin
          // A two-entry local queue absorbs the cycle in which an older beat
          // is consumed.  Downstream ready never feeds combinationally into
          // the selected XPM bank, while the bank's native two-cycle cadence
          // remains sustainable without an extra wrapper bubble.
          bank_rd_ready[rd_bank] = 1'b1;
          rd_output_push = bank_rd_valid[rd_bank];
        end
      end
      // Seven UI clocks after the write-domain flush acknowledgement leave
      // more than two complete synchronizer pipelines for the final READY and
      // XPM read-count state to become visible before empty is permitted.
      all_empty = (flush_guard == 3'd7) && !rd_bank_active &&
                  !(|bank_ready_ui) && (rd_output_entry_count == 0);
    end

    // Two-entry selected-bank stream queue.  It is implemented as fixed
    // front/back registers instead of a circular array so the downstream DMA
    // never traverses a 512-bit pointer mux.  Payload registers have no reset
    // requirement; the entry count is the sole qualifier.
    // Payload is qualified exclusively by rd_output_entry_count and therefore
    // needs no reset.  Keeping it in a reset-free process avoids mapping a
    // reset/set network onto 1028 wide data bits in the DDR1 clock region.
    always_ff @(posedge rd_clk) begin
      if (rd_resetn_local) begin
        case ({rd_output_push,rd_output_pop})
          2'b10: begin
            if (rd_output_entry_count == 0) begin
              rd_output_front_data <= bank_rd_data[rd_bank];
              rd_output_front_count <= bank_rd_record_count[rd_bank];
            end else begin
              rd_output_back_data <= bank_rd_data[rd_bank];
              rd_output_back_count <= bank_rd_record_count[rd_bank];
            end
          end
          2'b01: begin
            if (rd_output_entry_count == 2) begin
              rd_output_front_data <= rd_output_back_data;
              rd_output_front_count <= rd_output_back_count;
            end
          end
          2'b11: begin
            if (rd_output_entry_count == 2) begin
              rd_output_front_data <= rd_output_back_data;
              rd_output_front_count <= rd_output_back_count;
              rd_output_back_data <= bank_rd_data[rd_bank];
              rd_output_back_count <= bank_rd_record_count[rd_bank];
            end else begin
              rd_output_front_data <= bank_rd_data[rd_bank];
              rd_output_front_count <= bank_rd_record_count[rd_bank];
            end
          end
          default: begin
          end
        endcase
      end
    end

    // Only the two-bit qualifier is reset.  This is the sole state that can
    // make either payload register visible to the DMA.
    always_ff @(posedge rd_clk or negedge rd_resetn_local) begin
      if (!rd_resetn_local)
        rd_output_entry_count <= 2'd0;
      else begin
        case ({rd_output_push,rd_output_pop})
          2'b10: rd_output_entry_count <= rd_output_entry_count + 1'b1;
          2'b01: rd_output_entry_count <= rd_output_entry_count - 1'b1;
          default: rd_output_entry_count <= rd_output_entry_count;
        endcase
      end
    end

    always_ff @(posedge rd_clk or negedge rd_resetn_local) begin
      if (!rd_resetn_local) begin
        completed_ui <= '0;
        rd_bank <= '0;
        rd_bank_active <= 1'b0;
        rd_bank_claimed <= 1'b0;
        rd_bank_pointer <= '0;
        release_ui <= '0;
        flush_guard <= '0;
        rd_count_sample <= '0;
        rd_count_stable_cycles <= '0;
      end else begin
        release_ui <= '0;
        if (flush_ack_ui && (flush_guard != 3'd7))
          flush_guard <= flush_guard + 1'b1;

        for (int bank = 0; bank < BANK_COUNT; bank = bank + 1)
          if (!bank_ready_ui[bank])
            completed_ui[bank] <= 1'b0;

        if (!rd_bank_active) begin
          // Descend so the last nonblocking assignment is the first ready
          // bank in circular FIFO order from rd_bank_pointer.
          for (int bank = BANK_COUNT-1; bank >= 0; bank = bank - 1) begin
            ui_candidate_i = (rd_bank_pointer + bank) % BANK_COUNT;
            if (bank_ready_ui[ui_candidate_i] &&
                !completed_ui[ui_candidate_i]) begin
              rd_bank <= ui_candidate_i[BANK_INDEX_WIDTH-1:0];
              rd_bank_active <= 1'b1;
              rd_bank_claimed <= 1'b0;
              rd_count_sample <= '0;
              rd_count_stable_cycles <= '0;
            end
          end
        end else if (!rd_bank_claimed) begin
          if (!bank_ready_ui[rd_bank] ||
              (bank_rd_occupancy[rd_bank] == 0)) begin
            rd_count_sample <= bank_rd_occupancy[rd_bank];
            rd_count_stable_cycles <= '0;
          end else if (bank_rd_occupancy[rd_bank] != rd_count_sample) begin
            rd_count_sample <= bank_rd_occupancy[rd_bank];
            rd_count_stable_cycles <= '0;
          end else if (rd_count_stable_cycles != 6'd32) begin
            rd_count_stable_cycles <= rd_count_stable_cycles + 1'b1;
          end
          if (batch_valid && batch_claim)
            rd_bank_claimed <= 1'b1;
        end else if (rd_bank_claimed && batch_done) begin
          release_ui[rd_bank] <= 1'b1;
          completed_ui[rd_bank] <= 1'b1;
          rd_bank_pointer <= rd_bank + 1'b1;
          rd_bank_active <= 1'b0;
          rd_bank_claimed <= 1'b0;
          rd_count_sample <= '0;
          rd_count_stable_cycles <= '0;
        end
      end
    end
endmodule
