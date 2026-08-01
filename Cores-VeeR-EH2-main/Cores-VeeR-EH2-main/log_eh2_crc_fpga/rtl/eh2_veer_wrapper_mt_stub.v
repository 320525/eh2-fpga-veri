// Auto-extracted from the dual-hart Synplify netlist.
// Do not hand-edit port widths; regenerate with extract_synplify_stub.py.
(* black_box = "true" *)
module eh2_veer_wrapper (
  clk,
  rst_l,
  dbg_rst_l,
  rst_vec,
  nmi_int,
  nmi_vec,
  jtag_id,
  trace_rv_i_insn_ip,
  trace_rv_i_address_ip,
  trace_rv_i_valid_ip,
  trace_rv_i_exception_ip,
  trace_rv_i_ecause_ip,
  trace_rv_i_interrupt_ip,
  trace_rv_i_tval_ip,
  rv_commit_valid,
  rv_commit_insn,
  rv_commit_pc,
  rv_commit_hart_id,
  rv_commit_priv_mode,
  rv_commit_gpr_wen_intent,
  rv_commit_gpr_wen,
  rv_commit_gpr_rd,
  rv_commit_gpr_wdata,
  rv_commit_csr_wen,
  rv_commit_csr_addr,
  rv_commit_csr_wdata,
  rv_commit_is_nonblock,
  rv_commit_is_nonblock_load,
  rv_commit_is_nonblock_div,
  rv_commit_waw_victim,
  rv_nb_waw_valid,
  rv_nb_waw_victim_insn,
  rv_nb_waw_victim_pc,
  rv_nb_waw_victim_hart_id,
  rv_nb_waw_victim_gpr_rd,
  rv_nb_waw_victim_is_load,
  rv_nb_waw_victim_is_div,
  rv_nb_load_gpr_wen,
  rv_nb_load_gpr_hart_id,
  rv_nb_load_gpr_rd,
  rv_nb_load_gpr_wdata,
  rv_nb_div_gpr_wen,
  rv_nb_div_gpr_hart_id,
  rv_nb_div_gpr_rd,
  rv_nb_div_gpr_wdata,
  lsu_axi_awvalid,
  lsu_axi_awready,
  lsu_axi_awid,
  lsu_axi_awaddr,
  lsu_axi_awregion,
  lsu_axi_awlen,
  lsu_axi_awsize,
  lsu_axi_awburst,
  lsu_axi_awlock,
  lsu_axi_awcache,
  lsu_axi_awprot,
  lsu_axi_awqos,
  lsu_axi_wvalid,
  lsu_axi_wready,
  lsu_axi_wdata,
  lsu_axi_wstrb,
  lsu_axi_wlast,
  lsu_axi_bvalid,
  lsu_axi_bready,
  lsu_axi_bresp,
  lsu_axi_bid,
  lsu_axi_arvalid,
  lsu_axi_arready,
  lsu_axi_arid,
  lsu_axi_araddr,
  lsu_axi_arregion,
  lsu_axi_arlen,
  lsu_axi_arsize,
  lsu_axi_arburst,
  lsu_axi_arlock,
  lsu_axi_arcache,
  lsu_axi_arprot,
  lsu_axi_arqos,
  lsu_axi_rvalid,
  lsu_axi_rready,
  lsu_axi_rid,
  lsu_axi_rdata,
  lsu_axi_rresp,
  lsu_axi_rlast,
  ifu_axi_awvalid,
  ifu_axi_awready,
  ifu_axi_awid,
  ifu_axi_awaddr,
  ifu_axi_awregion,
  ifu_axi_awlen,
  ifu_axi_awsize,
  ifu_axi_awburst,
  ifu_axi_awlock,
  ifu_axi_awcache,
  ifu_axi_awprot,
  ifu_axi_awqos,
  ifu_axi_wvalid,
  ifu_axi_wready,
  ifu_axi_wdata,
  ifu_axi_wstrb,
  ifu_axi_wlast,
  ifu_axi_bvalid,
  ifu_axi_bready,
  ifu_axi_bresp,
  ifu_axi_bid,
  ifu_axi_arvalid,
  ifu_axi_arready,
  ifu_axi_arid,
  ifu_axi_araddr,
  ifu_axi_arregion,
  ifu_axi_arlen,
  ifu_axi_arsize,
  ifu_axi_arburst,
  ifu_axi_arlock,
  ifu_axi_arcache,
  ifu_axi_arprot,
  ifu_axi_arqos,
  ifu_axi_rvalid,
  ifu_axi_rready,
  ifu_axi_rid,
  ifu_axi_rdata,
  ifu_axi_rresp,
  ifu_axi_rlast,
  sb_axi_awvalid,
  sb_axi_awready,
  sb_axi_awid,
  sb_axi_awaddr,
  sb_axi_awregion,
  sb_axi_awlen,
  sb_axi_awsize,
  sb_axi_awburst,
  sb_axi_awlock,
  sb_axi_awcache,
  sb_axi_awprot,
  sb_axi_awqos,
  sb_axi_wvalid,
  sb_axi_wready,
  sb_axi_wdata,
  sb_axi_wstrb,
  sb_axi_wlast,
  sb_axi_bvalid,
  sb_axi_bready,
  sb_axi_bresp,
  sb_axi_bid,
  sb_axi_arvalid,
  sb_axi_arready,
  sb_axi_arid,
  sb_axi_araddr,
  sb_axi_arregion,
  sb_axi_arlen,
  sb_axi_arsize,
  sb_axi_arburst,
  sb_axi_arlock,
  sb_axi_arcache,
  sb_axi_arprot,
  sb_axi_arqos,
  sb_axi_rvalid,
  sb_axi_rready,
  sb_axi_rid,
  sb_axi_rdata,
  sb_axi_rresp,
  sb_axi_rlast,
  dma_axi_awvalid,
  dma_axi_awready,
  dma_axi_awid,
  dma_axi_awaddr,
  dma_axi_awsize,
  dma_axi_awprot,
  dma_axi_awlen,
  dma_axi_awburst,
  dma_axi_wvalid,
  dma_axi_wready,
  dma_axi_wdata,
  dma_axi_wstrb,
  dma_axi_wlast,
  dma_axi_bvalid,
  dma_axi_bready,
  dma_axi_bresp,
  dma_axi_bid,
  dma_axi_arvalid,
  dma_axi_arready,
  dma_axi_arid,
  dma_axi_araddr,
  dma_axi_arsize,
  dma_axi_arprot,
  dma_axi_arlen,
  dma_axi_arburst,
  dma_axi_rvalid,
  dma_axi_rready,
  dma_axi_rid,
  dma_axi_rdata,
  dma_axi_rresp,
  dma_axi_rlast,
  lsu_bus_clk_en,
  ifu_bus_clk_en,
  dbg_bus_clk_en,
  dma_bus_clk_en,
  dccm_ext_in_pkt,
  iccm_ext_in_pkt,
  btb_ext_in_pkt,
  ic_data_ext_in_pkt,
  ic_tag_ext_in_pkt,
  timer_int,
  soft_int,
  extintsrc_req,
  dec_tlu_perfcnt0,
  dec_tlu_perfcnt1,
  dec_tlu_perfcnt2,
  dec_tlu_perfcnt3,
  jtag_tck,
  jtag_tms,
  jtag_tdi,
  jtag_trst_n,
  jtag_tdo,
  core_id,
  mpc_debug_halt_req,
  mpc_debug_run_req,
  mpc_reset_run_req,
  mpc_debug_halt_ack,
  mpc_debug_run_ack,
  debug_brkpt_status,
  dec_tlu_mhartstart,
  i_cpu_halt_req,
  o_cpu_halt_ack,
  o_cpu_halt_status,
  o_debug_mode_status,
  i_cpu_run_req,
  o_cpu_run_ack,
  scan_mode,
  mbist_mode
)
;
input clk ;
input rst_l ;
input dbg_rst_l ;
input [31:1] rst_vec ;
input nmi_int ;
input [31:1] nmi_vec ;
input [31:1] jtag_id ;
output [127:0] trace_rv_i_insn_ip ;
output [127:0] trace_rv_i_address_ip ;
output [3:0] trace_rv_i_valid_ip ;
output [3:0] trace_rv_i_exception_ip ;
output [9:0] trace_rv_i_ecause_ip ;
output [3:0] trace_rv_i_interrupt_ip ;
output [63:0] trace_rv_i_tval_ip ;
output [1:0] rv_commit_valid ;
output [63:0] rv_commit_insn ;
output [63:0] rv_commit_pc ;
output [1:0] rv_commit_hart_id ;
output [3:0] rv_commit_priv_mode ;
output [1:0] rv_commit_gpr_wen_intent ;
output [1:0] rv_commit_gpr_wen ;
output [9:0] rv_commit_gpr_rd ;
output [63:0] rv_commit_gpr_wdata ;
output [1:0] rv_commit_csr_wen ;
output [23:0] rv_commit_csr_addr ;
output [63:0] rv_commit_csr_wdata ;
output [1:0] rv_commit_is_nonblock ;
output [1:0] rv_commit_is_nonblock_load ;
output [1:0] rv_commit_is_nonblock_div ;
output [1:0] rv_commit_waw_victim ;
output [1:0] rv_nb_waw_valid ;
output [63:0] rv_nb_waw_victim_insn ;
output [63:0] rv_nb_waw_victim_pc ;
output [1:0] rv_nb_waw_victim_hart_id ;
output [9:0] rv_nb_waw_victim_gpr_rd ;
output [1:0] rv_nb_waw_victim_is_load ;
output [1:0] rv_nb_waw_victim_is_div ;
output rv_nb_load_gpr_wen ;
output rv_nb_load_gpr_hart_id ;
output [4:0] rv_nb_load_gpr_rd ;
output [31:0] rv_nb_load_gpr_wdata ;
output rv_nb_div_gpr_wen ;
output rv_nb_div_gpr_hart_id ;
output [4:0] rv_nb_div_gpr_rd ;
output [31:0] rv_nb_div_gpr_wdata ;
output lsu_axi_awvalid ;
input lsu_axi_awready ;
output [3:0] lsu_axi_awid /* synthesis syn_tristate = 1 */ ;
output [31:0] lsu_axi_awaddr ;
output [3:0] lsu_axi_awregion ;
output [7:0] lsu_axi_awlen ;
output [2:0] lsu_axi_awsize ;
output [1:0] lsu_axi_awburst ;
output lsu_axi_awlock ;
output [3:0] lsu_axi_awcache ;
output [2:0] lsu_axi_awprot ;
output [3:0] lsu_axi_awqos ;
output lsu_axi_wvalid ;
input lsu_axi_wready ;
output [63:0] lsu_axi_wdata ;
output [7:0] lsu_axi_wstrb ;
output lsu_axi_wlast ;
input lsu_axi_bvalid ;
output lsu_axi_bready ;
input [1:0] lsu_axi_bresp ;
input [3:0] lsu_axi_bid ;
output lsu_axi_arvalid ;
input lsu_axi_arready ;
output [3:0] lsu_axi_arid /* synthesis syn_tristate = 1 */ ;
output [31:0] lsu_axi_araddr ;
output [3:0] lsu_axi_arregion ;
output [7:0] lsu_axi_arlen ;
output [2:0] lsu_axi_arsize ;
output [1:0] lsu_axi_arburst ;
output lsu_axi_arlock ;
output [3:0] lsu_axi_arcache ;
output [2:0] lsu_axi_arprot ;
output [3:0] lsu_axi_arqos ;
input lsu_axi_rvalid ;
output lsu_axi_rready ;
input [3:0] lsu_axi_rid ;
input [63:0] lsu_axi_rdata ;
input [1:0] lsu_axi_rresp ;
input lsu_axi_rlast ;
output ifu_axi_awvalid ;
input ifu_axi_awready ;
output [3:0] ifu_axi_awid ;
output [31:0] ifu_axi_awaddr ;
output [3:0] ifu_axi_awregion ;
output [7:0] ifu_axi_awlen ;
output [2:0] ifu_axi_awsize ;
output [1:0] ifu_axi_awburst ;
output ifu_axi_awlock ;
output [3:0] ifu_axi_awcache ;
output [2:0] ifu_axi_awprot ;
output [3:0] ifu_axi_awqos ;
output ifu_axi_wvalid ;
input ifu_axi_wready ;
output [63:0] ifu_axi_wdata ;
output [7:0] ifu_axi_wstrb ;
output ifu_axi_wlast ;
input ifu_axi_bvalid ;
output ifu_axi_bready ;
input [1:0] ifu_axi_bresp ;
input [3:0] ifu_axi_bid ;
output ifu_axi_arvalid ;
input ifu_axi_arready ;
output [3:0] ifu_axi_arid ;
output [31:0] ifu_axi_araddr ;
output [3:0] ifu_axi_arregion ;
output [7:0] ifu_axi_arlen ;
output [2:0] ifu_axi_arsize ;
output [1:0] ifu_axi_arburst ;
output ifu_axi_arlock ;
output [3:0] ifu_axi_arcache ;
output [2:0] ifu_axi_arprot ;
output [3:0] ifu_axi_arqos ;
input ifu_axi_rvalid ;
output ifu_axi_rready ;
input [3:0] ifu_axi_rid ;
input [63:0] ifu_axi_rdata ;
input [1:0] ifu_axi_rresp ;
input ifu_axi_rlast ;
output sb_axi_awvalid ;
input sb_axi_awready ;
output [0:0] sb_axi_awid ;
output [31:0] sb_axi_awaddr ;
output [3:0] sb_axi_awregion ;
output [7:0] sb_axi_awlen ;
output [2:0] sb_axi_awsize ;
output [1:0] sb_axi_awburst ;
output sb_axi_awlock ;
output [3:0] sb_axi_awcache ;
output [2:0] sb_axi_awprot ;
output [3:0] sb_axi_awqos ;
output sb_axi_wvalid ;
input sb_axi_wready ;
output [63:0] sb_axi_wdata ;
output [7:0] sb_axi_wstrb ;
output sb_axi_wlast ;
input sb_axi_bvalid ;
output sb_axi_bready ;
input [1:0] sb_axi_bresp ;
input [0:0] sb_axi_bid ;
output sb_axi_arvalid ;
input sb_axi_arready ;
output [0:0] sb_axi_arid ;
output [31:0] sb_axi_araddr ;
output [3:0] sb_axi_arregion ;
output [7:0] sb_axi_arlen ;
output [2:0] sb_axi_arsize ;
output [1:0] sb_axi_arburst ;
output sb_axi_arlock ;
output [3:0] sb_axi_arcache ;
output [2:0] sb_axi_arprot ;
output [3:0] sb_axi_arqos ;
input sb_axi_rvalid ;
output sb_axi_rready ;
input [0:0] sb_axi_rid ;
input [63:0] sb_axi_rdata ;
input [1:0] sb_axi_rresp ;
input sb_axi_rlast ;
input dma_axi_awvalid ;
output dma_axi_awready ;
input [0:0] dma_axi_awid ;
input [31:0] dma_axi_awaddr ;
input [2:0] dma_axi_awsize ;
input [2:0] dma_axi_awprot ;
input [7:0] dma_axi_awlen ;
input [1:0] dma_axi_awburst ;
input dma_axi_wvalid ;
output dma_axi_wready ;
input [63:0] dma_axi_wdata ;
input [7:0] dma_axi_wstrb ;
input dma_axi_wlast ;
output dma_axi_bvalid ;
input dma_axi_bready ;
output [1:0] dma_axi_bresp ;
output [0:0] dma_axi_bid ;
input dma_axi_arvalid ;
output dma_axi_arready ;
input [0:0] dma_axi_arid ;
input [31:0] dma_axi_araddr ;
input [2:0] dma_axi_arsize ;
input [2:0] dma_axi_arprot ;
input [7:0] dma_axi_arlen ;
input [1:0] dma_axi_arburst ;
output dma_axi_rvalid ;
input dma_axi_rready ;
output [0:0] dma_axi_rid ;
output [63:0] dma_axi_rdata ;
output [1:0] dma_axi_rresp ;
output dma_axi_rlast ;
input lsu_bus_clk_en ;
input ifu_bus_clk_en ;
input dbg_bus_clk_en ;
input dma_bus_clk_en ;
input [95:0] dccm_ext_in_pkt ;
input [47:0] iccm_ext_in_pkt ;
input [23:0] btb_ext_in_pkt ;
input [95:0] ic_data_ext_in_pkt ;
input [47:0] ic_tag_ext_in_pkt ;
input [1:0] timer_int ;
input [1:0] soft_int ;
input [127:1] extintsrc_req ;
output [3:0] dec_tlu_perfcnt0 ;
output [3:0] dec_tlu_perfcnt1 ;
output [3:0] dec_tlu_perfcnt2 ;
output [3:0] dec_tlu_perfcnt3 ;
input jtag_tck ;
input jtag_tms ;
input jtag_tdi ;
input jtag_trst_n ;
output jtag_tdo ;
input [31:4] core_id ;
input [1:0] mpc_debug_halt_req ;
input [1:0] mpc_debug_run_req ;
input [1:0] mpc_reset_run_req ;
output [1:0] mpc_debug_halt_ack ;
output [1:0] mpc_debug_run_ack ;
output [1:0] debug_brkpt_status ;
output [1:0] dec_tlu_mhartstart ;
input [1:0] i_cpu_halt_req ;
output [1:0] o_cpu_halt_ack ;
output [1:0] o_cpu_halt_status ;
output [1:0] o_debug_mode_status ;
input [1:0] i_cpu_run_req ;
output [1:0] o_cpu_run_ack ;
input scan_mode ;
input mbist_mode ;
endmodule
