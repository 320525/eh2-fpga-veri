// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module crc_mix_accumulator #(
    parameter logic [63:0] K0 = 64'h9E37_79B9_7F4A_7C15,
    parameter logic [63:0] K1 = 64'hD1B5_4A32_D192_ED03
) (
    input  logic        clk,
    input  logic        rst_l,
    input  logic        in_valid,
    input  logic        in_last,
    input  logic [63:0] in_c0,
    input  logic [63:0] in_c1,
    input  logic [15:0] bank_package_number,

    output logic        result_valid,
    output logic [15:0] result_package_number,
    output logic [63:0] result_xor0,
    output logic [63:0] result_xor1,
    output logic [63:0] result_sum0,
    output logic [63:0] result_sum1,
    output logic [63:0] result_sum2,
    output logic [63:0] result_sum3,
    output logic [31:0] result_item_count
);
    logic stage_valid;
    logic stage_last;
    logic [63:0] stage_g0;
    logic [63:0] stage_g1;
    logic [63:0] stage_g2;
    logic [63:0] stage_g3;
    logic [15:0] stage_package;

    logic package_active;
    logic [15:0] active_package;
    logic [63:0] accum_xor0;
    logic [63:0] accum_xor1;
    logic [63:0] accum_sum0;
    logic [63:0] accum_sum1;
    logic [63:0] accum_sum2;
    logic [63:0] accum_sum3;
    logic [31:0] accum_count;

    function automatic logic [63:0] rotl64(
        input logic [63:0] value,
        input integer amount
    );
        rotl64 = (value << amount) | (value >> (64 - amount));
    endfunction

    // One-cycle G stage.  The pipeline accepts a new CRC pair every cycle.
    always_ff @(posedge clk or negedge rst_l) begin
        if (!rst_l) begin
            stage_valid   <= 1'b0;
            stage_last    <= 1'b0;
            stage_g0      <= 64'b0;
            stage_g1      <= 64'b0;
            stage_g2      <= 64'b0;
            stage_g3      <= 64'b0;
            stage_package <= 16'b0;
        end else begin
            stage_valid <= in_valid;
            if (in_valid) begin
                stage_last <= in_last;
                stage_g0 <= in_c0 + rotl64(in_c1, 17) + K0;
                stage_g1 <= in_c1 + rotl64(in_c0, 31) + K1;
                stage_g2 <= (in_c0 ^ rotl64(in_c1, 43)) + rotl64(in_c0, 11);
                stage_g3 <= (in_c1 ^ rotl64(in_c0, 29)) + rotl64(in_c1, 7);
                stage_package <= bank_package_number;
            end
        end
    end

    // Accumulation stage. All additions wrap modulo 2^64.
    always_ff @(posedge clk or negedge rst_l) begin
        if (!rst_l) begin
            package_active       <= 1'b0;
            active_package       <= 16'b0;
            accum_xor0           <= 64'b0;
            accum_xor1           <= 64'b0;
            accum_sum0           <= 64'b0;
            accum_sum1           <= 64'b0;
            accum_sum2           <= 64'b0;
            accum_sum3           <= 64'b0;
            accum_count          <= 32'b0;
            result_valid         <= 1'b0;
            result_package_number <= 16'b0;
            result_xor0          <= 64'b0;
            result_xor1          <= 64'b0;
            result_sum0          <= 64'b0;
            result_sum1          <= 64'b0;
            result_sum2          <= 64'b0;
            result_sum3          <= 64'b0;
            result_item_count    <= 32'b0;
        end else begin
            result_valid <= 1'b0;
            if (stage_valid) begin
                if (!package_active) begin
                    package_active <= 1'b1;
                    active_package <= stage_package;
                    accum_xor0 <= stage_g0;
                    accum_xor1 <= stage_g1;
                    accum_sum0 <= stage_g0;
                    accum_sum1 <= stage_g1;
                    accum_sum2 <= stage_g2;
                    accum_sum3 <= stage_g3;
                    accum_count <= 32'd1;
                end else begin
                    accum_xor0 <= accum_xor0 ^ stage_g0;
                    accum_xor1 <= accum_xor1 ^ stage_g1;
                    accum_sum0 <= accum_sum0 + stage_g0;
                    accum_sum1 <= accum_sum1 + stage_g1;
                    accum_sum2 <= accum_sum2 + stage_g2;
                    accum_sum3 <= accum_sum3 + stage_g3;
                    accum_count <= accum_count + 32'd1;
                end

                if (stage_last) begin
                    result_valid <= 1'b1;
                    result_package_number <= package_active ? active_package : stage_package;
                    result_xor0 <= package_active ? (accum_xor0 ^ stage_g0) : stage_g0;
                    result_xor1 <= package_active ? (accum_xor1 ^ stage_g1) : stage_g1;
                    result_sum0 <= package_active ? (accum_sum0 + stage_g0) : stage_g0;
                    result_sum1 <= package_active ? (accum_sum1 + stage_g1) : stage_g1;
                    result_sum2 <= package_active ? (accum_sum2 + stage_g2) : stage_g2;
                    result_sum3 <= package_active ? (accum_sum3 + stage_g3) : stage_g3;
                    result_item_count <= package_active ? (accum_count + 32'd1) : 32'd1;

                    package_active <= 1'b0;
                    active_package <= 16'b0;
                    accum_xor0 <= 64'b0;
                    accum_xor1 <= 64'b0;
                    accum_sum0 <= 64'b0;
                    accum_sum1 <= 64'b0;
                    accum_sum2 <= 64'b0;
                    accum_sum3 <= 64'b0;
                    accum_count <= 32'b0;
                end
            end
        end
    end
endmodule
