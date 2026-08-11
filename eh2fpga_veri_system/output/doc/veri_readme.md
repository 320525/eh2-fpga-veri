# EH2 FPGA 整机系统前仿验证说明

## 1. 文档目的

本文只说明本工程已经完成的前仿验证工作、验证方法、判定条件、最终结果、验证中发现的问题以及尚未覆盖的内容。系统功能、模块结构、状态机和协议定义的完整说明见同目录的 `README.md`。

截至 2026-08-06，工程已经完成以下四个层级的前仿：

1. 控制器、以太网接收隔离、DDR 主机、日志封帧/WAW 容量的单元级前仿；
2. EH2 双 hart 约 20 万条提交指令的独立长仿真；
3. 使用虚拟机内标准 Spike 生成指令级黄金参考，并与 EH2 前仿结果逐条比较；
4. 从系统顶层 RGMII 输入真实以太网帧，贯穿 MAC、FIFO、程序 DMA、双 DDR、EH2、hash/归约和 RGMII 发送端的整机前仿。

所有最终保留的通过日志和 JSON 报告均为 `PASS`。整机最终结果为：

```text
FULL_SYSTEM_RGMII_PASS frames=18 info=14 log=4 rgmii_cycles=5208 min_ifg=783 rx_overflow=0
FULL_SYSTEM_FRAME_PASS frames=18 info=14 log=4 errors=0
```

这里的“前仿”是 Vivado XSim behavioral simulation，不等同于综合网表时序仿真或上板验证。第 12 节明确列出了替代模型和未覆盖项。

## 2. 验证环境与仿真模型

### 2.1 工具与工程

- Vivado/XSim：Vivado 2023.2；
- FPGA part：`xcvu19p_CIV-fsva3824-1-e`；
- Vivado 工程：`build/vivado/eh2_veri_system.xpr`；
- 工程创建脚本：`scripts/create_project.tcl`；
- 整机前仿脚本：`scripts/run_full_system_sim.tcl`；
- 整机测试平台：`tb/tb_eh2_veri_system_rgmii.sv`。

综合工程保留并使用 `netlist/eh2_veer_wrapper.edf`。为了在前仿中观察双 hart 的提交指令、CSR 写入、停止状态和 hash 输入，behavioral simulation 使用与该配置对应的 EH2 RTL 替代 EDIF；因此本次验证检查了功能行为，没有检查 EDIF 网表延迟。

### 2.2 DDR 前仿替代模型

物理 MIG 和 DDR4 器件模型由以下前仿模型替代：

- `tb/dual_ddr_mig_sim_wrapper.sv`；
- `tb/axi512_memory_model.sv`。

每个 DDR 模型保存 1 MiB 数据，接口仍为系统实际使用的 512-bit AXI UI 侧接口。高地址位在模型中折叠到 1 MiB 窗口内，以便在可接受的前仿时间和内存占用下验证地址、突发、字节选通、响应和总线所有权切换。

硬件参数中的数据 DDR 清零长度仍为 4 GiB，即 `DATA_CLEAR_BYTES = 0x1_0000_0000`；整机前仿实例将其缩短为 `0x0010_0000`，即 1 MiB。前仿检查的是同一个 512-bit 清零主机及同一条 AXI 路径，但没有在仿真中实际循环写满 4 GiB。

### 2.3 PHY 与 MAC 前仿方式

整机前仿使用 TEMAC 的 behavioral model、MAC 接收/发送 FIFO 和实际 RGMII 引脚级数据通路。测试平台生成前导码、SFD、帧数据和 FCS，并通过顶层 `rgmii_rxd/rgmii_rx_ctl/rgmii_rxc` 输入；发送端则从 `rgmii_txd/rgmii_tx_ctl/rgmii_txc` 重新收集帧。

因为测试平台没有串行 MDIO PHY 模型，整机前仿设置 `PHY_INIT_BYPASS=1`。因此前仿验证了 MAC 初始化完成之后的数据通路，没有逐位验证 DP83867 的 MDIO 寄存器写入、自动协商和真实链路建立过程。

## 3. 验证总览

| 层级 | 测试平台/工具 | 主要验证对象 | 最终结果 |
|---|---|---|---|
| 状态控制器单元 | `tb_system_controller.sv` | 六状态正常路径、DDR 所有权、END/ERROR 全局复位请求 | `TB_PASS` |
| RX 隔离单元 | `tb_eth_rx_separation.sv` | 程序帧/系统帧隔离、结束标志、无关帧丢弃 | `TB_PASS rx separation program_words=519 drops=1` |
| DDR 主机单元 | `tb_ddr_masters.sv` | 1024-byte 全 FF 写入、回读比较、AXI 时序 | `TB_PASS DDR fill/check bytes=1024` |
| 日志封帧单元 | `tb_log_frame_packetizer.sv` | 双 hart 封帧、hash 字段、WAW 序号和 483 上限 | `TB_PASS log packetizer ... WAW_limit=483` |
| WAW 早期导出 | `tb_waw_export_early.sv` | direct-commit WAW 事件、hart/package/sequence 及前 132 项完整次序 | `TB_PASS WAW export count=132 hart0=4 hart1=128` |
| EH2 长仿真 | `tb_eh2_stress_200k_csr.sv` | 双 hart、约 20 万条提交、非阻塞结果、四个归约包 | `EH2_STRESS_200K_CSR_PASS` |
| Spike 对照 | Spike + Python | EH2 与 ISS 的 200044 条结构逐条比较 | `PASS`, 200044/200044 exact |
| 整机 RGMII 前仿 | `tb_eh2_veri_system_rgmii.sv` | 顶层收帧烧写、状态机、EH2 执行、日志发送 | `FULL_SYSTEM_RGMII_PASS` |
| TX 帧离线复核 | `verify_full_system_frames.py` | 18 帧格式、状态顺序、hash/WAW 黄金值和零填充 | `FULL_SYSTEM_FRAME_PASS` |

## 4. 单元级前仿

单元测试由 `scripts/run_unit_sims.ps1` 运行，其中 PRECONFIG 的 0 帧和 2 帧非法情况使用独立顶层。ERROR 测试会检查 first-error-wins、错误码、LED0、上位机停止确认和全局复位请求；错误信息帧物理发送完成且收到 `HOST_SEND_STOPPED` 后，监督器复位全系统并回到 PRECONFIG，而不是永久锁死或直接跳到 READY。

### 4.1 六状态控制器与系统信息发送

测试平台：`tb/tb_system_controller.sv`  
通过日志：`xsim_5584.backup.log`

验证的正常状态路径为：

```text
PRECONFIG
  -> READY
  -> PROGRAM_WRITE
  -> EXECUTE
  -> END
  -> GLOBAL_RESET
  -> PRECONFIG
```

具体检查内容：

