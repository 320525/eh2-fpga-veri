// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module eh2_crc_fpga_top (
    input  wire       sw3_1,
    input  wire       sw4_1,
    input  wire       core_clk_p,
    input  wire       core_clk_n,
    output wire [7:0] led
);
    wire board_resetn = sw3_1 & sw4_1;
    wire core_clk_ibuf;
    wire core_clk;
    wire mmcm_clkfb_raw;
    wire mmcm_clkfb;
    wire crc_clk_raw;
    wire crc_rd_clk;
    wire mmcm_locked;

    IBUFDS #(.DIFF_TERM("FALSE"), .IBUF_LOW_PWR("FALSE")) core_clk_ibuf_i (
        .I(core_clk_p), .IB(core_clk_n), .O(core_clk_ibuf)
    );
    BUFG core_clk_bufg_i (.I(core_clk_ibuf), .O(core_clk));

    MMCME4_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.000),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT_F(20.000),
        .CLKOUT0_DIVIDE_F(8.000),
        .STARTUP_WAIT("FALSE")
    ) crc_mmcm_i (
        .CLKIN1(core_clk), .CLKFBIN(mmcm_clkfb),
        .RST(~board_resetn), .PWRDWN(1'b0),
        .CLKFBOUT(mmcm_clkfb_raw), .CLKOUT0(crc_clk_raw),
        .LOCKED(mmcm_locked)
    );
    BUFG mmcm_fb_bufg_i (.I(mmcm_clkfb_raw), .O(mmcm_clkfb));
    BUFG crc_clk_bufg_i (.I(crc_clk_raw), .O(crc_rd_clk));

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *)
    logic [15:0] infra_reset_pipe = 16'b0;
    always_ff @(posedge core_clk or negedge board_resetn) begin
        if (!board_resetn)
            infra_reset_pipe <= 16'b0;
        else if (!mmcm_locked)
            infra_reset_pipe <= 16'b0;
        else
            infra_reset_pipe <= {infra_reset_pipe[14:0], 1'b1};
    end
    wire infra_rst_l = infra_reset_pipe[15];

    wire core_rst_l;
    wire crc_system_ready;
    wire pass_latched;
    wire fail_latched;
    wire activity_seen;
    wire hart1_commit_seen;
    wire [1:0] stopped;

    eh2_crc_soc #(
        .MEM_FILE("trace_1000_jump.mem64"),
        // The ELF contains 0x5a0 bytes of code at 0x8000_0000 and one
        // eight-byte data object at 0x8001_0000.  Avoid implementing the
        // unused 64 KiB address hole: 8 KiB BRAM plus one sparse data word
        // is sufficient for the exact FPGA program.
        .MEM_BYTES(8192),
        .SPARSE_AUX_ENABLE(1'b1),
        .SPARSE_AUX_ADDR(32'h8001_0000),
        .SPARSE_AUX_INIT(64'h2468_ace0_1357_9bdf),
        .RUN_HART_MASK(2'b01),
        .ENABLE_GOLDEN_CHECK(1'b1)
    ) soc_i (
        .core_clk(core_clk), .crc_rd_clk(crc_rd_clk),
        .infra_rst_l(infra_rst_l), .core_rst_l(core_rst_l),
        .crc_system_ready(crc_system_ready),
        .pass_latched(pass_latched), .fail_latched(fail_latched),
        .activity_seen(activity_seen),
        .hart1_commit_seen(hart1_commit_seen), .stopped(stopped),
        .commit_count(), .generated_count(), .result_valid(),
        .result_package_number(), .result_xor0(), .result_xor1(),
        .result_sum0(), .result_sum1(), .result_sum2(), .result_sum3(),
        .result_item_count()
    );

    // The reference board LEDs are active high.  Keep every LED low during
    // power-up, reset and program execution.  Once the final comparison has
    // completed, light exactly one status LED; failure has priority so that
    // a late error can never leave both PASS and FAIL illuminated.
    assign led = (!board_resetn || !infra_rst_l) ? 8'b0000_0000 :
                 fail_latched                    ? 8'b0000_0010 :
                 pass_latched                    ? 8'b0000_0001 :
                                                   8'b0000_0000;
endmodule
