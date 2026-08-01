# VeeR-EH2 双 DDR4 启动与状态显示工程

本工程面向 VeriTiger-V19P-A14，目标器件为 `xcvu19p_CIV-fsva3824-1-e`。系统包含两块 DDR4：

- `ddr0_i`：第一块 DDR4（板卡 DDR4-1），保存程序并连接 EH2 IFU 指令端口。
- `ddr1_i`：第二块 DDR4（板卡 DDR4-2），保存数据并连接 EH2 LSU 访存端口。

两块 DDR 均先由一次性 ATG 写入初始化内容，再由独立的 512 位 AXI 回读检查器核对。只有写入和回读全部正确后，总线所有权才会永久交给 EH2。

## EH2 Synplify 网表

Vivado 综合和实现使用 Synplify 生成的 EH2 EDIF 网表：

`build/synplify/rev_1/eh2_veer_wrapper.edf`

集成方式如下：

1. `rtl/eh2_veer_wrapper_synplify_stub.v` 只向 Vivado 声明 `eh2_veer_wrapper` 的黑盒端口。
2. `scripts/synplify_netlist_common.tcl` 将 EDIF 设置为参与综合和实现。
3. `D:/eh2_fpga/source/eh2_design` 下的 EH2 RTL 保留用于行为仿真，但全部设置为不参与 Vivado 综合。
4. 每次运行综合或实现前，脚本都会检查目标器件、EDIF、黑盒声明和 EH2 RTL 的 `USED_IN_SYNTHESIS` 状态；检查不通过则停止。

现有 Vivado 综合日志已经确认解析了该 EDIF，网表目标器件为 `xcvu19p-fsva3824-1-e`。

## 启动顺序和总线所有权

每块 DDR 的总线所有权只允许单向切换：

```text
MIG 完成校准
    -> 一次性 ATG 写入
    -> ATG 永久复位
    -> 初始化内容回读检查
    -> 总线永久交给 EH2
```

DDR0 回读检查覆盖程序地址 `0x00000000-0x00000058`；DDR1 回读检查覆盖数据地址 `0x00010000-0x0001000F`。任何 AXI `RID`、`RRESP`、`RLAST` 或数据错误都会使对应初始化 LED 保持熄灭，并阻止 EH2 解除复位。

DDR0 通过后连接 EH2 IFU；DDR1 通过后连接 EH2 LSU。ATG 完成后复位会一直保持有效，不能重新取得总线。

程序完成终态写入后，DDR1 总线再永久切换给最终结果检查器，检查地址 `0x0001000C` 是否为 `0x000001BC`。

## EH2 TCM 初始化

EH2 在 debug halt 状态下通过自身 DMA AXI 从接口清零完整的 64 KiB DCCM 和 64 KiB ICCM：

- DCCM：`0xF0040000-0xF004FFFF`
- ICCM：`0xEE000000-0xEE00FFFF`

所有写入均经过 EH2 正常 TCM 存储通路，因此 ECC 由处理器硬件按正常写入方式生成。清零完成、写响应无错误且 `mpc_debug_run_ack` 有效后，EH2 才从复位向量 0 开始运行。

## 八颗 LED 定义

手册表 7-1 给出的八颗用户 LED 均为高电平点亮。RTL 使用一个 `led[7:0]` 向量，复位有效期间全部强制熄灭；事件类状态采用锁存显示，直到下一次系统复位。

系统包含独立的上电复位保持链。FPGA 配置完成后，即使两个板卡复位按键已经处于释放状态，内部复位仍保持至少 16 个 ATG 时钟周期；在此期间八颗 LED 强制输出 0，两个 MIG、两个 ATG 和 EH2 都不能启动。按下 KEY-T1 或 KEY-T2 会异步重新置位该复位链并立即熄灭八颗 LED，松开后重新等待 16 个 ATG 时钟周期再启动。

| RTL | 板卡标识 | FPGA 管脚 | 点亮含义 |
|---|---|---|---|
| `led[0]` | LED-T1 | BE22 | DDR0 的 ATG 写入完成且无错误，并从 DDR0 回读程序内容全部正确 |
| `led[1]` | LED-T2 | BG23 | DDR1 的 ATG 初始化完成且无错误，并从 DDR1 回读初始化数据全部正确 |
| `led[2]` | LED-T3 | BJ20 | EH2 IFU 已发出取指请求，且取指 AXI AR 通道完成握手 |
| `led[3]` | LED-T4 | BN19 | 第一块 DDR 已返回正常取指数据；数据已经过 512→64 位宽转换和 AXI 时钟转换，到达 EH2 IFU 接口并完成 R 通道握手 |
| `led[4]` | LED-B1 | U34 | EH2 LSU 已发出数据读取请求，且 LSU AXI AR 通道完成握手 |
| `led[5]` | LED-B2 | T37 | 第二块 DDR 已返回正常读取数据；数据已经过 512→64 位宽转换和 AXI 时钟转换，到达 EH2 LSU 接口并完成 R 通道握手 |
| `led[6]` | LED-B3 | K37 | EH2 LSU 已发出写请求，且 LSU AXI AW 通道完成握手 |
| `led[7]` | LED-B4 | M39 | EH2 TCM 初始化无错误，最终检查器从 DDR1 读到 `0x000001BC`，终态校验通过 |