- PRECONFIG 开始时，程序 DDR 的所有者为程序 DMA，数据 DDR 的所有者为 ATG；
- 两侧 1024-byte 全 FF 写入结束后，指令 DDR 和数据 DDR 的读比较器同时启动；
- 读比较期间两侧 DDR 所有者均切换为 CHECKER；
- 检查通过后进入 READY，数据 DDR 所有者切换为 ZERO；
- 清零和一周期程序会话记账清除结束后进入 PROGRAM_WRITE，程序 DDR 只归程序 DMA；
- 只有程序结束标志、结束帧前一程序帧的 DMA 成功完成和 DMA 空闲三个条件同时成立后才进入 EXECUTE，两侧 DDR 均只归 EH2；
- 两个 hart 执行停止、日志结果发送完毕且 AXI 空闲条件满足后进入 END；
- END 两帧物理发送完成后请求 64-cycle 全局复位并再次进入 PRECONFIG。

最终一次顶层闭环测试逐字节检查了 14 个系统信息帧。每帧长度必须为 60 bytes，不含 RGMII 前导码和 FCS；字段必须为：

- 目的 MAC：`ff:ff:ff:ff:ff:ff`；
- 源 MAC：`02:32:05:25:00:ff`；
- EtherType：`0x88B5`；
- payload[0:3]：32-bit 系统信息码，大端发送；
- payload[4:5]：`03 20`；
- payload[6:45]：40 bytes 全零。

检查到的系统信息码顺序为：

```text
11111111  PREINIT_DONE
44004444  PRECONFIG PROGRAM_WRITE_START
44114444  PRECONFIG RECEIVE_DONE
22222222  SYSTEM_FUNCTION_CHECK_PASS
33333333  READY
44004444  PROGRAM_WRITE_START
44114444  RECEIVE_DONE
44444444  PROGRAM_WRITE_DONE
55000000  HART0_FIRST_COMMIT
55010000  HART1_FIRST_COMMIT
550000FF  HART0_STOPPED
550100FF  HART1_STOPPED
55555555  EH2_EXECUTE_DONE
77777777  END 后最后一帧；其物理发送完成后请求全局复位
```

单元测试为加速仿真将 `PROGRAM_TIMEOUT_CYCLES` 设为 80、执行保护周期设为 4；全局复位监督器的持续周期另做定向检查。该测试没有等待真实 20 秒超时，但对错误停止握手、复位请求、程序序号、DMA 配对和 RX/FCS CDC 使用独立定向平台覆盖。

PROGRAM_WRITE 的配对逻辑使用 3 帧做最小定向反例：结束帧到达时锁存 `target=3`；当成功 DMA 完成数仅为 2 时必须继续停在 PROGRAM_WRITE；完成数变为 3 但 `dma_busy=1` 时仍不能通过；只有 `done_count=target=3` 且 `dma_busy=0` 才允许发送 PROGRAM_WRITE_DONE。这里的 3 只是控制器逻辑的最小反例，整机正式程序使用 782 帧。

PRECONFIG 的“恰好一帧”由三部分验证：

- 正常整机路径发送 1 帧全 FF 程序帧和结束帧，要求 DMA 完成、从 `0x80000000` 回读 1024 bytes 全 FF，并继续进入 READY；
- `tb_preconfig_zero_frame_error` 在 0 帧后发送结束帧，要求进入 ERROR、锁存包数错误并点亮 LED0；
- `tb_preconfig_frame_count_error` 在 2 帧后发送结束帧，要求进入 ERROR、锁存包数错误并点亮 LED0；错误帧完成且收到主机停止确认后按统一策略执行全局复位并回到 PRECONFIG。

最终标志：

```text
TB_PASS controller frames=15
```

### 4.2 程序帧与系统信息帧接收隔离

测试平台：`tb/tb_eth_rx_separation.sv`  
通过日志：`xsim_41172.backup.log`

测试平台依次输入：

1. 一帧合法程序帧，共 1042 bytes/521 个 16-bit word，其中 payload 前两个 word 是 32-bit 帧序号；
2. 一帧合法系统信息结束帧，共 60 bytes；
3. 一帧目的地址和类型均不匹配的 60-byte 无关帧。

检查内容：

- 程序帧只进入程序写入通路，不能进入系统信息 FIFO，也不能产生程序结束脉冲；
- 系统信息帧只进入系统信息 FIFO，不能向程序 DMA 输出任何 word；
- 系统信息帧 payload 前四个字节全为 `FF` 时，只产生一次 `program_end_pulse`；
- 无关帧被丢弃，不能污染程序帧或系统帧路径；
- 接收统计必须为 program=1、info=1、drop=1、end=1；
- `frame_buffer_overflow`、识别帧长度错误、系统信息 FIFO overflow 和 malformed frame 均不得置位。

最终标志：

```text
TB_PASS rx separation program_words=521 drops=1
```

这项测试确认了共用同一个 MAC 时，系统帧不会进入程序 DMA，程序帧也不会进入系统信息 FIFO。

### 4.3 DDR 全 FF 写入与回读比较

测试平台：`tb/tb_ddr_masters.sv`  
通过日志：`xsim_22512.backup.log`

测试内容：

- 从基地址 `0x1000` 写入 1024 bytes 的 `0xFF`；
- 检查填充主机报告的完成字节数必须等于 1024；
- 在写主机和读比较器之间切换 AXI owner；
- 回读同一地址范围并与 512-bit 全 FF 期望值比较；
- `mismatch_count` 必须为 0；
- 检查 AXI 写突发的 `WLAST` 位置和 B/R 响应；
- 写入和读取过程都不得报告 error。

最终标志：

```text
TB_PASS DDR fill/check bytes=1024
```

### 4.4 日志帧封装和 WAW 容量边界

测试平台：`tb/tb_log_frame_packetizer.sv`  
通过日志：`xsim.log`

第一阶段同时向 hart0 和 hart1 提交 package 0 的归约结果，检查必须发送两帧 1038-byte 日志帧。逐字节检查内容包括：

- 目的 MAC 为广播地址；
- 源 MAC 为 `02:12:34:56:78:ff`；
- EtherType 为 `0x88B5`；
- package number、hart ID、指令计数和六个 64-bit 归约字段的位置；
- hart0 帧包含两个 WAW 序号 `0x1122`、`0x3344`，且按大端顺序发送；
- WAW 数据之后的剩余 payload 必须为零；
- 第二帧必须属于 hart1；
- 两帧发送完成后 `all_done` 必须有效；
- 不允许出现 pending result overflow、WAW overflow 或 WAW bank conflict。

日志 payload 固定字段占 58 bytes，1024-byte payload 剩余 966 bytes，可容纳：

```text
966 / 2 = 483 个 16-bit WAW 指令序号
```

第二阶段先复位测试对象，再向同一 package 写入 484 个 WAW 序号：

- 前 483 个必须被正常保存；
- 第 484 个必须置位 hart0 的 WAW overflow；
- 不进行跨帧拆分，符合“超过单帧容量立即进入 ERROR”的设计要求。

日志末尾显示：

```text
TB_PASS log packetizer frames=0 WAW_limit=483
```

其中 `frames=0` 是因为边界测试开始前复位了 DUT 和测试平台计数器；在复位前，测试平台已经显式等待 `frame_count == 2`，并完成了上述两帧的所有断言。因此该数字不表示未发送日志帧。

