`timescale 1ns/1ps

package eh2_system_pkg;
  typedef enum logic [2:0] {
    ST_PRECONFIG    = 3'd0,
    ST_READY        = 3'd1,
    ST_PROGRAM_WRITE= 3'd2,
    ST_EXECUTE      = 3'd3,
    ST_END          = 3'd4,
    ST_ERROR        = 3'd5
  } system_state_t;

  typedef enum logic [2:0] {
    DDR0_OWNER_IDLE    = 3'd0,
    DDR0_OWNER_PROGRAM = 3'd1,
    DDR0_OWNER_CHECKER = 3'd2,
    DDR0_OWNER_EH2     = 3'd3
  } ddr0_owner_t;

  typedef enum logic [2:0] {
    DDR1_OWNER_IDLE    = 3'd0,
    DDR1_OWNER_ATG     = 3'd1,
    DDR1_OWNER_CHECKER = 3'd2,
    DDR1_OWNER_ZERO    = 3'd3,
    DDR1_OWNER_EH2     = 3'd4
  } ddr1_owner_t;

  localparam logic [47:0] PROGRAM_MAC = 48'h02_12_34_56_78_FF;
  localparam logic [47:0] SYSTEM_MAC  = 48'h02_32_05_25_00_FF;
  localparam logic [47:0] BCAST_MAC   = 48'hFF_FF_FF_FF_FF_FF;
  localparam logic [15:0] SYSTEM_ETHERTYPE = 16'h88B5;

  localparam logic [31:0] MSG_PREINIT_DONE = 32'h1111_1111;
  localparam logic [31:0] MSG_CHECK_PASS   = 32'h2222_2222;
  localparam logic [31:0] MSG_DATA_FAIL    = 32'h2222_0011;
  localparam logic [31:0] MSG_INSTR_FAIL   = 32'h2222_0022;
  localparam logic [31:0] MSG_READY        = 32'h3333_3333;
  localparam logic [31:0] MSG_PROGRAM_START= 32'h4400_4444;
  localparam logic [31:0] MSG_RECEIVE_DONE = 32'h4411_4444;
  // Host-to-FPGA acknowledgement.  The host sends this only after it has
  // stopped the current program-frame transmission in response to an error.
  localparam logic [31:0] HOST_SEND_STOPPED= 32'h4412_4445;
  localparam logic [31:0] MSG_PROGRAM_DONE = 32'h4444_4444;
  localparam logic [31:0] ERR_PROGRAM_OVERTIME = 32'h4444_0011;
  localparam logic [31:0] ERR_PROGRAM_WRITE    = 32'h4444_0022;
  localparam logic [31:0] ERR_PROGRAM_FIFO     = 32'h4444_0033;
  localparam logic [31:0] ERR_PROGRAM_DMA      = 32'h4444_0044;
  localparam logic [31:0] ERR_PROGRAM_SEQUENCE = 32'h4444_0055;
  localparam logic [31:0] ERR_PROGRAM_COUNT    = 32'h4444_0066;
  localparam logic [31:0] MSG_HART0_START  = 32'h5500_0000;
  localparam logic [31:0] MSG_HART1_START  = 32'h5501_0000;
  localparam logic [31:0] MSG_HART0_DONE   = 32'h5500_00FF;
  localparam logic [31:0] MSG_HART1_DONE   = 32'h5501_00FF;
  localparam logic [31:0] MSG_EH2_DONE     = 32'h5555_5555;
  localparam logic [31:0] ERR_NB_HART0     = 32'h6666_0011;
  localparam logic [31:0] ERR_NB_HART1     = 32'h6666_0012;
  localparam logic [31:0] ERR_HASH_HART0   = 32'h6666_0021;
  localparam logic [31:0] ERR_HASH_HART1   = 32'h6666_0022;
  localparam logic [31:0] ERR_TXMAC_FIFO   = 32'h6666_0033;
  localparam logic [31:0] ERR_TXMAC_STREAM = 32'h6666_0044;
  localparam logic [31:0] ERR_WAW_HART0    = 32'h6666_0051;
  localparam logic [31:0] ERR_WAW_HART1    = 32'h6666_0052;
  localparam logic [31:0] ERR_BANK_HART0   = 32'h6666_0061;
  localparam logic [31:0] ERR_BANK_HART1   = 32'h6666_0062;
  localparam logic [31:0] ERR_INFO_RX_FIFO = 32'h6666_0071;
  localparam logic [31:0] ERR_INFO_TX_FIFO = 32'h6666_0072;
  localparam logic [31:0] ERR_RX_FRAME_BUF = 32'h6666_0073;
  localparam logic [31:0] ERR_RX_FRAME_LEN = 32'h6666_0074;
  localparam logic [31:0] ERR_MAC_RX_FCS   = 32'h6666_0075;
  localparam logic [31:0] ERR_MAC_CONFIG   = 32'h6666_0081;
  localparam logic [31:0] ERR_PHY_INIT     = 32'h6666_0082;
  localparam logic [31:0] ERR_PHY_LINK     = 32'h6666_0083;
  localparam logic [31:0] ERR_MIG0         = 32'h6666_0091;
  localparam logic [31:0] ERR_MIG1         = 32'h6666_0092;
  localparam logic [31:0] ERR_DDR_ZERO     = 32'h6666_00A1;
  localparam logic [31:0] ERR_DDR_CHECK    = 32'h6666_00A2;
  localparam logic [31:0] ERR_EH2_INIT     = 32'h6666_00B1;
  localparam logic [31:0] ERR_EH2_IFU_AXI  = 32'h6666_00B2;
  localparam logic [31:0] ERR_EH2_LSU_AXI  = 32'h6666_00B3;
  localparam logic [31:0] ERR_ILLEGAL_STATE= 32'h6666_00F1;
  localparam logic [31:0] MSG_EXE_END      = 32'h7777_7777;
endpackage
