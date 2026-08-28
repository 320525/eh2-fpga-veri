`timescale 1ns/1ps

// First-error-wins monitor.  Sources are already synchronized to ctrl_clk by
// their owning subsystems.  Normal operation relies on the system-wide hard
// reset between sessions; clear remains only as a directed-test hook.
module system_error_monitor (
  input  logic clk,
  input  logic resetn,
  input  logic clear,

  input  logic err_nb_hart0,
  input  logic err_nb_hart1,
  input  logic err_hash_hart0,
  input  logic err_hash_hart1,
  input  logic err_txmac_fifo,
  input  logic err_txmac_stream,
  input  logic err_waw_hart0,
  input  logic err_waw_hart1,
  input  logic err_bank_hart0,
  input  logic err_bank_hart1,
  input  logic err_info_rx_fifo,
  input  logic err_info_tx_fifo,
  input  logic err_rx_frame_buf,
  input  logic err_rx_frame_len,
  input  logic err_mac_rx_fcs,
  input  logic err_mac_config,
  input  logic err_phy_init,
  input  logic err_phy_link,
  input  logic err_mig0,
  input  logic err_mig1,
  input  logic err_ddr_zero,
  input  logic err_ddr_check,
  input  logic err_eh2_init,
  input  logic err_eh2_ifu_axi,
  input  logic err_eh2_lsu_axi,
  input  logic err_program_write,
  input  logic err_program_fifo,
  input  logic err_program_dma,
  input  logic err_program_sequence,
  input  logic err_info_fifo_h0,
  input  logic err_info_fifo_h1,
  input  logic err_info_queue_h0,
  input  logic err_info_queue_h1,
  input  logic err_info_capture_h0,
  input  logic err_info_capture_h1,
  input  logic err_info_dma,
  input  logic err_info_dump,
  input  logic err_info_dump_read_protocol,
  input  logic err_info_dump_frame_protocol,
  input  logic err_info_dump_release,
  input  logic err_waw_cause_h0,
  input  logic err_waw_cause_h1,

  output logic pending,
  output logic [31:0] code
);
  import eh2_system_pkg::*;

  logic any_error;
  logic [31:0] next_code;

  always_comb begin
    any_error = 1'b1;
    if      (err_nb_hart0)      next_code = ERR_NB_HART0;
    else if (err_nb_hart1)      next_code = ERR_NB_HART1;
    else if (err_hash_hart0)    next_code = ERR_HASH_HART0;
    else if (err_hash_hart1)    next_code = ERR_HASH_HART1;
    else if (err_txmac_fifo)    next_code = ERR_TXMAC_FIFO;
    else if (err_txmac_stream)  next_code = ERR_TXMAC_STREAM;
    else if (err_waw_hart0)     next_code = ERR_WAW_HART0;
    else if (err_waw_hart1)     next_code = ERR_WAW_HART1;
    else if (err_bank_hart0)    next_code = ERR_BANK_HART0;
    else if (err_bank_hart1)    next_code = ERR_BANK_HART1;
    else if (err_info_rx_fifo)  next_code = ERR_INFO_RX_FIFO;
    else if (err_info_tx_fifo)  next_code = ERR_INFO_TX_FIFO;
    else if (err_rx_frame_buf)  next_code = ERR_RX_FRAME_BUF;
    else if (err_rx_frame_len)  next_code = ERR_RX_FRAME_LEN;
    else if (err_mac_rx_fcs)    next_code = ERR_MAC_RX_FCS;
    else if (err_mac_config)    next_code = ERR_MAC_CONFIG;
    else if (err_phy_init)      next_code = ERR_PHY_INIT;
    else if (err_phy_link)      next_code = ERR_PHY_LINK;
    else if (err_mig0)          next_code = ERR_MIG0;
    else if (err_mig1)          next_code = ERR_MIG1;
    else if (err_ddr_zero)      next_code = ERR_DDR_ZERO;
    else if (err_ddr_check)     next_code = ERR_DDR_CHECK;
    else if (err_eh2_init)      next_code = ERR_EH2_INIT;
    else if (err_eh2_ifu_axi)   next_code = ERR_EH2_IFU_AXI;
    else if (err_eh2_lsu_axi)   next_code = ERR_EH2_LSU_AXI;
    else if (err_program_sequence) next_code = ERR_PROGRAM_SEQUENCE;
    else if (err_program_write) next_code = ERR_PROGRAM_WRITE;
    else if (err_program_fifo)  next_code = ERR_PROGRAM_FIFO;
    else if (err_program_dma)   next_code = ERR_PROGRAM_DMA;
    else if (err_info_fifo_h0)  next_code = ERR_INFO_FIFO_H0;
    else if (err_info_fifo_h1)  next_code = ERR_INFO_FIFO_H1;
    else if (err_info_queue_h0) next_code = ERR_INFO_QUEUE_H0;
    else if (err_info_queue_h1) next_code = ERR_INFO_QUEUE_H1;
    else if (err_info_capture_h0)
                                next_code = ERR_INFO_CAPTURE_H0;
    else if (err_info_capture_h1)
                                next_code = ERR_INFO_CAPTURE_H1;
    else if (err_info_dma)      next_code = ERR_INFO_DMA;
    else if (err_info_dump)     next_code = ERR_INFO_DUMP;
    else if (err_info_dump_read_protocol)
                                next_code = ERR_INFO_DUMP_READ_PROTOCOL;
    else if (err_info_dump_frame_protocol)
                                next_code = ERR_INFO_DUMP_FRAME_PROTOCOL;
    else if (err_info_dump_release)
                                next_code = ERR_INFO_DUMP_RELEASE;
    else if (err_waw_cause_h0)  next_code = ERR_WAW_CAUSE_H0;
    else if (err_waw_cause_h1)  next_code = ERR_WAW_CAUSE_H1;
    else begin
      any_error = 1'b0;
      next_code = 32'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!resetn || clear) begin
      pending <= 1'b0;
      code    <= 32'b0;
    end else if (!pending && any_error) begin
      pending <= 1'b1;
      code    <= next_code;
    end
  end
endmodule
