`timescale 1ns/1ps

module system_tx_arbiter (
  input  logic       clk,
  input  logic       resetn,
  input  logic       prefer_log,

  input  logic [7:0] info_tdata,
  input  logic       info_tvalid,
  input  logic       info_tlast,
  output logic       info_tready,

  input  logic [7:0] log_tdata,
  input  logic       log_tvalid,
  input  logic       log_tlast,
  output logic       log_tready,

  output logic [7:0] m_axis_tdata,
  output logic       m_axis_tvalid,
  output logic       m_axis_tlast,
  input  logic       m_axis_tready
);
  logic in_frame;
  logic selected_log;
  logic choose_log;

  always_comb begin
    if (in_frame)
      choose_log = selected_log;
    else if (prefer_log)
      choose_log = log_tvalid || !info_tvalid;
    else
      choose_log = !info_tvalid && log_tvalid;

    m_axis_tdata  = choose_log ? log_tdata  : info_tdata;
    m_axis_tvalid = choose_log ? log_tvalid : info_tvalid;
    m_axis_tlast  = choose_log ? log_tlast  : info_tlast;
    log_tready    = choose_log  ? m_axis_tready : 1'b0;
    info_tready   = !choose_log ? m_axis_tready : 1'b0;
  end

  always_ff @(posedge clk) begin
    if (!resetn) begin
      in_frame     <= 1'b0;
      selected_log <= 1'b0;
    end else if (m_axis_tvalid && m_axis_tready) begin
      if (!in_frame)
        selected_log <= choose_log;
      if (m_axis_tlast)
        in_frame <= 1'b0;
      else
        in_frame <= 1'b1;
    end
  end
endmodule