## 5. 20 万条双 hart EH2 独立长仿真

### 5.1 测试程序

程序源文件：`programs/stress_200k_dualhart_system/stress_200k_dualhart_system.S`

程序特征：

- reset vector 和链接地址为 `0x80000000`；
- 仅 hart0 执行 `csrw 0x7FC, t6`，其中 `t6=2`，用于启动 hart1；
- 两个 hart 分别设置栈和私有数据区域；
- hart0 和 hart1 各包含 100,000 条实际展开的静态指令，不用小循环制造约 20 万条动态提交；
- 指令主体包含整数运算、乘法、load/store，以及显式的 load/div 后同目的寄存器写入 WAW 相关序列；
- 两个 hart 最终分别向结束地址写入停止标志；
- 程序本体 800,640 bytes，补零至 800,768 bytes；
- 拆分成 782 帧，每帧为 14-byte header + 4-byte 大端序连续编号 + 1024-byte 程序数据。

程序镜像清单 `programs/stress_200k_dualhart_system/build/image_manifest.json` 记录：

```text
DDR base       = 0x80000000
program bytes  = 800640
payload bytes  = 800768
frame count    = 782
frame bytes    = 1042
sequence bytes = 4
destination    = 02:12:34:56:78:ff
source         = 02:32:05:25:00:fe
EtherType      = 0x88B6
```

### 5.2 独立 EH2/CRC 测试平台

测试平台：`tb/tb_eh2_stress_200k_csr.sv`  
运行脚本：`scripts/run_stress_csr_sim.ps1`  
主日志：`artifacts/sim/stress_200k_csr_xsim.log`

该测试使用 EH2 RTL、原 `log_eh2_crc_fpga` 工程的 hash/归约 RTL 和统一 AXI BRAM，重点验证处理器提交到 hash 结果之间的链路，不包含整机 MAC、状态机和 MIG wrapper。

测试平台没有强制启动 hart1。hart1 必须由程序中 hart0 对私有 CSR `0x7FC` 的写入启动。

完成条件和断言：

- 两个 hart 都进入停止状态；
- 两个 hart 的 pending nonblock 结果都归零；
- hart0/package0、hart0/package1、hart1/package0、hart1/package1 四个结果全部出现；
- `error_seen` 和 sticky fail 均为 0；
- 必须观察到两个 hart 的真实提交活动；
- 每个 hart 的 commit count 必须等于送入 hash 的 generated count；
- 每个 hart 至少执行 90000 条被记录指令；
- 每个 hart 的 package 0 必须恰好包含 65536 条；
- package 0 与 package 1 的数量之和必须等于该 hart 的 generated count；
- 从 hash 输入端导出的结构条数必须与四个归约包报告的条数完全一致；
- 非阻塞除法/余数的晚返回结果在 pending 清空之前不能结束测试。

最终结果：

```text
EH2_STRESS_200K_CSR_PASS
hart0 = 100023
hart1 = 100021
packages = 65536/34487, 65536/34485
```

两个 hart 合计生成并导出：

```text
100023 + 100021 = 200044 条 hash 输入结构
```

相关产物：

- `artifacts/sim/stress_200k_csr_actual_structs.txt`：EH2 前仿导出的每条 160-bit 结构；
- `artifacts/sim/stress_200k_csr_results.txt`：RTL 输出的四个 package 归约结果；
- `artifacts/sim/stress_200k_csr_div_timing.txt`：非阻塞除法返回时序诊断；
- `artifacts/sim/stress_straight_200k_csr_verified.json`：独立 Python CRC/归约重算报告。

独立 Python 模型用导出的 200044 条结构重新计算 CRC 和归约值，再与 RTL 四个 package 的输出比较。报告结果：

```text
status          = PASS
structure_count = 200044
package_count   = 4
hardware_match  = true（四个 package 全部）
errors          = []
```

## 6. Spike 指令级黄金参考验证

### 6.1 运行方法

按要求，Spike 在用户虚拟机内运行，连接方式为 SSH，不使用虚拟机图形控制界面执行仿真。

硬件 ELF 保留真实指令：

```asm
li   t6, 2
csrw 0x7FC, t6
```

标准 Spike 不实现 EH2 私有 CSR `0x7FC`。为了让标准 Spike 可以运行，构建脚本另外生成 `stress_200k_dualhart_spike.elf`，只在该位置用一条 NOP 替代私有 CSR。Spike 执行结束后，`scripts/restore_spike_hartstart.py` 将这一个 hart0 trace/commit 对恢复为真实指令 `0x7fcf9073`，并恢复其语义效果 `mhartstart=2`。除这一条私有 CSR 的兼容处理外，其余 Spike 轨迹来自标准 Spike 实际执行结果。

Spike 相关产物：

- `artifacts/sim/spike_straight_200k_adjusted.log`；
- `artifacts/sim/spike_straight_200k_structs.txt`；
- `artifacts/sim/spike_straight_200k_golden.json`；
- `artifacts/sim/eh2_spike_straight_200k_compare.json`。

### 6.2 比较粒度

比较不是只比较最终 hash，而是先把 EH2 前仿和 Spike 轨迹都转换为 hash 模块实际接收的指令结构，再逐条比较：

- hart；
- package number；
- package 内 sequence number；
- PC；
- instruction；
- metadata；
- data/result。

逐条比较报告：

```text
status                = PASS
eh2_count             = 200044
spike_count           = 200044
exact_matches         = 200011
accepted_waw_zero     = 33
missing_eh2_count     = 0
missing_spike_count   = 0
mismatches            = []
```

这说明：

- hart0 的 `csrw 0x7FC` 已按真实硬件指令参与 EH2/Spike 对照；
- hart1 的启动点和后续执行序列与黄金参考一致；
- EH2 前仿没有缺失或多生成 hash 输入；
- 33 条结构的 hart/package/sequence、PC、instruction 和 metadata 与 Spike 完全相同，只有 EH2 按设计把被 WAW 取消的晚返回结果清为 0；这些比较例外全部属于 hart1/package0，序号为 `267, 275, ..., 523`，间隔 8，共 33 项。
- `accepted_waw_zero=33` 只统计“EH2 数据为 0 而 Spike 原始结果非 0”的 ISS 对比例外，不等于 RTL 输出的全部 WAW 取消事件。当前完整 WAW 导出为 hart0/package0 4 条、hart1/package0 128 条，总计 132 条。
- 其余 200011 条结构逐位相同，且无缺失、无多余、无其他 mismatch。单帧 483/484 容量边界仍由第 4.4 节的专用单元测试覆盖。

## 7. 四个 package 的黄金归约结果

Spike 黄金文件、EH2 独立长仿真和整机 RGMII 发出的日志帧三者最终一致：

### hart0 / package0

```text
count = 65536
waw   = 4 (sequence 18, 20, 26, 28)
xor0  = d31849f405d7893f
xor1  = f362cffb3bd01126
sum0  = 40883202d86e0925
sum1  = c155b99763889958
sum2  = f97364871915ade9
sum3  = 7ec3152548d669c5
```

### hart0 / package1

