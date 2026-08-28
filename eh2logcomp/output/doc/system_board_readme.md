# EH2LOGCOMP 板级、时钟、引脚、时序与运行说明

## 1. 最终硬件产物

| 文件 | 大小 | SHA-256 |
| --- | ---: | --- |
| `eh2logcomp_2slot.bit` | 199112137 Byte | `EF901C78E23654CBC8741E3DDA76C6D967BC92631A15A882FCA45CF745A150BB` |
| `eh2logcomp_2slot_routed.dcp` | 201083512 Byte | `A17FA0DA86643C92840675E234045E0F15D2B7179BEA1E009F9AD15B77D0621E` |
| `stress_200k_dualhart_system.bin` | 800640 Byte | `5D073F32602F986E6AE253F425046271C4255402067632DA7C6FFD43E4A1CCFC` |
| `riscvdv_10k_top/riscvdv_10k_program.bin` | 88040 Byte | `065E5AF9C246A612F6504B1A77F2C7DF9FFFE4F19FA30C914C2FABA9C351C70F` |

同目录 `SHA256SUMS.txt` 可用于烧写或拷贝前后的完整性复核。`eh2logcomp_2slot_postroute_timing_fixed.dcp` 是 2026-08-15 的历史实现产物，不对应当前位流；当前签核基准必须使用上表的 `eh2logcomp_2slot_routed.dcp`。

目标器件为 VeriTiger-V19P-A14，`xcvu19p_CIV-fsva3824-1-e`。Vivado 版本为 2023.2。BIT 为脚本明确生成的未压缩配置文件。2026-08-25 当前最终报告位于 `output/board/reports_latest`；不要把历史 `reports_postroute_fix` 中非法 1250 ps 试验的数字当作最终结果。

## 2. 外部时钟和主要引脚

### 2.1 时钟/复位/LED

| 顶层信号 | 管脚 | 电气 | 频率/作用 |
| --- | --- | --- | --- |
| `core_clk_p/n` | BY44/CA44 | LVDS | 50 MHz，EH2/Info 捕获；经 MMCM 产生 125 MHz TX |
| `atg_clk_p/n` | BN55/BP55 | LVDS | 100 MHz，六状态控制器、MAC AXI 配置、系统信息路径、ATG 控制 |
| `refclk_p/n` | CA36/CA37 | LVDS | 333.333 MHz，TEMAC RGMII IDELAY/ODELAY 参考和校准 |
| `c0_sys_clk_p/n` | BN26/BP26 | MIG 定义 | 76.15 MHz DDR0 MIG 参考输入 |
| `c1_sys_clk_p/n` | F32/E32 | MIG 定义 | 76.15 MHz DDR1 MIG 参考输入 |
| `sw3_1/sw4_1` | BU21/BU28 | LVCMOS12 | 两者都为 1 才释放板级复位 |

LED 均为 LVCMOS12、active high：BE22/BG23/BJ20/BN19/U34/T37/K37/M39 对应 LED[0..7]。

- LED0：ERROR；
- LED1：MAC 配置完成且无配置错；
- LED2：PHY 初始化成功；
- LED3/4：DDR0/DDR1 MIG calibration done；
- LED5/6/7：PROGRAM_WRITE/EXECUTE/END。

### 2.2 以太网 J22/HSPI2-057-UTEH-A20

| 信号 | 管脚 | 信号 | 管脚 |
| --- | --- | --- | --- |
| TXD0..3 | BJ47, BE44, BF41, BF42 | RXD0..3 | BH43, BK44, BL42, BR43 |
| TX_CTL | BN49 | RX_CTL | BM44 |
| TXC | BN45 | RXC | BJ43 |
| MDC | BJ42 | MDIO | BM42 |
| PHY_RESETN | BM47 |  |  |

全部 RGMII/MDIO/PHY reset 使用 LVCMOS18。TX 数据为 FAST slew；MDC/MDIO/reset 为 SLOW slew。BJ43 是 clock-capable RXC 输入。

DDR DQ/DQS/地址/控制的完整 264 个板级管脚不在本文重复，权威定义是 `constraints/eh2_dual_ddr_v19p.xdc` 和 MIG XCI；不要手工复制或只约束部分 DDR 管脚。

## 3. 内部时钟用途

