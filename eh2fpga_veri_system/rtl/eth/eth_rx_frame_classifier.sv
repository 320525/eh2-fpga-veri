`timescale 1ns/1ps

module eth_rx_frame_classifier #(
  parameter int MAX_FRAME_WORDS = 520
) (
  input  logic        clk,
  input  logic        resetn,

  input  logic [15:0] s_axis_tdata,
  input  logic        s_axis_tvalid,
  input  logic        s_axis_tlast,
  output logic        s_axis_tready,

  output logic [15:0] program_tdata,
  output logic        program_tvalid,
  output logic        program_tlast,
  input  logic        program_tready,

  output logic [15:0] info_wr_data,
  output logic        info_wr_last,
  output logic        info_wr_en,
  input  logic        info_fifo_full,

  output logic        program_frame_accepted,
  output logic        info_frame_accepted,
  output logic        frame_buffer_overflow,
  output logic        recognized_length_error,
  output logic [31:0] dropped_frame_count
);
  localparam int PROGRAM_FRAME_WORDS = (14 + 1024) / 2;
  localparam int INFO_FRAME_WORDS    = (14 + 46) / 2;
  localparam int COUNT_W = $clog2(MAX_FRAME_WORDS + 1);

  // Only the three destination-MAC words are buffered. Once the destination
  // is known, program data streams directly to the DMA path. System frames
  // discard the seven Ethernet-header words and stream only their 46-byte
  // payload to the dedicated information FIFO. This sustains consecutive
  // line-rate frames without filling the MAC RX FIFO.
  typedef enum logic [2:0] {
    HEADER,
    PROGRAM_HEADER,
    PROGRAM_STREAM,
    INFO_SKIP_HEADER,
    INFO_STREAM,
    DROP_REMAINDER
  } state_t;
  state_t state;

  logic [15:0] header_words [0:2];
  logic [1:0] header_replay_index;
  logic [COUNT_W-1:0] source_word_count;

  wire third_word_program_dest =
      (header_words[0] == 16'h1202) &&
      (header_words[1] == 16'h5634) &&
      (s_axis_tdata   == 16'hFF78);
  wire third_word_system_dest =
      (header_words[0] == 16'h3202) &&
      (header_words[1] == 16'h2505) &&
      (s_axis_tdata   == 16'hFF00);

  always_comb begin
    s_axis_tready = 1'b0;
    program_tdata = 16'b0;
    program_tvalid = 1'b0;
    program_tlast = 1'b0;
    info_wr_data = 16'b0;
    info_wr_last = 1'b0;
    info_wr_en = 1'b0;

    case (state)
      HEADER: begin
        s_axis_tready = 1'b1;
      end

      PROGRAM_HEADER: begin
        program_tdata = header_words[header_replay_index];
        program_tvalid = 1'b1;
      end

      PROGRAM_STREAM: begin
        s_axis_tready = program_tready;
        program_tdata = s_axis_tdata;
        program_tvalid = s_axis_tvalid;
        program_tlast = s_axis_tlast;
      end

      INFO_SKIP_HEADER: begin
        s_axis_tready = 1'b1;
      end

      INFO_STREAM: begin
        s_axis_tready = !info_fifo_full;
        info_wr_data = s_axis_tdata;
        info_wr_last = s_axis_tlast;
        info_wr_en = s_axis_tvalid && !info_fifo_full;
      end

      DROP_REMAINDER: begin
        s_axis_tready = 1'b1;
      end

      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      state                    <= HEADER;
      header_replay_index      <= 2'b0;
      source_word_count        <= '0;
      header_words[0]          <= 16'b0;
      header_words[1]          <= 16'b0;
      header_words[2]          <= 16'b0;
      program_frame_accepted   <= 1'b0;
      info_frame_accepted      <= 1'b0;
      frame_buffer_overflow    <= 1'b0;
      recognized_length_error <= 1'b0;
      dropped_frame_count      <= 32'd0;
    end else begin
      program_frame_accepted   <= 1'b0;
      info_frame_accepted      <= 1'b0;
      frame_buffer_overflow    <= 1'b0;
      recognized_length_error <= 1'b0;

      case (state)
        HEADER: begin
          if (s_axis_tvalid && s_axis_tready) begin
            header_words[source_word_count[1:0]] <= s_axis_tdata;
            if (s_axis_tlast) begin
              if ((source_word_count == 2) &&
                  (third_word_program_dest || third_word_system_dest))
                recognized_length_error <= 1'b1;
              dropped_frame_count <= dropped_frame_count + 32'd1;
              source_word_count <= '0;
            end else if (source_word_count == 2) begin
              source_word_count <= COUNT_W'(3);
              if (third_word_program_dest) begin
                header_replay_index <= 2'b0;
                state <= PROGRAM_HEADER;
              end else if (third_word_system_dest) begin
                state <= INFO_SKIP_HEADER;
              end else begin
                dropped_frame_count <= dropped_frame_count + 32'd1;
                state <= DROP_REMAINDER;
              end
            end else begin
              source_word_count <= source_word_count + 1'b1;
            end
          end
        end

        PROGRAM_HEADER: begin
          if (program_tvalid && program_tready) begin
            if (header_replay_index == 2) begin
              header_replay_index <= 2'b0;
              state <= PROGRAM_STREAM;
            end else begin
              header_replay_index <= header_replay_index + 1'b1;
            end
          end
        end

        PROGRAM_STREAM: begin
          if (s_axis_tvalid && s_axis_tready) begin
            if (s_axis_tlast) begin
              if ((source_word_count + 1'b1) == PROGRAM_FRAME_WORDS)
                program_frame_accepted <= 1'b1;
              else
                recognized_length_error <= 1'b1;
              source_word_count <= '0;
              state <= HEADER;
            end else if (source_word_count == MAX_FRAME_WORDS-1) begin
              frame_buffer_overflow <= 1'b1;
              dropped_frame_count <= dropped_frame_count + 32'd1;
              source_word_count <= '0;
              state <= DROP_REMAINDER;
            end else begin
              source_word_count <= source_word_count + 1'b1;
            end
          end
        end

        INFO_SKIP_HEADER: begin
          if (s_axis_tvalid && s_axis_tready) begin
            if (s_axis_tlast) begin
              recognized_length_error <= 1'b1;
              dropped_frame_count <= dropped_frame_count + 32'd1;
              source_word_count <= '0;
              state <= HEADER;
            end else if (source_word_count == 6) begin
              source_word_count <= COUNT_W'(7);
              state <= INFO_STREAM;
            end else begin
              source_word_count <= source_word_count + 1'b1;
            end
          end
        end

        INFO_STREAM: begin
          if (s_axis_tvalid && s_axis_tready) begin
            if (s_axis_tlast) begin
              if ((source_word_count + 1'b1) == INFO_FRAME_WORDS)
                info_frame_accepted <= 1'b1;
              else
                recognized_length_error <= 1'b1;
              source_word_count <= '0;
              state <= HEADER;
            end else if (source_word_count == MAX_FRAME_WORDS-1) begin
              frame_buffer_overflow <= 1'b1;
              dropped_frame_count <= dropped_frame_count + 32'd1;
              source_word_count <= '0;
              state <= DROP_REMAINDER;
            end else begin
              source_word_count <= source_word_count + 1'b1;
            end
          end
        end

        DROP_REMAINDER: begin
          if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
            source_word_count <= '0;
            state <= HEADER;
          end
        end

        default: begin
          source_word_count <= '0;
          state <= HEADER;
        end
      endcase
    end
  end
endmodule
