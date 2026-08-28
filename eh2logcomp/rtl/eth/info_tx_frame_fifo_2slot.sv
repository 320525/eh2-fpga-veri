// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Two complete-frame slots for the DDR1 instruction-info transmit path.
//
// The UI-clock writer reserves a whole slot before the fixed 30-beat DMA is
// started.  A reserved slot is immediately counted as occupied (dirty), but
// is invisible to the transmit side until all 30 beats have been received.
// Publishing and releasing a slot use per-slot toggle handshakes, so the
// 384-bit payload words and header metadata are stable for several clocks
// before the opposite clock domain is allowed to use them.
module info_tx_frame_fifo_2slot #(
    parameter logic [47:0] DEST_MAC      = 48'hFFFF_FFFF_FFFF,
    parameter logic [47:0] HART0_MAC     = 48'h0232_0525_1000,
    parameter logic [47:0] HART1_MAC     = 48'h0232_0525_1001,
    parameter logic [15:0] DATA_ETHERTYPE = 16'h88B7
) (
    input  logic         ui_clk,
    input  logic         tx_clk,
    // Reset assertion is common, but release must already be synchronized
    // independently to each clock before it reaches these ports.
    input  logic         ui_resetn,
    input  logic         tx_resetn,

    input  logic         build_start,
    input  logic         build_hart,
    input  logic [31:0]  build_frame_number,
    input  logic [5:0]   build_valid_records,
    output logic         build_ready,

    input  logic         dma_data_valid,
    input  logic [511:0] dma_data,
    input  logic [4:0]   dma_data_index,
    input  logic         dma_data_last,
    output logic         dma_data_ready,

    output logic         full_ui,
    output logic [1:0]   dirty_ui,
    output logic [1:0]   valid_ui,
    output logic         frame_released_ui,
    output logic         protocol_error_ui,

    output logic [7:0]   m_axis_tdata,
    output logic         m_axis_tvalid,
    output logic         m_axis_tlast,
    input  logic         m_axis_tready,
    output logic         frame_done_tx,
    output logic         empty_tx
);
    localparam integer HEADER_BYTES = 14;
    localparam integer RECORD_BYTES = 24;
    localparam integer RECORDS_PER_FRAME = 60;
    localparam integer PAYLOAD_BYTES = 4 + RECORD_BYTES*RECORDS_PER_FRAME;
    localparam integer FRAME_BYTES = HEADER_BYTES + PAYLOAD_BYTES;

    // Each 384-bit word contains two 192-bit effective Info Structs.  Together
    // with the stored header and frame number this is one complete 1458-byte
    // Ethernet frame slot.  Invalid records in the last frame are stored as 0.
    logic [383:0] slot_payload [0:1][0:29];
    logic [111:0] slot_header [0:1];
    logic [31:0]  slot_frame_number [0:1];
    logic [5:0]   slot_valid_records [0:1];

    logic [1:0] occupied_ui;
    logic [1:0] publish_toggle_ui;
    logic [1:0] release_toggle_tx;
    logic [1:0] release_toggle_ui;
    logic [1:0] release_seen_ui;
    logic       write_slot;
    logic       build_active;
    logic [4:0] expected_dma_index;

    sync_bits #(.WIDTH(2), .STAGES(3)) release_sync_i (
      .clk(ui_clk), .resetn(ui_resetn),
      .async_in(release_toggle_tx), .sync_out(release_toggle_ui)
    );

    assign build_ready = !build_active && !occupied_ui[write_slot];
    assign dma_data_ready = build_active;
    assign full_ui = &occupied_ui;
    always_comb begin
      for (integer slot = 0; slot < 2; slot = slot + 1)
        valid_ui[slot] = occupied_ui[slot] && !dirty_ui[slot] &&
                         (publish_toggle_ui[slot] !=
                          release_toggle_ui[slot]);
    end

    always_ff @(posedge ui_clk or negedge ui_resetn) begin
      if (!ui_resetn) begin
        occupied_ui <= 2'b00;
        dirty_ui <= 2'b00;
        publish_toggle_ui <= 2'b00;
        release_seen_ui <= 2'b00;
        write_slot <= 1'b0;
        build_active <= 1'b0;
        expected_dma_index <= 5'd0;
        frame_released_ui <= 1'b0;
        protocol_error_ui <= 1'b0;
      end else begin
        frame_released_ui <= 1'b0;

        // A transmit-side release makes that complete frame slot reusable.
        for (integer slot = 0; slot < 2; slot = slot + 1) begin
          if (release_toggle_ui[slot] != release_seen_ui[slot]) begin
            release_seen_ui[slot] <= release_toggle_ui[slot];
            occupied_ui[slot] <= 1'b0;
            frame_released_ui <= 1'b1;
          end
        end

        if (build_start) begin
          if (!build_ready) begin
            protocol_error_ui <= 1'b1;
          end else begin
            occupied_ui[write_slot] <= 1'b1;
            dirty_ui[write_slot] <= 1'b1;
            build_active <= 1'b1;
            expected_dma_index <= 5'd0;
            slot_header[write_slot] <= {
              DEST_MAC,
              build_hart ? HART1_MAC : HART0_MAC,
              DATA_ETHERTYPE
            };
            slot_frame_number[write_slot] <= build_frame_number;
            slot_valid_records[write_slot] <= build_valid_records;
          end
        end

        if (dma_data_valid && dma_data_ready) begin
          if (dma_data_index != expected_dma_index)
            protocol_error_ui <= 1'b1;

          // DDR stores the older record in bits 255:0.  The effective struct
          // occupies the upper 192 bits of each 256-bit DDR record.
          slot_payload[write_slot][dma_data_index] <= {
            ((dma_data_index*2 + 1) < slot_valid_records[write_slot]) ?
              dma_data[511:320] : 192'b0,
            ((dma_data_index*2) < slot_valid_records[write_slot]) ?
              dma_data[255:64] : 192'b0
          };

          if (dma_data_last != (dma_data_index == 5'd29))
            protocol_error_ui <= 1'b1;

          if (dma_data_index == 5'd29) begin
            dirty_ui[write_slot] <= 1'b0;
            publish_toggle_ui[write_slot] <=
              ~publish_toggle_ui[write_slot];
            build_active <= 1'b0;
            expected_dma_index <= 5'd0;
            write_slot <= ~write_slot;
          end else begin
            expected_dma_index <= expected_dma_index + 5'd1;
          end
        end
      end
    end

    logic [1:0] publish_toggle_tx;
    sync_bits #(.WIDTH(2), .STAGES(3)) publish_sync_i (
      .clk(tx_clk), .resetn(tx_resetn),
      .async_in(publish_toggle_ui), .sync_out(publish_toggle_tx)
    );

    typedef enum logic [2:0] {
      TX_IDLE, TX_HEADER, TX_FRAME_NUMBER, TX_LOAD_WORD, TX_RECORD_DATA
    } tx_state_t;
    tx_state_t tx_state;
    logic read_slot;
    logic [4:0] header_index;
    logic [2:0] frame_number_index;
    logic [4:0] payload_word_index;
    logic [5:0] payload_word_byte;
    logic [383:0] payload_word_hold;
    logic [111:0] active_header;
    logic [31:0] active_frame_number;

    wire current_slot_pending =
      publish_toggle_tx[read_slot] != release_toggle_tx[read_slot];

    always_comb begin
      m_axis_tdata = 8'h00;
      m_axis_tvalid = 1'b0;
      m_axis_tlast = 1'b0;
      case (tx_state)
        TX_HEADER: begin
          m_axis_tvalid = 1'b1;
          m_axis_tdata = active_header[111-(header_index*8) -: 8];
        end
        TX_FRAME_NUMBER: begin
          m_axis_tvalid = 1'b1;
          case (frame_number_index)
            0: m_axis_tdata = active_frame_number[31:24];
            1: m_axis_tdata = active_frame_number[23:16];
            2: m_axis_tdata = active_frame_number[15:8];
            default: m_axis_tdata = active_frame_number[7:0];
          endcase
        end
        TX_RECORD_DATA: begin
          m_axis_tvalid = 1'b1;
          if (payload_word_byte < 24)
            m_axis_tdata =
              payload_word_hold[191-(payload_word_byte*8) -: 8];
          else
            m_axis_tdata =
              payload_word_hold[383-((payload_word_byte-24)*8) -: 8];
          m_axis_tlast = (payload_word_index == 5'd29) &&
                         (payload_word_byte == 6'd47);
        end
        default: begin end
      endcase
    end

    always_ff @(posedge tx_clk or negedge tx_resetn) begin
      if (!tx_resetn) begin
        tx_state <= TX_IDLE;
        read_slot <= 1'b0;
        release_toggle_tx <= 2'b00;
        header_index <= 5'd0;
        frame_number_index <= 3'd0;
        payload_word_index <= 5'd0;
        payload_word_byte <= 6'd0;
        payload_word_hold <= '0;
        active_header <= '0;
        active_frame_number <= '0;
        frame_done_tx <= 1'b0;
      end else begin
        frame_done_tx <= 1'b0;
        case (tx_state)
          TX_IDLE: if (current_slot_pending) begin
            active_header <= slot_header[read_slot];
            active_frame_number <= slot_frame_number[read_slot];
            header_index <= 5'd0;
            tx_state <= TX_HEADER;
          end

          TX_HEADER: if (m_axis_tvalid && m_axis_tready) begin
            if (header_index == HEADER_BYTES-1) begin
              frame_number_index <= 3'd0;
              tx_state <= TX_FRAME_NUMBER;
            end else
              header_index <= header_index + 5'd1;
          end

          TX_FRAME_NUMBER: if (m_axis_tvalid && m_axis_tready) begin
            if (frame_number_index == 3) begin
              payload_word_index <= 5'd0;
              tx_state <= TX_LOAD_WORD;
            end else
              frame_number_index <= frame_number_index + 3'd1;
          end

          // One preload cycle per frame makes the 30-deep, 384-bit storage
          // mux a registered path.  All later words are prefetched at the
          // preceding word's final-byte handshake, so there are no gaps.
          TX_LOAD_WORD: begin
            payload_word_hold <= slot_payload[read_slot][0];
            payload_word_byte <= 6'd0;
            tx_state <= TX_RECORD_DATA;
          end

          TX_RECORD_DATA: if (m_axis_tvalid && m_axis_tready) begin
            if (payload_word_byte == 6'd47) begin
              if (payload_word_index == 5'd29) begin
                release_toggle_tx[read_slot] <=
                  publish_toggle_tx[read_slot];
                read_slot <= ~read_slot;
                frame_done_tx <= 1'b1;
                tx_state <= TX_IDLE;
              end else begin
                payload_word_index <= payload_word_index + 5'd1;
                payload_word_hold <=
                  slot_payload[read_slot][payload_word_index + 5'd1];
                payload_word_byte <= 6'd0;
              end
            end else
              payload_word_byte <= payload_word_byte + 6'd1;
          end

          default: tx_state <= TX_IDLE;
        endcase
      end
    end

    assign empty_tx = (tx_state == TX_IDLE) &&
                      (publish_toggle_tx == release_toggle_tx);

    initial begin
      if (PAYLOAD_BYTES != 1444 || FRAME_BYTES != 1458)
        $error("Info frame geometry must be 14-byte header + 1444-byte payload");
    end
endmodule