```text
count = 34487
xor0  = ca29af3d5afed2de
xor1  = dab2dbaec7cf9013
sum0  = 304dcd82a6df56f4
sum1  = 594544d87138de09
sum2  = c90918dde2a98436
sum3  = 86df023d8dec6168
```

### hart1 / package0

```text
count = 65536
waw   = 128 (完整序号见 webui/golden/stress_200k_system_golden.json)
xor0  = bb84a72d88908184
xor1  = 77ae970cea8f03ee
sum0  = f0ba1c03f647a3d4
sum1  = 07d2e3a5867b2f14
sum2  = fec9fec6bbd4da0b
sum3  = f9fc10899b8299e5
```

### hart1 / package1

```text
count = 34485
xor0  = b2c8ba18b57bb719
xor1  = 1d356092b1daae53
sum0  = 2f710fa64e36788d
sum1  = ee452c2062e1d3ad
sum2  = d772ad1beae8bdf4
sum3  = cfaf9594c587af03
```

## 8. 系统顶层完整 RGMII 前仿

### 8.1 目的

整机前仿不是直接向 DDR 预加载程序。20 万条测试程序从系统顶层以真实 Ethernet/RGMII 接收帧输入，依次经过：

```text
RGMII RX
 -> TEMAC
 -> MAC RX FIFO
 -> 程序帧/系统帧分类
 -> 程序 DataMover/DMA
 -> 指令 DDR（从 0x80000000 写入）
 -> EH2 IFU/LSU
 -> 双 hart 提交
 -> hash/归约
 -> log FIFO/封帧
 -> TEMAC
 -> RGMII TX
```

因此当前 20 万条程序写入确实由顶层 MAC 接收路径完成，没有通过测试平台层次引用直接写 DDR，也没有用 `$readmemh` 把程序预装到指令 DDR。

### 8.2 测试平台时钟

`tb/tb_eh2_veri_system_rgmii.sv` 产生：

- 处理器 core clock：50 MHz；
- 控制器/system clock：100 MHz；
- TEMAC reference clock：约 333.333 MHz；
- RGMII RX clock：125 MHz；
- DDR reference clock：约 76.15 MHz。

控制状态机和系统信息 FIFO 使用工程中定义的 100 MHz 控制时钟域；EH2 和 ATG 使用 50 MHz 处理器时钟域。跨域结果通过工程内 CDC/FIFO 路径进入发送域。整机前仿同时运行这些异步时钟，验证了正常数据流下的跨域握手。

### 8.3 顶层输入帧

测试平台从：

```text
programs/stress_200k_dualhart_system/build/stress_200k_program_frames.mem16
```

读取帧内容，但它只把该文件作为“上位机发送帧”的字节源。测试平台为每帧生成：

- 7-byte Ethernet preamble；
- 1-byte SFD；
- Ethernet header 和 payload；
- 按实际帧内容计算的 FCS；
- RGMII 低/高 nibble 时序；
- 协议允许的最小帧间隔：`RX_CTL` 连续低 24 个 DDR nibble，即 96 ns/12 byte IFG。

程序数据阶段按 1 Gb/s RGMII 的每个上下沿连续发送，不插入软件节流。测试平台测量相邻帧的有效采样中心为 100 ns；扣除两侧半个 nibble 后，线上的空闲低电平恰好为 96 ns。PRECONFIG 程序帧到结束帧、782 帧正式程序以及其结束帧共检查 783 个最小 IFG，并对 MAC RX FIFO overflow、分类器 overflow 和识别长度错误分别做 sticky 断言。

测试平台共从 RGMII RX 输入两类程序帧和两帧结束信息：

1. PRECONFIG 中的 1024-byte 全 FF 程序通路检查帧；
2. PRECONFIG 的系统结束帧；
3. PROGRAM_WRITE 中的 20 万条测试程序帧；
4. PROGRAM_WRITE 的系统结束帧。

### 8.4 PRECONFIG 验证

测试顺序和检查结果：

1. 等待系统通过 MAC 发送 `11111111 PREINIT_DONE`；
2. 从顶层 RGMII 输入编号 0 的一帧 1024-byte 全 FF 程序数据；
3. 帧通过 TEMAC、程序 RX FIFO 和 DataMover，从 AXI 地址 `0x80000000` 开始写入指令 DDR；
4. 数据 DDR 一侧由 ATG 写入 1024-byte 全 FF；
5. 观察首帧写入状态 `44004444`，再从系统信息 MAC 地址输入“前四字节全 FF、总包数为 1”的结束帧，并观察 `44114444`；
6. 指令 DDR 和数据 DDR 同时切换给读比较器；
7. 两侧回读均无 mismatch；
8. 系统发送 `22222222 SYSTEM_FUNCTION_CHECK_PASS`。

日志证据：

```text
SYSTEM_TX code=11111111
PROGRAM_RX_ACCEPT
PROGRAM_STREAM_DONE frames=1
INFO_RX_ACCEPT
PROGRAM_END_MARKER
SYSTEM_TX code=44004444
SYSTEM_TX code=44114444
PROGRAM_DMA_DONE status=80040080
SYSTEM_TX code=22222222
```

完整前仿中未出现 instruction/data check fail。

这里需要区分 AXI 地址和前仿存储数组下标：PRECONFIG 全 FF 帧在总线上的起始地址不是 `0x00000000`，而是按统一程序 DMA 配置从 `0x80000000` 开始；1 MiB 紧凑 DDR 模型折叠高地址位，所以 `0x80000000` 落在模型内部的第 0 行。指令读比较器也从 AXI 地址 `0x80000000` 读取。这与 EH2 reset vector 和正式程序写入地址一致。

### 8.5 READY 验证

PRECONFIG 通过后：

- 状态机进入 READY；
- EH2 保持复位；
- 数据 DDR 清零主机占有 DDR1；
- 前仿清零 1 MiB 建模窗口；
- 清零完成后只发出一个控制时钟的 `program_session_clear`，清除 PRECONFIG 的程序帧序号、包数、DMA done 数和写地址记账；
- MAC、PHY、MIG、EH2、日志系统和系统信息 RX/TX FIFO 不在 READY 被复位；
- 清零及程序记账清除完成后发送 `33333333 READY`；
- 进入 PROGRAM_WRITE。

最终版本取消旧的会话软复位。END 完成后先确认 `55555555/77777777` 已物理发送，再由监督器拉低全系统复位 64 个 `ctrl_clk` 周期并回到 PRECONFIG。顶层长仿真只运行一次完整 20 万条闭环；全局复位持续时间、返回 PRECONFIG 和 ERROR/主机停止握手由定向平台检查，不为观察第二个 READY 再重复整套大程序。

### 8.6 PROGRAM_WRITE 验证

在 PROGRAM_WRITE 中，测试平台从顶层 RGMII 输入完整的双 hart 大程序，共 782 个连续的 1042-byte Ethernet frame：

- destination：`02:12:34:56:78:ff`；
- source：`02:32:05:25:00:fe`；
- EtherType：`0x88B6`；
- 程序本体：800,640 bytes；
- 补零后程序数据总量：800,768 bytes；
- 每帧 payload：4-byte 连续编号 + 1024-byte 程序数据，帧数：782；
- DDR 写入起始地址：`0x80000000`。