LED3 和 LED5 的条件都取自处理器一侧的 64 位 AXI 接口，而不是 MIG 的 512 位接口。因此它们可以直接判断读数据是否真正穿过 Xilinx AXI Data Width Converter 和 AXI Clock Converter 到达 EH2。

正常运行的最终状态为：

```text
led[7:0] = 8'b1111_1111
```

典型故障定位：

- LED0 熄灭：DDR0 ATG 写入、DDR0 回读或程序内容检查未通过。
- LED1 熄灭：DDR1 ATG 写入、DDR1 回读或数据内容检查未通过。
- LED2 亮而 LED3 灭：EH2 已发出取指地址，但取指数据没有正常穿过 DDR0、位宽转换和时钟转换到达 IFU。
- LED3 亮而 LED4 灭：EH2 已取得并执行部分指令，但还没有发出程序所需的 LSU 读取。
- LED4 亮而 LED5 灭：数据读地址已发出，但 DDR1 数据没有正常到达 LSU。
- LED5 亮而 LED6 灭：数据读取已经完成，但处理器尚未执行到写操作。
- LED6 亮而 LED7 灭：处理器已经写 DDR1，但终态写响应或最终 DDR 回读值未通过检查。

## 时钟

| 板卡时钟 | 频率 | FPGA 管脚 P/N | 用途 |
|---|---:|---|---|
| GCCLKT0 | 50 MHz | BY44 / CA44 | EH2 `core_clk` |
| GCCLKT1 | 100 MHz | BN55 / BP55 | ATG 管理时钟 |
| GCCLKT3 | 76.15 MHz | BN26 / BP26 | DDR0 MIG 参考时钟 |
| GCCLKB3 | 76.15 MHz | F32 / E32 | DDR1 MIG 参考时钟 |

EH2 外部差分时钟使用 `IBUFDS + BUFG`。当前 XDC 按 50 MHz、20 ns 周期进行静态时序分析；`create_clock` 只定义时序要求，不会改变板卡时钟芯片的实际输出频率。

## 主要文件

- 顶层和状态逻辑：`rtl/eh2_dual_ddr_top.sv`
- ATG 初始化回读和终态检查：`rtl/ddr_result_checker.sv`
- EH2 硬件 TCM 初始化：`rtl/eh2_hw_init.sv`
- AXI 时钟/位宽转换封装：`rtl/axi32_to_512_cdc.sv`、`rtl/axi64_to_512_cdc.sv`
- 永久所有权切换：`rtl/axi_owner_mux2.sv`
- 管脚和时钟约束：`constraints/eh2_dual_ddr_v19p.xdc`
- Synplify 网表集成检查：`scripts/synplify_netlist_common.tcl`

## 重新生成

使用 Vivado 2023.2：

1. 运行 `scripts/integrate_synplify_netlist.tcl`，将最新 Synplify EDIF 绑定到现有 Vivado 工程。
2. 运行 `scripts/run_synthesis.tcl` 重新综合。
3. 运行 `scripts/run_implementation.tcl` 完成布局布线、时序报告和比特流生成。
4. 如需仿真，再运行 `scripts/run_pre_sim.tcl` 和 `scripts/run_post_synth_sim.tcl`。

## 本次验证结果

2026-07-25 已对本次八灯和初始化回读版本重新完成全部流程：

- 前仿通过：复位期间 `led[7:0] = 8'b0000_0000`；DDR0/DDR1 初始化回读、EH2 取指、LSU 读写和最终 `0x000001BC` 检查依次通过，终态为 `8'b1111_1111`。
- 综合通过：Vivado 已解析并使用 `build/synplify/rev_1/eh2_veer_wrapper.edf`，目标器件为 `xcvu19p_CIV-fsva3824-1-e`。
- 实现与比特流生成通过：设计为 Fully Routed，路由错误为 0。
- 最终静态时序通过：`WNS = +0.293 ns`、`TNS = 0`、`WHS = +0.010 ns`、`THS = 0`；EH2 `core_clk` 在实现报告中为 `50.000 MHz`。
- AXI 总线偏斜约束通过：要求 `3.752 ns`，实际 `0.497 ns`，余量 `+3.255 ns`。
- 实现 DRC 没有 Error 或 Critical Warning；现有条目均为 Warning/Advisory，主要来自 EH2 Synplify 网表优化建议和 MIG/IO 结构检查。
- 交付比特流：`output/bitstreams/eh2_dual_ddr_gclkt0_50mhz_led8_verified.bit`
- SHA-256：`621B4136F51ABA837993441A166DD40BEEA303251E3A7F44A0E16BB634457B95`