| 时钟 | 实际频率 | 用途 |
| --- | ---: | --- |
| `core_clk` | 50 MHz | EH2、双 hart sequence/WAW/Info 生成、Info FIFO 写侧、ATG 发起侧 |
| `ctrl_clk`/`atg_clk` | 100 MHz | 状态机、错误监测、MAC/PHY 管理、程序帧解析与程序 DMA 控制、系统信息 FIFO |
| `clk125` | 125 MHz | 由 50 MHz 经 MMCM 产生；TEMAC TX 核、RGMII TXD/TXC、TX client FIFO 读侧、Info 双帧槽发送侧 |
| `rgmii_rxc`/TEMAC RX clock | 链路恢复 125 MHz | RGMII RX DDR 采样和 MAC RX 侧；与 100 MHz 控制域异步 |
| `refclk` | 333.333 MHz | IDELAYE3/ODELAYE3 的延迟标定参考，不承载以太网帧业务数据 |
| DDR0 `ui_clk` | 266.525 MHz | DDR0 512-bit AXI UI，程序/检查/清零/EH2 IFU+LSU |
| DDR1 `ui_clk` | 266.525 MHz | DDR1 512-bit AXI UI，Info FIFO 读侧、Info 写/读 DMA |
| MDC | 1.667 MHz | 由 TEMAC 管理逻辑产生，仅用于 MDIO PHY 寄存器读写 |

DDR 的外部参考时钟来自板卡，DDR 存储器 CK 和 266.525 MHz UI clock 由各自 MIG 内部 MMCM/PLL 产生。MIG XCI 参数：输入周期 13132 ps，DDR 时间周期 938 ps，SODIMM `MTA9ASF1G72HZ-2G6`，数据宽 72 bit；业务侧数据宽为 512 bit。

## 4. RGMII RX/TX 时序策略

### 4.1 PHY 和 FPGA 延迟

DP83867 工作在 RGMII_ID：

- TX clock internal delay code 7 = 2.00 ns；
- RX clock internal delay code 3 = 1.00 ns；
- FPGA RGMII RX 的 IDELAYE3 `DELAY_VALUE=1100 ps`；
- FPGA TXC edge-aligned 输出，所需 TX skew 由 PHY 提供。

这样做避免了原先 PHY/FPGA 采样相位随复位落到数据眼边缘、导致“同一次复位后每轮都好或每轮都坏”的问题。约束按当前 PHY 延迟重新标定：TX output delay max/min 为 -1/-3 ns（含上/下降沿），RX input delay max/min 为 0/-1 ns（含上/下降沿）。这些数值必须与 MDIO 实际写入完全一致。

实现后的 RXC 全局时钟根固定为 `X2Y2`。原始 `X3Y2` 路由使 5 条 RGMII 输入保持路径最差为 `-0.074 ns`；在不改变 PHY 延迟、IDELAY、数据路由或功能 RTL 的前提下，对 `X3Y1/X2Y2/X2Y1/X1Y2/X1Y1` 分别从同一 routed DCP 执行“解布线 RXC 网 → `update_clock_routing` → 只补布 RXC 网”的合法扫描。`X2Y2` 得到最均衡的外部输入裕量：setup `+0.254 ns`、hold `+0.306 ns`。其他候选结果为：

| RXC root | RGMII setup | RGMII hold | 结论 |
| --- | ---: | ---: | --- |
| `X3Y1` | +0.411 ns | -0.003 ns | hold 失败 |
| `X2Y2` | +0.254 ns | +0.306 ns | 最终采用 |
| `X2Y1` | +0.215 ns | +0.377 ns | 合法但最小裕量较小 |
| `X1Y2` | +0.058 ns | +0.686 ns | setup 太窄 |
| `X1Y1` | +0.019 ns | +0.757 ns | setup 太窄 |

IDELAYE3 在本器件和 333.333 MHz 参考时钟下的合法最大值是 1100 ps。曾尝试的 1250 ps 虽能让时序报告显示正 hold，却被 `AVAL-174` 明确判定非法，绝不能用于生成位流。直接使用普通 `route_design -auto_delay` 改已路由时钟网也会得到错误/不平衡结果；UltraScale+ 必须先重建 clock gap tree，再补齐剩余路由，并检查 `RTSTAT-2` 不存在。

### 4.2 确定性 RX 放行

系统不会在 PHY 声称 link up 后立刻开放 RX client FIFO。必须同时满足：

- 全局 reset 已释放；
- 333.333 MHz 延迟校准 guard 完成（硬件 100000 个控制周期）；
- PHY 初始化成功和链路稳定轮询通过；
- RGMII RX clock 在其本地域累计稳定边沿；
- 稳定信号同步回 100 MHz 控制域。