测试平台发送完最后一帧程序帧后，立即从 RGMII 输入系统结束帧，中间不等待也不读取 FPGA 内部的 DMA done。状态机先检查 782 个帧序号严格为 `0..781`，再比较结束帧声明总数、连续接收数和成功 DMA 完成数；三者相等且 DMA 当前空闲后才发送：

```text
44444444 PROGRAM_WRITE_DONE
```

最后一帧及结束帧附近的日志为：

```text
PROGRAM_RX_ACCEPT
PROGRAM_STREAM_DONE frames=782
INFO_RX_ACCEPT
PROGRAM_END_MARKER
PROGRAM_DMA_DONE status=8004008d
SYSTEM_TX code=44444444
PROGRAM_DDR_IMAGE_PASS frames=782 bytes=800768 final_addr=800c3800
```

这项完整前仿覆盖“有程序写入并正常结束”的路径；20 秒 program write overtime 路径未在整机长仿真中实际等待和触发。

### 8.7 EXECUTE、双 hart 启动和归约验证

进入 EXECUTE 前，两侧 DDR 总线所有权均切换给 EH2。EH2 初始化完成后释放执行。

测试平台专门监测 hart0 对 CSR `0x7FC` 的提交，要求：

- 提交 hart 必须是 hart0；
- CSR 地址必须为 `0x7FC`；
- 写入数据的 bit1 必须为 1。

最终日志：

```text
HARTSTART_CSR_COMMIT hart=0 lane=0 pc=8000000c data=00000002
```

随后必须观察到 hart1 的第一条真实提交：

```text
HART1_FIRST_COMMIT lane=0 pc=80000000 insn=f1402473
```

hart1 首次提交比 hart0 的 CSR 写提交晚约 520 ns。执行过程中的进度点为：

```text
500000 cycles:
  mhartstart=11
  stopped=00
  commit/generated=48264/48249
```

最终：

- hart0：100023 条；
- hart1：100021 条；
- 两个 hart 均停止；
- pending nonblock 结果排空；
- 生成四个 package；
- 四帧 hash/归约结果与 Spike 黄金值完全一致。

在 EXECUTE 中系统信息 FIFO 不参与 MAC 仲裁，MAC TX 由 log FIFO 使用。四个日志帧发送完成后，状态机还要等待 EH2 IFU/LSU AXI outstanding 事务归零并连续保持 16 个周期，才允许切换到 END。

### 8.8 END、全局复位和返回 PRECONFIG

执行完成后进入 END，依次发送：

```text
55000000 HART0_FIRST_COMMIT
55010000 HART1_FIRST_COMMIT
550000FF HART0_STOPPED
550100FF HART1_STOPPED
55555555 EH2_EXECUTE_DONE
77777777 EXECUTE_END
```

两帧只有在物理 MAC TX 完成计数确认后才允许提出 `global_reset_request`。监督器把全系统 reset 拉低 64 个 `ctrl_clk` 周期，覆盖 MAC、PHY、MIG、FIFO、程序 DMA、控制器、EH2 和日志路径；释放后状态从 PRECONFIG 重新开始，不直接发送第二次 READY。

整机观察到的系统信息帧顺序严格为：

```text
11111111
44004444
44114444
22222222
33333333
44004444
44114444
44444444
55000000
55010000
550000FF
550100FF
55555555
77777777
```

### 8.9 整机测试平台最终断言

整机前仿结束前还检查：

- 不能进入 ERROR，`led0` 不能点亮；
- 两个 DDR AXI memory model 均不能出现 protocol error；
- 14 个系统信息码必须全部出现且状态合法；PRECONFIG 与 PROGRAM_WRITE 各自的 START/RECEIVE_DONE 不能改变 DDR owner 或越过 DMA 配对条件；
- 必须恰好发送 4 帧日志；
- TEMAC 必须产生实际 RGMII TX 活动；
- hart0 必须提交 CSR `0x7FC`；
- hart1 必须至少提交一条指令；
- 测试 watchdog 不能超时。

最终日志：

```text
SYSTEM_TX code=11111111 state=0
SYSTEM_TX code=44004444 state=0
SYSTEM_TX code=44114444 state=0
SYSTEM_TX code=22222222 state=0
SYSTEM_TX code=33333333 state=1
SYSTEM_TX code=44004444 state=2
SYSTEM_TX code=44114444 state=2
SYSTEM_TX code=44444444 state=2
HARTSTART_CSR_COMMIT hart=0 lane=0 pc=8000000c data=00000002
HART1_FIRST_COMMIT lane=0 pc=80000000 insn=f1402473
SYSTEM_TX code=55000000 state=3
SYSTEM_TX code=55010000 state=3
LOG_TX frame=1 package=0 hart=0 count=65536
LOG_TX frame=2 package=0 hart=1 count=65536
LOG_TX frame=3 package=1 hart=0 count=34487
LOG_TX frame=4 package=1 hart=1 count=34485
SYSTEM_TX code=550000ff state=3
SYSTEM_TX code=550100ff state=3
SYSTEM_TX code=55555555 state=4
SYSTEM_TX code=77777777 state=4
FULL_SYSTEM_RGMII_PASS frames=18 info=14 log=4 rgmii_cycles=5208 min_ifg=783 rx_overflow=0
FULL_SYSTEM_FRAME_PASS frames=18 info=14 log=4 errors=0
```

最终离线结果 `artifacts/sim/full_system_frame_verify.json` 记录 `status=PASS`、18 帧总数、14 个系统码和 4 帧日志。DDR 镜像另行确认 782 帧的 800768 byte 补零后数据逐字节一致；模型统计只用于诊断，不代表板上 DDR 物理 burst 数。

最终运行时长：

```text
simulation time = 26.206435 ms
wall elapsed    = 1 h 16 min 36 s
```

`artifacts/sim/full_system_vivado.stderr.log` 长度为 0，最终主日志中没有 `Fatal:` 和 `AXI_PROTOCOL_ERROR`。

## 9. RGMII TX 帧离线复核

整机测试平台把 TEMAC 从 RGMII TX 实际发出的帧重组后写入：

```text
artifacts/sim/full_system_tx_frames.log
```

随后由 `scripts/verify_full_system_frames.py` 进行独立离线复核，结果写入：

```text
artifacts/sim/full_system_frame_verify.json
```

### 9.1 系统信息帧复核

对全部 15 帧检查：

- 60-byte 长度；
- 广播目的 MAC；
- `02:32:05:25:00:ff` 源 MAC；
- EtherType `0x88B5`；
- payload[4:5] 为 `03 20`；
- payload 后 40 bytes 全零；
- 信息码顺序与预期完全一致。
- PRECONFIG/PROGRAM_WRITE 的两组 `44004444/44114444` 均在对应状态出现；四个 hart start/done code 均在 EXECUTE 出现。

### 9.2 日志帧复核

对全部 4 帧检查：

