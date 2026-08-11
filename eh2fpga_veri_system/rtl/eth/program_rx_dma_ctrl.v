`timescale 1ns / 1ps

// RX FIFO frame controller and AXI DataMover S2MM command generator.
//
// Operation for each valid Ethernet frame:
//   1. Consume seven 16-bit words (14-byte Ethernet header) while checking
//      the destination MAC address 02:12:34:56:78:FF.
//   2. Discard a non-matching frame through TLAST without issuing a command.
//   3. For a matching frame, post one 1024-byte S2MM command using
//      dma_write_addr and forward the remaining RX FIFO words.
//   4. On the accepted FIFO TLAST, count the frame and advance the next DMA
//      address by 0x400 bytes so frame payloads are contiguous in memory.
//   5. Wait for the DataMover status before accepting the next frame.
module program_rx_dma_ctrl #(
  parameter [31:0] DMA_BASE_ADDR = 32'h8000_0000
) (
  input  wire        clk,
  input  wire        resetn,
  input  wire        session_clear,

  // RX FIFO read-side interface.
  input  wire [15:0] rx_fifo_tdata,
  input  wire        rx_fifo_tvalid,
  input  wire        rx_fifo_tlast,
  output wire        rx_fifo_tready,

  // Payload stream connected to AXI DataMover S_AXIS_S2MM.
  output wire [15:0] payload_tdata,
  output wire        payload_tvalid,
  output wire        payload_tlast,
  input  wire        payload_tready,

  // AXI DataMover S2MM command interface.
  output wire [71:0] s_axis_s2mm_cmd_tdata,
  output wire        s_axis_s2mm_cmd_tvalid,
  input  wire        s_axis_s2mm_cmd_tready,

  // AXI DataMover S2MM status interface.  The configured DataMover uses the
  // 32-bit Indeterminate-BTT status format.
  input  wire [31:0] m_axis_s2mm_sts_tdata,
  input  wire        m_axis_s2mm_sts_tvalid,
  output wire        m_axis_s2mm_sts_tready,

  // Frame and DMA status outputs.
  output reg  [31:0] frame_count,
  output reg  [31:0] dma_write_addr,
  output reg         frame_done,
  output reg         dma_done,
  output reg         dma_error,
  output reg         sequence_error,
  output reg         frame_length_error,
  output reg  [31:0] last_dma_status,
  output wire        dma_busy
);

  localparam [22:0] DMA_BTT_BYTES  = 23'h000400;   // 1024 bytes
  localparam [31:0] DMA_ADDR_STEP  = 32'h0000_0400; // 1024 bytes
  localparam [9:0]  PAYLOAD_WORDS  = 10'd512;       // 1024 / 2

  // RX FIFO byte lane 0 is the earlier byte on the wire, so each pair is
  // compared in {later_byte, earlier_byte} order.
  localparam [15:0] DEST_MAC_WORD0 = 16'h1202;
  localparam [15:0] DEST_MAC_WORD1 = 16'h5634;
  localparam [15:0] DEST_MAC_WORD2 = 16'hFF78;

  localparam [2:0] ST_DISCARD_HEADER = 3'd0;
  localparam [2:0] ST_SEND_COMMAND   = 3'd1;
  localparam [2:0] ST_MOVE_PAYLOAD   = 3'd2;
  localparam [2:0] ST_WAIT_STATUS    = 3'd3;
  localparam [2:0] ST_DROP_FRAME     = 3'd4;
  localparam [2:0] ST_READ_SEQUENCE  = 3'd5;

  reg [2:0] state;
  reg [2:0] discard_count;
  reg [9:0] payload_word_count;
  reg [3:0] active_tag;
  reg       dest_match;
  reg       sequence_half;
  reg [15:0] sequence_word0;

  wire rx_transfer;
  wire payload_transfer;
  wire command_transfer;
  wire status_transfer;

  assign rx_fifo_tready = (state == ST_DISCARD_HEADER) ? 1'b1 :
                          (state == ST_READ_SEQUENCE)  ? 1'b1 :
                          (state == ST_MOVE_PAYLOAD)   ? payload_tready :
                          (state == ST_DROP_FRAME)     ? 1'b1 :
                                                       1'b0;

  assign rx_transfer      = rx_fifo_tvalid && rx_fifo_tready;
  assign payload_transfer = payload_tvalid && payload_tready;
  assign command_transfer = s_axis_s2mm_cmd_tvalid &&
                            s_axis_s2mm_cmd_tready;
  assign status_transfer  = m_axis_s2mm_sts_tvalid &&
                            m_axis_s2mm_sts_tready;

  assign payload_tdata  = rx_fifo_tdata;
  assign payload_tvalid = (state == ST_MOVE_PAYLOAD) && rx_fifo_tvalid;
  assign payload_tlast  = (state == ST_MOVE_PAYLOAD) && rx_fifo_tlast;

  // DataMover 72-bit command layout for a 32-bit address.  This controller
  // supplies only the starting address for each 1024-byte transfer; TYPE=1
  // makes the DataMover increment its AXI destination address internally.
  // [71:68] RSVD, [67:64] TAG, [63:32] SADDR, [31] DRR, [30] EOF,
  // [29:24] DSA, [23] TYPE (1 = INCR), [22:0] BTT.
  assign s_axis_s2mm_cmd_tdata = {
    4'h0,
    frame_count[3:0],
    dma_write_addr,
    1'b1,              // Re-establish DRE alignment for this command.
    1'b1,              // This command contains one complete frame payload.
    6'b00_0000,
    1'b1,              // Incrementing AXI memory address.
    DMA_BTT_BYTES
  };

  assign s_axis_s2mm_cmd_tvalid = (state == ST_SEND_COMMAND);
  assign m_axis_s2mm_sts_tready = (state == ST_WAIT_STATUS);
  assign dma_busy = (state == ST_SEND_COMMAND) ||
                    (state == ST_MOVE_PAYLOAD) ||
                    (state == ST_WAIT_STATUS);

  always @(posedge clk) begin
    if (!resetn || session_clear) begin
      state              <= ST_DISCARD_HEADER;
      discard_count      <= 3'd0;
      payload_word_count <= 10'd0;
      active_tag         <= 4'd0;
      dest_match         <= 1'b1;
      frame_count        <= 32'd0;
      // Instruction images are linked at the temporary EH2 reset vector.
      // Each completed frame moves the next command start address forward by
      // exactly 1024 bytes.
      dma_write_addr     <= DMA_BASE_ADDR;
      frame_done         <= 1'b0;
      dma_done           <= 1'b0;
      dma_error          <= 1'b0;
      sequence_error     <= 1'b0;
      frame_length_error <= 1'b0;
      last_dma_status    <= 32'd0;
      sequence_half      <= 1'b0;
      sequence_word0     <= 16'b0;
    end
    else begin
      frame_done <= 1'b0;
      dma_done   <= 1'b0;

      case (state)
        ST_DISCARD_HEADER: begin
          if (rx_transfer) begin
            if (rx_fifo_tlast) begin
              // A legal frame cannot end inside its 14-byte header.
              discard_count      <= 3'd0;
              dest_match         <= 1'b1;
              frame_length_error <= 1'b1;
            end
            else begin
              if (((discard_count == 3'd0) &&
                   (rx_fifo_tdata != DEST_MAC_WORD0)) ||
                  ((discard_count == 3'd1) &&
                   (rx_fifo_tdata != DEST_MAC_WORD1)) ||
                  ((discard_count == 3'd2) &&
                   (rx_fifo_tdata != DEST_MAC_WORD2))) begin
                dest_match <= 1'b0;
              end

              if (discard_count == 3'd6) begin
                // The destination decision is complete before this seventh
                // header word.  A rejected frame is drained through TLAST;
                // only a matching frame is allowed to post a DMA command.
                discard_count <= 3'd0;
                if (dest_match)
                  state <= ST_READ_SEQUENCE;
                else
                  state <= ST_DROP_FRAME;
              end
              else begin
                discard_count <= discard_count + 3'd1;
              end
            end
          end
        end

        ST_DROP_FRAME: begin
          if (rx_transfer && rx_fifo_tlast) begin
            // Rejected frames do not alter frame_count or dma_write_addr, so
            // accepted payloads remain packed in consecutive DDR locations.
            discard_count <= 3'd0;
            dest_match    <= 1'b1;
            state         <= ST_DISCARD_HEADER;
          end
        end

        ST_READ_SEQUENCE: begin
          if (rx_transfer) begin
            if (rx_fifo_tlast) begin
              frame_length_error <= 1'b1;
              sequence_half      <= 1'b0;
              discard_count      <= 3'd0;
              dest_match         <= 1'b1;
              state              <= ST_DISCARD_HEADER;
            end else if (!sequence_half) begin
              sequence_word0 <= rx_fifo_tdata;
              sequence_half  <= 1'b1;
            end else begin
              sequence_half <= 1'b0;
              // Bytes arrive on lane 0 first. The host sequence field is
              // network byte order, so swap bytes within both 16-bit beats.
              if ({sequence_word0[7:0], sequence_word0[15:8],
                   rx_fifo_tdata[7:0], rx_fifo_tdata[15:8]} != frame_count) begin
                sequence_error <= 1'b1;
                state          <= ST_DROP_FRAME;
              end else begin
                state <= ST_SEND_COMMAND;
              end
            end
          end
        end

        ST_SEND_COMMAND: begin
          if (command_transfer) begin
            active_tag         <= frame_count[3:0];
            payload_word_count <= 10'd0;
            state              <= ST_MOVE_PAYLOAD;
          end
        end

        ST_MOVE_PAYLOAD: begin
          if (payload_transfer) begin
            if (rx_fifo_tlast) begin
              if (payload_word_count != (PAYLOAD_WORDS - 10'd1)) begin
                frame_length_error <= 1'b1;
              end

              frame_count        <= frame_count + 32'd1;
              dma_write_addr     <= dma_write_addr + DMA_ADDR_STEP;
              frame_done         <= 1'b1;
              payload_word_count <= 10'd0;
              state              <= ST_WAIT_STATUS;
            end
            else begin
              payload_word_count <= payload_word_count + 10'd1;

              // The 512th word must carry TLAST for a 1024-byte command.
              if (payload_word_count == (PAYLOAD_WORDS - 10'd1)) begin
                frame_length_error <= 1'b1;
              end
            end
          end
        end

        ST_WAIT_STATUS: begin
          if (status_transfer) begin
            last_dma_status <= m_axis_s2mm_sts_tdata;
            dma_done        <= 1'b1;

            // IBTT status: EOP[31], bytes received[30:8], OKAY[7],
            // error flags[6:4], and echoed command tag[3:0].
            if (!m_axis_s2mm_sts_tdata[31] ||
                (m_axis_s2mm_sts_tdata[30:8] != DMA_BTT_BYTES) ||
                !m_axis_s2mm_sts_tdata[7] ||
                (m_axis_s2mm_sts_tdata[6:4] != 3'b000) ||
                (m_axis_s2mm_sts_tdata[3:0] != active_tag)) begin
              dma_error <= 1'b1;
            end

            discard_count <= 3'd0;
            dest_match    <= 1'b1;
            state         <= ST_DISCARD_HEADER;
          end
        end

        default: begin
          state         <= ST_DISCARD_HEADER;
          discard_count <= 3'd0;
          dest_match    <= 1'b1;
        end
      endcase
    end
  end

endmodule
