`timescale 1ps / 1ps

// XSim treats this empty bidirectional module as an ideal short.  Other
// simulators use the Verilog tran primitive below.
`ifdef XILINX_SIMULATOR
module short(in1, in1);
  inout in1;
endmodule
`endif

// DDR4-2400, 1-rank x72 ECC SODIMM model wrapper generated from the
// parameters of ddr4_0 (nine x8 devices, 8 Gb density per device).
module ddr4_sodimm_x72_model (
  input  wire        act_n,
  input  wire [16:0] adr,
  input  wire [1:0]  ba,
  input  wire [1:0]  bg,
  input  wire [0:0]  cke,
  input  wire [0:0]  odt,
  input  wire [0:0]  cs_n,
  input  wire [0:0]  ck_t,
  input  wire [0:0]  ck_c,
  input  wire        reset_n,
  inout  wire [8:0]  dm_dbi_n,
  inout  wire [71:0] dq,
  inout  wire [8:0]  dqs_c,
  inout  wire [8:0]  dqs_t
);

  localparam integer ADDR_WIDTH         = 17;
  localparam integer DQ_WIDTH           = 72;
  localparam integer DRAM_WIDTH         = 8;
  localparam integer NUM_PHYSICAL_PARTS = DQ_WIDTH / DRAM_WIDTH;

  localparam [2:0] WR = 3'b100;
  localparam [2:0] RD = 3'b101;

  import arch_package::*;
  parameter UTYPE_density CONFIGURED_DENSITY = _8G;

  bit en_model;
  tri model_enable = en_model;

  initial begin
    en_model = 1'b0;
    #5 en_model = 1'b1;
  end

  // The DDR4 model consumes A[13:0] separately from the multiplexed DDR4
  // command pins A[16:14].  During WR/RD, mask the column-only fields exactly
  // as done by the MIG-generated example testbench.
  reg [ADDR_WIDTH-1:0] adr_mod;
  always @(*) begin
    if (act_n) begin
      casez (adr[16:14])
        WR, RD:  adr_mod = adr & 17'h1C7FF;
        default: adr_mod = adr;
      endcase
    end
    else begin
      adr_mod = adr;
    end
  end

  DDR4_if #(.CONFIGURED_DQ_BITS(8))
    iDDR4[0:NUM_PHYSICAL_PARTS-1]();

  genvar device_index;
  genvar bit_index;
  generate
    for (device_index = 0;
         device_index < NUM_PHYSICAL_PARTS;
         device_index = device_index + 1) begin : g_device

      ddr4_model #(
        .CONFIGURED_DQ_BITS(8),
        .CONFIGURED_DENSITY(CONFIGURED_DENSITY)
      ) memory_model_i (
        .model_enable(model_enable),
        .iDDR4(iDDR4[device_index])
      );

      for (bit_index = 0;
           bit_index < DRAM_WIDTH;
           bit_index = bit_index + 1) begin : g_dq
`ifdef XILINX_SIMULATOR
        short dq_short(
          iDDR4[device_index].DQ[bit_index],
          dq[bit_index + device_index * DRAM_WIDTH]
        );
`else
        tran dq_short(
          iDDR4[device_index].DQ[bit_index],
          dq[bit_index + device_index * DRAM_WIDTH]
        );
`endif
      end

`ifdef XILINX_SIMULATOR
      short dqs_t_short(iDDR4[device_index].DQS_t,
                        dqs_t[device_index]);
      short dqs_c_short(iDDR4[device_index].DQS_c,
                        dqs_c[device_index]);
      short dm_short(iDDR4[device_index].DM_n,
                     dm_dbi_n[device_index]);
`else
      tran dqs_t_short(iDDR4[device_index].DQS_t,
                       dqs_t[device_index]);
      tran dqs_c_short(iDDR4[device_index].DQS_c,
                       dqs_c[device_index]);
      tran dm_short(iDDR4[device_index].DM_n,
                    dm_dbi_n[device_index]);
`endif

      assign iDDR4[device_index].BG        = bg;
      assign iDDR4[device_index].BA        = ba;
      assign iDDR4[device_index].ADDR_17   = 1'b0;
      assign iDDR4[device_index].ADDR      = adr_mod[13:0];
      assign iDDR4[device_index].CS_n      = cs_n[0];
      assign iDDR4[device_index].CK        = {ck_t[0], ck_c[0]};
      assign iDDR4[device_index].ACT_n     = act_n;
      assign iDDR4[device_index].RAS_n_A16 = adr_mod[16];
      assign iDDR4[device_index].CAS_n_A15 = adr_mod[15];
      assign iDDR4[device_index].WE_n_A14  = adr_mod[14];
      assign iDDR4[device_index].CKE       = cke[0];
      assign iDDR4[device_index].ODT       = odt[0];
      assign iDDR4[device_index].PARITY    = 1'b0;
      assign iDDR4[device_index].TEN       = 1'b0;
      assign iDDR4[device_index].ZQ        = 1'b1;
      assign iDDR4[device_index].PWR       = 1'b1;
      assign iDDR4[device_index].VREF_CA   = 1'b1;
      assign iDDR4[device_index].VREF_DQ   = 1'b1;
      assign iDDR4[device_index].RESET_n   = reset_n;
    end
  endgenerate

endmodule