- 1038-byte 长度；
- 广播目的 MAC；
- `02:12:34:56:78:ff` 源 MAC；
- EtherType `0x88B5`；
- package number 和 hart ID；
- 指令 count；
- xor0、xor1、sum0、sum1、sum2、sum3；
- WAW count 不得超过 483；
- WAW 数量和每一个 16-bit sequence 必须与黄金 JSON 完全一致；本轮为 `4/0/128/0`，总计 132 条；
- WAW 序号之后的剩余 payload 必须全零；
- `(hart, package)` 不能重复；
- 四个 `(hart, package)` 必须与 Spike 黄金文件一一对应；
- 每一个 count 和 64-bit 归约字段必须与 Spike 完全相等。

最终报告：

```text
status       = PASS
frame_count  = 19
info frames  = 15
log frames   = 4
errors       = []
```

## 10. 前仿中发现并解决的问题

### 10.1 双 hart 启动错误

初始整机长仿真中：

```text
mhartstart=11
hart0 commit=99963
hart1 commit=0
```

这说明 hart0 已经正确执行 `csrw 0x7FC`，`mhartstart[1]` 也已经置位，但 hart1 仍没有提交指令。因此问题不在测试程序的 CSR 地址、写入值或 DDR 程序内容。

根因是 EH2 wrapper 原来把 `mpc_reset_run_req` 接为全 0，而调试初始化结束后的 `mpc_debug_run_req` 只对 hart0 发出。hart1 在较晚被 `MHARTSTART` 释放时进入了 MPC debug-halt 路径，但系统没有给 hart1 对应的 debug-run 请求，所以 hart1 永久停在调试停止状态。

修正为：

```systemverilog
.mpc_reset_run_req(2'b10)
```

含义是：

- hart0 仍按原流程在复位后保持停止，由 `eh2_hw_init` 通过 debug DMA 完成 DCCM/ICCM 初始化，再由 hart0 的 debug-run 启动；
- hart1 仍由 `MHARTSTART` 门控，不会在上电时提前运行；
- 当 hart0 写 `CSR 0x7FC[1]` 后，hart1 采用 reset-run 路径从 `0x80000000` 启动，不再进入没有 run request 的 debug-halt。

修正后的直接证据：

```text
HARTSTART_CSR_COMMIT ... data=00000002
HART1_FIRST_COMMIT ... pc=80000000
最终 commit=100023/100021
```

EH2/Spike 的 200044 条结构随后全部逐条一致，说明该修正不仅让 hart1“有活动”，而且启动位置、提交顺序和最终归约值都正确。

保留的故障诊断日志：

- `artifacts/sim/full_system_hart1_stall_20260731_0630.log`；
- `artifacts/sim/full_system_hart1_debughalt_20260731.log`。

### 10.2 AXI 512-bit 前仿模型的错误限制

初版 AXI memory model 错误地要求所有 512-bit 接口事务都使用 `AxSIZE=6`，并固定每 beat 地址增加 64 bytes。实际 Xilinx width converter 可能保留未合并窄访问的 `AxSIZE`，再用 `AWADDR[5:0]` 和 `WSTRB` 选择 512-bit 数据线中的有效 byte lane。数据 ATG 的合法 `AWSIZE=2` 因此被旧模型误报为协议错误。

修正后的模型：

- 接受 `AxSIZE <= 6` 的 INCR burst；
- 每 beat 地址按 `1 << AxSIZE` 增加；
- 写入严格按 `WSTRB` 和地址 lane 更新；
- 继续检查不合法 burst、`WLAST` 和响应握手。

修正后重新运行 DDR 单元测试、PRECONFIG 回读检查和整机长仿真，均通过，最终没有 `AXI_PROTOCOL_ERROR`。

### 10.3 仿真脚本重复运行

原整机脚本同时设置非零 XSim runtime 并显式执行 `run all`。当第一次运行出现 `$fatal` 时，脚本可能继续第二次运行，造成日志中失败和后续输出混杂。

修正为：

```tcl
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
run all
```

即只执行一次明确的 `run all`，最终日志中的 PASS 或 FAIL 具有唯一含义。

### 10.4 EH2 AXI 排空保护

状态机不能只看到两个 hart 的软件停止标志就立即切走 DDR owner，因为 IFU/LSU 可能仍有已经接受、尚未收到 B 或 RLAST 的 AXI 事务。

工程增加 EH2 侧已接受读写事务的 outstanding 计数，并将 END 进入条件设为：

```text
stopped == 2'b11
&& log_all_done
&& eh2_axi_idle 连续保持 16 个控制时钟周期
```

整机前仿已经覆盖执行结束、总线排空、进入 END、两帧物理发送完成和提出全局复位请求；定向复位平台覆盖 64-cycle reset 与返回 PRECONFIG。最终两个 DDR 模型都没有 owner 切换引起的协议错误。

### 10.5 连续程序帧下的 MAC RX FIFO overflow

早期整机长仿真在 PROGRAM_WRITE 连续发送程序帧时，大约在第 13 帧附近触发了 MAC RX FIFO overflow。这不是单纯的 FIFO 读时钟不够：

- MAC FIFO 写侧为 8 bit @ 125 MHz，峰值 125 MB/s；
- 原 `mac_fifo_dma_proj` 读侧为 16 bit @ 125 MHz，峰值 250 MB/s，且头部判断与 payload 转发只走一遍；
- 集成系统读侧为 16 bit @ 100 MHz，峰值 200 MB/s，仍高于写侧 125 MB/s。

根因是旧版 `eth_rx_frame_classifier` 对整帧执行“先采集、后重放”。按当前 1042-byte 程序帧计算，共 521 个 16-bit word：

```text
采集时间 = 521 / 100 MHz = 5.21 µs
重放时间 = 521 / 100 MHz = 5.21 µs
总服务时间                 = 10.42 µs/帧
```

重放期间 `mac_rx_ready=0`，MAC RX FIFO 不被读取。而千兆以太网在加上前导码、FCS 和最小 IFG 后，该帧的线速时间约为 8.53 µs。因此旧分类器有效服务能力只有约 100 MB/s，低于连续帧约 122 MB/s 的到达速率，4 KiB MAC RX FIFO 会逐帧累积并最终溢出。

修正后的分类器只缓存目的 MAC 所需的前 3 个 16-bit word，判定后对后续 word 单遍流式转发；程序帧进入 DMA，系统帧去掉 Ethernet header 后进入专用信息 FIFO，其他帧直接排空。修正后：

- RX 隔离单元测试通过；
- 整机前仿连续接收 782 个程序帧；
- 782 帧全部观察到 `PROGRAM_STREAM_DONE` 和成功 `PROGRAM_DMA_DONE`；
- 未再出现 RX FIFO overflow。

### 10.6 旧版第二次 READY 判定及全局复位版替代

第一次最终整机运行已经走到 `END -> READY`，四个归约帧也全部与 Spike 一致，但测试平台在看到 READY 状态后只再等待 2000 个 100 MHz 周期，即 20 µs，就结束仿真。第二轮 READY 要再次清零 1 MiB 数据 DDR，实际需要约 62.78 µs；因此当时只捕获到 6 个系统信息帧，离线校验脚本正确报告缺少最后的 `33333333`。