只有 `rgmii_rx_ready=1` 才释放 RX client reset，PRECONFIG 的 `init_ready` 也要求该信号。TEMAC 丢弃的 FCS 错帧会产生 pulse 和 32-bit 累加计数，并立即报告 `66660075`。

## 5. 复位和 CDC

### 5.1 全局复位

`sw3_1 && sw4_1` 是电平型 base reset。MMCM lock 后还经过 16 个 100 MHz 周期同步放行。END 正常完成或 ERROR 收到主机停止确认后，supervisor 把 `hard_resetn` 拉低 64 个 100 MHz 周期（约 640 ns），相当于对整个系统执行硬复位流程；之后重新从 PRECONFIG 初始化 MAC、PHY、MIG 和数据通路。

复位不通过 AXI 总线发送。AXI Clock Converter、Data Width Converter、DataMover、FIFO、MIG 用户接口和自研模块都有独立 reset/aresetn 端口，顶层分别连接。多数时钟域使用异步拉低、同步释放；MIG 用户域还与各自 `ui_clk_sync_rst`/calibration 状态共同形成本地 reset。

### 5.2 跨时钟域

- 64-bit EH2 AXI 到 512-bit MIG：Xilinx AXI Clock Converter + Data Width Converter；
- Info 数据：每 hart XPM async FIFO，Gray pointer 同步并受 bus-skew 约束；
- 100 MHz 系统码到 125 MHz：异步 code FIFO；
- 双帧槽：payload 稳定后翻转 per-slot publish toggle，TX 完整读完后翻转 release toggle；
- 单脉冲启动/完成：toggle event CDC；
- 状态/计数：源域先寄存，单 bit 多级同步；Gray 编码计数跨域后再解码；
- DDR owner：100 MHz one-hot 寄存后同步到各 UI 域，并只在前一主设备 idle 后切换。

不要用普通两级触发器逐 bit 同步总线后直接解释为同一个数值；这会产生撕裂数据。

## 6. 输入/输出帧字段

### 6.1 主机到 FPGA 程序帧

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 6 | 目的 `02:12:34:56:78:FF` |
| 6 | 6 | 主机源 `02:32:05:25:00:FE` |
| 12 | 2 | EtherType `88B6` |
| 14 | 4 | 大端帧号，从 0 连续 |
| 18 | 1024 | 写入 DDR0 的程序数据 |

总长 1042 Byte，不含 preamble/SFD/FCS。最后程序块由 WebUI 补零到 1024 Byte。

### 6.2 主机到 FPGA 结束/停止确认帧

目的 `02:32:05:25:00:FF`、源 `02:32:05:25:00:FE`、EtherType `88B5`、Payload 46 Byte。

- 结束：`FFFFFFFF` + 32-bit 总帧数 + 38 Byte 0；
- 主机停止确认：`44124445` + 42 Byte 0。

### 6.3 FPGA 系统信息帧

广播目的、源 `02:32:05:25:00:FF`、EtherType `88B5`、Payload 46 Byte：4-Byte code + `03 20` + 40 Byte 0。状态码详见系统总 README。

### 6.4 FPGA Info 数据和完成帧

数据帧 EtherType `88B7`、Payload 1444 Byte、每帧 60 条 24-Byte 记录；完成帧 EtherType `88B8`、Payload 46 Byte。两个 hart 以源 MAC `02:32:05:25:10:00/01` 区分。详细字段见系统总 README。

网卡负责生成 FCS；WebUI 构造的 raw frame 不附加 FCS。Npcap 有时剥离 FCS，解码器同时接受保留 4 Byte FCS 的抓包长度。

## 7. 状态运行过程

板上正常序列：

```text
复位 -> PRECONFIG
11111111
主机发 1×全FF程序帧 + 结束帧
44004444 -> 44114444 -> 22222222
READY 清 DDR0 低4GiB
33333333（帧完成后硬件已处于 PROGRAM_WRITE）
主机发 N 个程序帧 + 结束帧
44004444 -> 44114444 -> 44444444
EXECUTE: 55000000/55010000 -> 550000FF/550100FF
END: 55555555 -> H0数据/H0DN -> H1数据/H1DN -> 77777777
确认物理 MAC 已完成全部帧 -> 全局复位 -> PRECONFIG
```

