// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

package info_struct_pkg;
  localparam int INFO_LOGICAL_WIDTH = 192;
  localparam int INFO_RECORD_WIDTH  = 256;
  localparam int INFO_RECORD_BYTES  = 32;
  localparam int INFO_WIRE_BYTES    = 24;
  localparam int ETH_LOG_PAYLOAD_BYTES = 1444;
  localparam int ETH_LOG_FRAME_NUMBER_BYTES = 4;
  localparam int ETH_LOG_RECORDS_PER_FRAME = 60;

  typedef enum logic [1:0] {
    WAW_CANCEL_NONE    = 2'b00,
    WAW_CANCEL_DIRECT  = 2'b01,
    WAW_CANCEL_NB_LOAD = 2'b10,
    WAW_CANCEL_NB_DIV  = 2'b11
  } waw_cancel_kind_t;

  // The packed order is also the network order.  A transmitter sends bit
  // 255 first, so sequence is the first 32-bit word seen by the host.
  typedef struct packed {
    logic [31:0] sequence_id;
    logic [31:0] pc;
    logic [31:0] instruction;
    logic [31:0] metadata;
    logic [31:0] data;
    logic [31:0] waw_cancel_number;
  } info_struct_t;

  function automatic logic [31:0] make_metadata(
      input waw_cancel_kind_t waw_kind,
      input logic             hart,
      input logic [1:0]       privilege,
      input logic [1:0]       event_type,
      input logic [11:0]      register_number
  );
    make_metadata = {
      waw_kind, 13'b0, hart, privilege, event_type, register_number
    };
  endfunction

  function automatic logic [INFO_RECORD_WIDTH-1:0] pad_record(
      input info_struct_t value
  );
    // The reserved 64 bits trail the meaningful fields on DDR and Ethernet.
    pad_record = {value, 64'b0};
  endfunction
endpackage
