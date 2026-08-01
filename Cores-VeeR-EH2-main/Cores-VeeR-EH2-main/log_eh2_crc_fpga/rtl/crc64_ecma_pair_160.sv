// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module crc64_ecma_160_seed #(
    parameter logic [63:0] INIT = 64'h0000_0000_0000_0000
) (
    input  logic [159:0] data,
    output logic [63:0]  crc
);
    localparam logic [63:0] POLY = 64'h42F0_E1EB_A9EA_3693;
    logic [63:0] work;
    integer bit_index;

    // CRC-64/ECMA-182, non-reflected.  The 160-bit instruction structure is
    // consumed from bit 159 down to bit 0 (Word0 first, MSB first).
    always_comb begin
        work = INIT;
        for (bit_index = 159; bit_index >= 0; bit_index = bit_index - 1) begin
            if (work[63] ^ data[bit_index])
                work = {work[62:0], 1'b0} ^ POLY;
            else
                work = {work[62:0], 1'b0};
        end
        crc = work;
    end
endmodule

module crc64_ecma_pair_160 (
    input  logic [159:0] data,
    output logic [63:0]  c0,
    output logic [63:0]  c1
);
    // CRC is affine with respect to its initial state. For a fixed 160-bit
    // message length, CRC(data, all-ones) equals CRC(data, zero) XOR the
    // constant below. This produces the exact second CRC while using one
    // data-dependent CRC network instead of duplicating all 160 stages.
    localparam logic [63:0] INIT_ONES_160_DELTA =
        64'hC2D8_22ED_D2DB_FBB1;

    crc64_ecma_160_seed #(
        .INIT(64'h0000_0000_0000_0000)
    ) c0_i (
        .data(data),
        .crc (c0)
    );
    assign c1 = c0 ^ INIT_ONES_160_DELTA;
endmodule