这是旧版测试平台判定过早，不是 DUT 的 READY 控制错误。旧版曾把结束条件修正为：

```text
ready_frame_count == 2
&& tx_info_frame_count == 15
```

测试平台必须从实际 MAC TX 捕获第二个 `33333333`，不再仅根据状态寄存器判定。最终重跑中：

```text
STATE_TRANSITION 4 -> 1 time=26162515000
SYSTEM_TX code=33333333 state=1
STATE_TRANSITION 1 -> 2 time=26225315000
FULL_SYSTEM_RGMII_PASS frames=19 info=15 log=4
```

该 19 帧结果是取消软复位之前的历史回归证据。当前最终设计在 END 后改为全局复位并返回 PRECONFIG，因此最新一次顶层 20 万条仿真以 18 帧（14 系统+4日志）结束，再由定向平台检查全局复位；旧版第二个 READY 不再是最终协议的一部分。

### 10.7 RX FIFO overflow 错误事件的跨时钟域定向验证

MAC RX FIFO 的 overflow 原始事件产生于 `rgmii_rxc` 对应的 MAC 接收时钟域，错误控制器工作于 100 MHz 控制时钟域。为避免约 8 ns 的短脉冲被控制域漏采、直接跨域导致亚稳态或持续电平被重复计数，接口采用“源域上升沿转 toggle、三级 `ASYNC_REG` 同步、目的域异或还原单周期脉冲”的事件跨域结构。第一次 overflow 即为致命错误，因此系统不要求在少于三个控制时钟周期的间隔内累计多个 overflow 事件。

定向前仿 `tb/tb_rx_fifo_overflow_cdc.sv` 覆盖了：

- 无 overflow 时不得产生错误事件；
- 源域仅保持一个 8 ns 周期的 overflow 脉冲必须被目的域准确接收一次；
- 源端 overflow 持续为高时仍只能产生一次目的域事件；
- 首错误码锁存为 `32'h6666_0073`；
- 系统控制器进入 `ERROR` 状态并点亮 `led0`。

定向仿真结束标志为：

```text
RX_FIFO_OVERFLOW_CDC_PASS pulses=1 code=66660073 state=5 led0=1
```

按验证范围约定，此项修改仅重跑针对性的 CDC 前仿，没有再次运行完整 20 万条整机长仿真。

### 10.8 WAW direct-commit 事件漏导出

早期日志只把 `rv_nb_waw_valid` 两路 pending-nonblocking victim 写入 WAW 序号存储，`rv_commit_waw_victim[1:0]` 已参与 hash 结构的 victim 清零，却没有进入 WAW sideband。因此归约值可以正确，而日志帧中的 WAW list 仍不完整；旧的 33 条 ISS 清零容差被误当成全部 WAW 数量。

修正后 `instr_crc_hash_dual` 统一输出四槽：槽 0/1 是两路直接 commit victim，槽 2/3 是两路 pending-nonblocking victim。`waw_event_cdc` 为四槽分别使用 `33 bit × 16` 异步 FIFO，从 50 MHz 送往 100 MHz；`waw_sequence_store` 使用同拍前缀计数把同 hart/package 的多事件写入连续地址。四路的作用是保住同拍并发事件，不会改变每 hart/package 483 条的帧容量。

验证分三层：

- `tb_waw_export_early.sv` 在程序开头的 WAW 压力段逐事件检查，得到 `count=132, hart0=4, hart1=128`；
- `tb_log_frame_packetizer.sv` 继续检查同拍多事件写入、逐项读出、483 条可发送和第 484 条触发 overflow；
- 整机 782 帧长仿真从实际 RGMII TX 重组四个日志帧，离线工具把 WAW count 和全部 sequence 与黄金 JSON 逐项比较，结果为 `4/0/128/0`，无遗漏、重复或乱序。

### 10.9 PRECONFIG 状态码扩展引起的 DDR owner 提前切换

PRECONFIG 增加 `PROGRAM_WRITE_START` 和 `RECEIVE_DONE` 后，内部 phase 使用了 6、7、8、9 等新编号。旧 owner 组合逻辑用 `phase < 3` 判断“程序/ATG 写入窗口”，因此 phase 从 2 跳到 6 只是为了发送状态码，却被错误解释为写入阶段已结束，DDR0 被过早交给 checker、DDR1 也可能过早离开 ATG。这会使一帧 DMA 尚未完成时失去总线控制权。

修正后 owner 不再依赖 phase 数值的大小关系：PRECONFIG 只有 3/4/5 三个明确的回读/报告 phase 交给 checker，其余 phase 均保持 DDR0=PROGRAM、DDR1=ATG。测试平台增加断言：在结束帧总数、连续接收帧数、DMA done 数和 idle 尚未同时成立前，`instr_check_start` 不得拉高；最终确认 START/RECEIVE 状态帧本身只报告进度，不改变程序写入语义。

### 10.10 RGMII 全速激励的 DDR nibble 相位

全速压力激励最初在不同 task 调用之间偶尔多等待一个同极性边沿，导致下一帧低/高 nibble 与 TEMAC behavioral model 的采样相位错半周期。症状是原始 RX byte 数接近 0、bad frame 增长，看起来像 DUT 在全速下丢帧，实际是测试平台没有持续保持 DDR 相位。

修正后的发送 task 固定在外部下降沿驱动低 nibble、上升沿驱动高 nibble，并记录相邻帧第一个有效采样中心。每次连续 burst 都断言中心间隔为 100 ns：扣除两侧半个 nibble 后，RX_CTL 低电平正好是 IEEE 802.3 最小 96 ns IFG。最终 782 帧以协议允许的最小 IFG 连续输入，`min_ifg=783` 个相邻帧间隔检查全部通过，MAC RX FIFO、分类器和识别长度 overflow 均为 0。

### 10.11 程序序号立即拒绝与会话重装

`tb/tb_program_rx_dma_sequence.sv` 直接驱动正式 `program_rx_dma_ctrl`，验证帧 payload 的前 32 bit 只作为大端序编号，不送入 1024-byte DataMover 数据区。编号不等于当前 `expected_sequence` 时，控制器在该帧内立即锁存 `sequence_error`、拒绝 DMA command/data，不等结束帧的总数比较；`session_clear` 后编号、计数和 DDR 首地址都重新装载。结束标志为：

```text
TB_PASS program sequence immediate-reject/reload cmd=1 payload=512
```

这里的 `payload=512` 表示一个合法帧送给 16-bit DataMover 流的 512 个 word，即恰好 1024 byte，不包含 4-byte 编号。

### 10.12 MAC FCS 统计、CDC 与 ERROR/主机停止握手

TEMAC 会在用户 RX 数据口之前丢弃坏 FCS 帧；若只检查分类器计数，坏帧会表现为“包编号缺失、超时或没有响应”，无法区分物理采样问题。`mac_rx_statistics_cdc` 在 RX 统计域检测 FCS 统计 bit2 的新增事件，源端累计计数并用请求/确认方式跨到 100 MHz 控制域。定向测试 `tb/tb_mac_rx_statistics_cdc.sv` 注入两个事件，要求脉冲和累计数都恰好为 2：