发生错误时：FPGA 完成当前以太网帧边界后发送一次错误码；WebUI 立即取消发送线程并发 `44124445`；FPGA 收到确认后全局复位。不要在没有停止确认时手工继续注入程序帧。

## 8. 最终实现和时序签核

### 8.1 结果

- WNS `+0.045 ns`，TNS `0`，setup failing endpoints `0`；
- WHS `+0.009 ns`，THS `0`，hold failing endpoints `0`；
- RGMII 外部输入 setup/hold `+0.254/+0.306 ns`；
- pulse-width slack `+0.046 ns`；
- 376352/376352 routable nets fully routed；routing errors `0`；
- 74 组 bus-skew 全部通过，最差 slack `+2.218 ns`；post-route blackbox `0`；
- DRC：0 Error，102 Warning，6 Advisory；Bitgen 总结 0 Error、0 Critical Warning；
- 主路由峰值约 19.3 GB（Vivado 报告值，超过物理内存时依赖分页文件）。

### 8.2 必须特别注意

1. **全局正裕量很小**：+0.045/+0.009 ns 只说明当前 routed DCP 满足当前约束。不能把它当成大裕量设计；任何改动都要重新跑 `report_timing_summary -delay_type min_max`。
2. **不能只看 WNS**：同时看 TNS、WHS/THS、pulse width、unconstrained paths、route status 和 DRC。
3. **RGMII 约束必须晚加载**：`rgmii_phy_timing.xdc` 要覆盖 IP 默认的 RX/TX 外部延迟；若重复约束而不是替换，报告可能看似通过但物理模型错误。
4. **PHY 寄存器与 XDC 必须成对修改**：TX=2 ns、RX=1 ns、FPGA IDELAY=1.1 ns 是一组。单独改任何一项会重新破坏 setup/hold 平衡。
5. **异步时钟组不要掩盖功能 CDC**：core、ctrl、两 MIG、RGMII RX 是独立域；set_clock_groups 只在已有正确 FIFO/同步器时才合理。不要用 broad false path 隐藏普通逻辑。
6. **Gray pointer bus skew**：最终报告的 74 项 bus-skew 约束均有正 slack。新建异步 FIFO或改变层级名时必须确认约束仍匹配；只做 false path 而没有 bus skew 会遗漏多 bit Gray 到达差。
7. **AXI burst**：不得跨 4 KiB；AR/AW 一旦握手，必须能接收整笔返回/发送整笔数据；不能依靠跨域的滞后 free-count 临时判断。
8. **MIG reset/owner**：MIG `ui_resetn` 和 owner mux 切换时必须保证前一 AXI master 完全 idle，否则可能遗留 response 给下一会话。
9. **高内存阶段**：本次最终路由峰值约 19104 MB。机器物理内存约 16920 MB，依赖系统分页文件；过高并发可能直接崩溃。当前稳定策略为 synth 内部最多 4、opt 1、place 2、route 虽设置 2 但 Vivado 路由器内部报告最多 8、bitstream 1；必须保持单 Vivado 任务并优先保证内存。
10. **RXC 时钟根修改不是普通数据网 ECO**：必须从未被试验覆盖的 routed DCP 开始，只解 RXC 网，调用 `update_clock_routing`，再 `route_design -nets`。最终同时检查 setup、hold、route status、bus skew、DRC 和实际 `CLOCK_ROOT/USER_CLOCK_ROOT`。
11. **非法参数不能用“时序已通过”掩盖**：1250 ps IDELAY 的时序数字不是合法实现；任何 `AVAL-174`、`RTSTAT-2`、未路由网或严重 DRC 都必须先归零，不能生成板级交付位流。

### 8.3 当前普通警告的解释

- URAM `REQP-1859` 和 DSP `AVAL-155` 来自 EH2/器件映射建议，未形成严重 DRC；后者是功耗建议。
- MIG calibration/debug 内部存在 no-routable-load 提示，但 route status 证明全部需要路由的网络已完成，相关 violation 为 none。
- 双帧槽综合会报告未使用的 DDR 记录低 64 bit，这是协议有意丢弃的保留区。
- 双帧槽数组的 set/reset 同优先级警告已由定向 RTL 仿真和最终结构审计覆盖；如果后续重写复位编码，必须重新做两槽背压/顺序测试，不能只消除警告文字。

这些普通 warning 不是忽略清单。升级 Vivado 或改 RTL 后必须重新逐类审阅，确认实例和数量没有变化。
