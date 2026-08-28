`timescale 1ns/1ps

// Compact AXI4 memory used only by the full-system presimulation.  Address
// bits above the modeled memory window are folded away so the temporary
// 0x8000_0000 reset vector maps to line zero, just as the board address map
// selects the low instruction-DDR window.
module axi512_memory_model #(
  parameter integer LINE_COUNT = 2048,
  // When set, bit 32 selects a second modeled window instead of being
  // folded away.  This gives DDR1 independent low/high 4-GiB hart regions
  // while keeping a compact sparse behavioral memory.
  parameter integer SPLIT_AT_ADDR32 = 0,
  // DDR0 uses bit 29 to keep the 0x8000_0000 IFU image and 0xA000_0000
  // random LSU data in independent compact banks.  A real 4-GiB DDR already
  // distinguishes these addresses; this option prevents simulation-only
  // aliasing after high address bits are folded away.
  parameter integer SPLIT_AT_ADDR29 = 0
) (
  input  logic         clk,
  input  logic         resetn,

  input  logic [3:0]   awid,
  input  logic [32:0]  awaddr,
  input  logic [7:0]   awlen,
  input  logic [2:0]   awsize,
  input  logic [1:0]   awburst,
  input  logic         awvalid,
  output logic         awready,
  input  logic [511:0] wdata,
  input  logic [63:0]  wstrb,
  input  logic         wlast,
  input  logic         wvalid,
  output logic         wready,
  output logic [3:0]   bid,
  output logic [1:0]   bresp,
  output logic         bvalid,
  input  logic         bready,

  input  logic [3:0]   arid,
  input  logic [32:0]  araddr,
  input  logic [7:0]   arlen,
  input  logic [2:0]   arsize,
  input  logic [1:0]   arburst,
  input  logic         arvalid,
  output logic         arready,
  output logic [3:0]   rid,
  output logic [511:0] rdata,
  output logic [1:0]   rresp,
  output logic         rlast,
  output logic         rvalid,
  input  logic         rready,

  output logic         protocol_error,
  output logic [31:0]  write_beat_count,
  output logic [31:0]  read_beat_count
);
  localparam integer INDEX_WIDTH = $clog2(LINE_COUNT);

  logic [511:0] mem [0:LINE_COUNT-1];
  logic write_active;
  logic [3:0] write_id;
  logic [32:0] write_addr;
  logic [7:0] write_len;
  logic [2:0] write_size;
  logic [7:0] write_index;
  logic read_active;
  logic [3:0] read_id;
  logic [32:0] read_addr;
  logic [7:0] read_len;
  logic [2:0] read_size;
  logic [7:0] read_index;
  integer byte_index;
  integer init_index;

  function automatic [INDEX_WIDTH-1:0] line_index(
    input logic [32:0] byte_address
  );
    if (SPLIT_AT_ADDR32)
      line_index = {byte_address[32],
                    byte_address[INDEX_WIDTH+4:6]};
    else if (SPLIT_AT_ADDR29)
      line_index = {byte_address[29],
                    byte_address[INDEX_WIDTH+4:6]};
    else
      line_index = byte_address[INDEX_WIDTH+5:6];
  endfunction

  initial begin
    for (init_index = 0; init_index < LINE_COUNT; init_index = init_index + 1)
      mem[init_index] = 512'b0;
  end

  always_comb begin
    awready = resetn && !write_active && !bvalid;
    wready  = resetn && write_active && !bvalid;
    bid     = write_id;
    bresp   = 2'b00;

    arready = resetn && !read_active;
    rid     = read_id;
    rdata   = mem[line_index(read_addr)];
    rresp   = 2'b00;
    rlast   = read_active && (read_index == read_len);
    rvalid  = resetn && read_active;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      write_active    <= 1'b0;
      write_id        <= 4'b0;
      write_addr      <= 33'b0;
      write_len       <= 8'b0;
      write_size      <= 3'b0;
      write_index     <= 8'b0;
      bvalid          <= 1'b0;
      read_active     <= 1'b0;
      read_id         <= 4'b0;
      read_addr       <= 33'b0;
      read_len        <= 8'b0;
      read_size       <= 3'b0;
      read_index      <= 8'b0;
      protocol_error  <= 1'b0;
      write_beat_count <= 32'b0;
      read_beat_count  <= 32'b0;
    end else begin
      if (bvalid && bready)
        bvalid <= 1'b0;

      if (awvalid && awready) begin
        write_active <= 1'b1;
        write_id     <= awid;
        write_addr   <= awaddr;
        write_len    <= awlen;
        write_size   <= awsize;
        write_index  <= 8'b0;
        // A 512-bit AXI data bus may legally carry narrow 4/8-byte beats.
        // Xilinx width converters preserve AWSIZE for transfers they do not
        // coalesce, using WSTRB and AWADDR[5:0] to select the active lanes.
        if ((awsize > 3'd6) || (awburst != 2'b01)) begin
          if (!protocol_error)
            $display("AXI_PROTOCOL_ERROR AW time=%0t addr=%h len=%0d size=%0d burst=%0d",
                     $time, awaddr, awlen, awsize, awburst);
          protocol_error <= 1'b1;
        end
      end

      if (wvalid && wready) begin
        for (byte_index = 0; byte_index < 64; byte_index = byte_index + 1)
          if (wstrb[byte_index])
            mem[line_index(write_addr)][byte_index*8 +: 8] <=
              wdata[byte_index*8 +: 8];
        write_beat_count <= write_beat_count + 32'd1;
        if (wlast != (write_index == write_len)) begin
          if (!protocol_error)
            $display("AXI_PROTOCOL_ERROR WLAST time=%0t addr=%h len=%0d index=%0d wlast=%b",
                     $time, write_addr, write_len, write_index, wlast);
          protocol_error <= 1'b1;
        end
        if (write_index == write_len) begin
          write_active <= 1'b0;
          bvalid       <= 1'b1;
        end else begin
          write_index <= write_index + 8'd1;
          write_addr  <= write_addr + (33'd1 << write_size);
        end
      end

      if (arvalid && arready) begin
        read_active <= 1'b1;
        read_id     <= arid;
        read_addr   <= araddr;
        read_len    <= arlen;
        read_size   <= arsize;
        read_index  <= 8'b0;
        if ((arsize > 3'd6) || (arburst != 2'b01)) begin
          if (!protocol_error)
            $display("AXI_PROTOCOL_ERROR AR time=%0t addr=%h len=%0d size=%0d burst=%0d",
                     $time, araddr, arlen, arsize, arburst);
          protocol_error <= 1'b1;
        end
      end

      if (rvalid && rready) begin
        read_beat_count <= read_beat_count + 32'd1;
        if (read_index == read_len) begin
          read_active <= 1'b0;
        end else begin
          read_index <= read_index + 8'd1;
          read_addr  <= read_addr + (33'd1 << read_size);
        end
      end
    end
  end
endmodule