```text
TB_PASS MAC RX FCS event/count CDC pulses=2 count=2
```

`tb/tb_error_global_reset_flow.sv` 进一步验证：程序序号错误和 FCS 错误均立即锁存 first error、进入 ERROR、只发送一次对应错误码；在没有主机停止确认时不得请求复位；主机回送 `0x44124445` 且错误帧物理发送完成后才产生全局复位请求。结束标志为：

```text
TB_PASS immediate sequence/FCS error and global reset handshake
```

这保证 FPGA 不会在 PC 仍以线速发送旧会话程序帧时自行复位并把尾帧接到下一会话。WebUI 对应逻辑在收到任意 error code 时立即停止发送循环、发送一次 `HOST_SEND_STOPPED`，并把时间戳和错误码保存到日志。

### 10.13 确定性 PHY RX 启动放行的验证边界

硬件默认路径依次要求：DP83867 延时寄存器写入并回读正确、自动协商完成、链路连续稳定 100 ms、1 ms IDELAY guard、`rgmii_rxc` 域连续 4096 个边沿，然后才释放 RX client FIFO。RTL/参数、寄存器值和 XDC 的 `RX≈1.25 ns + FPGA IODELAY=1100 ps` 已在综合前做一致性审查；最新实现进一步对外部 RGMII 输入路径完成静态时序签核。由于 behavioral 顶层没有串行 MDIO PHY 和模拟数据眼模型，20 万条前仿旁路了真实 PHY 管理过程，只验证放行后的完整 RGMII/MAC/FIFO/分类/DMA路径。PHY 延时、温压和板间偏差仍必须用新 bitstream 上板压力回归确认。

## 11. 验证产物索引

### 单元测试

- `tb/tb_system_controller.sv`
- `tb/tb_eth_rx_separation.sv`
- `tb/tb_ddr_masters.sv`
- `tb/tb_log_frame_packetizer.sv`
- `tb/tb_rx_fifo_overflow_cdc.sv`
- `tb/tb_mac_rx_statistics_cdc.sv`
- `tb/tb_program_rx_dma_sequence.sv`
- `tb/tb_error_global_reset_flow.sv`
- `tb/tb_waw_export_early.sv`
- `scripts/run_waw_export_early_sim.ps1`
- `scripts/run_unit_sims.ps1`
- `xsim_5584.backup.log`
- `xsim_41172.backup.log`
- `xsim_22512.backup.log`
- `xsim.log`
- `artifacts/sim/waw_export_early_xsim.log`

### EH2 长仿真和 Spike

- `tb/tb_eh2_stress_200k_csr.sv`
- `scripts/run_stress_csr_sim.ps1`
- `scripts/build_stress_program.ps1`
- `scripts/restore_spike_hartstart.py`
- `artifacts/sim/stress_200k_csr_xsim.log`
- `artifacts/sim/stress_200k_csr_actual_structs.txt`
- `artifacts/sim/stress_200k_csr_results.txt`
- `artifacts/sim/stress_200k_csr_verified.json`
- `artifacts/sim/spike_straight_200k_raw.log`
- `artifacts/sim/spike_straight_200k_adjusted.log`
- `artifacts/sim/spike_straight_200k_structs.txt`
- `artifacts/sim/spike_straight_200k_golden.json`
- `artifacts/sim/eh2_spike_straight_200k_compare.json`

### 整机前仿

- `tb/tb_eh2_veri_system_rgmii.sv`
- `tb/dual_ddr_mig_sim_wrapper.sv`
- `tb/axi512_memory_model.sv`
- `scripts/run_full_system_sim.tcl`
- `scripts/verify_full_system_frames.py`
- `artifacts/sim/full_system_vivado.log`
- `artifacts/sim/full_system_vivado.stderr.log`
- `artifacts/sim/full_system_tx_frames.log`
- `artifacts/sim/full_system_frame_verify.json`

## 12. 已验证边界和未覆盖项

为避免把 behavioral simulation 的结果扩大解释，以下内容没有在本次前仿中完成：

1. 没有进行 EDIF 网表时序仿真；EH2 前仿使用对应配置的 RTL；
2. 没有使用真实 DDR4 器件时序模型，MIG 校准和物理 DDR 信号由紧凑 AXI UI 模型替代；
3. 没有在前仿中实际清零 4 GiB，只清零 1 MiB 建模窗口；
4. 没有 MDIO PHY 串行模型，因此未验证 DP83867 寄存器写入波形、自动协商和真实网线链路；
5. 没有验证操作系统/网卡驱动对自定义 EtherType 的实际抓包行为；
6. 整机已覆盖 800,640-byte 大程序拆分为 782 个连续程序帧的正常写入，并验证严格连续编号和结束帧总包数；定向测试覆盖了序号/总包数错误，但协议不提供 ACK 或重传；
7. 20 万条程序实际导出 132 个 WAW 取消事件，整机逐项验证 `4/0/128/0`；483/484 容量边界另由专用单元测试覆盖；
8. 20 秒 program write overtime 未在整机仿真中实际等待触发；
9. 错误监测平台在整机正常路径中验证了“不得误报”，并对 RX MAC FIFO overflow、MAC FCS 统计 CDC、程序序号立即拒绝、ERROR/LED、主机停止确认和全局复位握手做了定向故障注入；其余错误源尚未逐项注入；
10. 本工程已另外完成综合、实现、静态时序、bus-skew、DRC 和 bitstream 生成；这些属于板级实现签核而不是 behavioral 前仿，结果见 `system_board_readme.md`。本次仍未对新整机 bitstream 做板上回归。

因此当前可以确认的是：在 behavioral simulation 覆盖范围内，从顶层 RGMII 以最小 IFG 连续接收 782 个程序帧、DMA 写入 `0x80000000`、六状态正常转移、双 hart 启动与执行、200044 条结构级 ISS 对照、132 条 WAW 导出、四个归约包、END 的两帧物理发送、全局复位请求以及最终 RGMII 发送帧全部一致；程序序号/FCS错误和主机停止握手由定向平台通过。物理 PHY、物理 DDR 和新整机的板上行为仍需上板确认。

## 13. 复现命令

在工程根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_unit_sims.ps1
powershell -ExecutionPolicy Bypass -File scripts\build_stress_program.ps1
powershell -ExecutionPolicy Bypass -File scripts\run_stress_csr_sim.ps1
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source scripts\run_full_system_sim.tcl
python scripts\verify_full_system_frames.py `
  artifacts\sim\full_system_tx_frames.log `
  artifacts\sim\spike_straight_200k_golden.json `
  --json artifacts\sim\full_system_frame_verify.json
```

Spike 黄金参考需要先通过 `scripts/ssh_vm_command.py` 使用 SSH 在虚拟机中运行 Spike，再执行 hart-start 轨迹恢复、结构导出和 EH2/Spike 比较步骤。连接信息和密码不写入本文档，也不应提交到工程源码中。
