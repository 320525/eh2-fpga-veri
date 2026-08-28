# EH2LOGCOMP 最终两轮验证、实现与比特流交付说明

## 1. 最终结论

此前按用户要求执行了 **2 轮**完整自动化前仿，不执行十轮。两轮均从顶层 RGMII/MAC RX 注入程序帧，经过正式程序 DMA 写入 DDR0，启动双 hart EH2 执行，将每条指令的 Info Struct 写入 DDR1，再经 DDR1 读 DMA、双整帧缓冲和 RGMII/MAC TX 回传；最后使用实际 WebUI 解码器检查帧、记录和两个 hart 的完成信息。两轮结果均为 PASS。之后针对 MIG ECC 尾帧问题修改了读/写 DMA，并按用户要求只再执行一次最终 10k 双 hart 顶层 RGMII 闭环；该次同样 PASS，且生产格式 `fpga_info.txt` 可由 WebUI 比较器完整重构。

完成前仿后，工程又完成了全量综合、opt、place、route、精确时序分析、DRC 和比特流生成。最终实现没有未解析 blackbox、没有未布通网络、没有 setup/hold 违例，也没有 DRC Error 或 Critical Warning。

本轮没有进行实体开发板烧写测试；结论覆盖 RTL 前仿、WebUI 软件测试、综合、实现、时序签核和 bitstream 生成。

## 2. 最终交付文件

| 文件 | 大小 | SHA-256 | 用途 |
| --- | ---: | --- | --- |
| `output/board/eh2logcomp_2slot.bit` | 199112137 Byte | `EF901C78E23654CBC8741E3DDA76C6D967BC92631A15A882FCA45CF745A150BB` | 当前可烧写的未压缩位流 |
| `output/board/eh2logcomp_2slot_routed.dcp` | 201083512 Byte | `A17FA0DA86643C92840675E234045E0F15D2B7179BEA1E009F9AD15B77D0621E` | 与当前位流对应的 routed checkpoint |
| `output/board/implementation_20260825_164411_214114.log` | 211514 Byte | `754F33CAF21F69F51ED4BA2781118012B9C960250F6944AFDA95CB4662F39A96` | 本轮完整实现和 bitgen 日志 |
| `output/verification/automation_10x10k/campaign_20260825_005851/campaign_summary.json` | — | `79C3C13073E3FD1241C0FA17358CD6530C65846F1D4AFBE845452D93B5FF4E08` | 最终两轮自动化证据 |
| `output/verification/current_fix_full_top/fpga_info.txt` | 4905101 Byte | `EBBDC30578E763D448EE74D1E3A54998AB3EE375AC248501149D9CC64DD28EE7` | ECC 尾帧修复后的唯一一次最终顶层输出 |

`output/board/SHA256SUMS.txt` 保存板级产物的哈希。历史文件 `eh2logcomp_2slot_postroute_timing_fixed.dcp` 不对应当前位流，不能作为本次签核或重新出 bitstream 的起点。

## 3. 系统结构和 DDR 分工

系统包括双 hart VeeR EH2、两套 DDR4 MIG、单个全双工 TEMAC/RGMII、程序接收 DMA、逐指令 Info Struct 采集/存储/回传、六状态控制器、错误监测和 Windows WebUI。

```text
主机程序帧
  -> RGMII RX -> TEMAC RX -> 目的 MAC/EtherType 分类
  -> 帧号连续性检查 -> 1024-Byte S2MM DMA
  -> DDR0，从 0x80000000 连续写入

EH2 IFU + LSU
  -> AXI 时钟/位宽转换 -> 仲裁 -> DDR0

EH2 双 hart 提交、direct WAW、nonblock load/divide 返回
  -> 每 hart 独立 Info 捕获 bank
  -> 每 hart 独立 4-write/2-record-read 异步 FIFO
  -> 弹性寄存器 -> DDR1 写 DMA
  -> hart1：DDR1 低 4 GiB；hart0：DDR1 高 4 GiB

END 回传
  -> DDR1 只读取 ceil(valid_records/2) 个真实 512-bit beat
  -> DMA 本地补零到构帧侧固定 30 beat
  -> 两个完整 1458-Byte 帧槽
  -> TEMAC TX -> RGMII TX -> 主机
```

DDR0 同时保存指令和 EH2 数据。程序从 `0x80000000` 执行；自动化程序的随机 LSU 地址总包络限定为 `0xA0000000–0xFFFFFFFF`，避免覆盖代码区。DDR1 只保存 Info 记录。

DDR0/DDR1 的控制权按状态唯一分配，切换前等待前一主设备 idle；不会让检查器、清零器、程序 DMA 和 EH2 同时驱动同一套 MIG AXI 接口。

## 4. Info Struct 与 WAW

每个 hart 独立维护 32-bit `sequence_id`，均从 0 递增，不存在 package 概念。逻辑 Info Struct 为 192 bit/24 Byte：

| 字节 | 字段 | 说明 |
| ---: | --- | --- |
| 0–3 | `sequence_id` | 当前 hart 的指令序号 |
| 4–7 | `pc` | 指令 PC |
| 8–11 | `instruction` | 32-bit 指令 |
| 12–15 | `metadata` | WAW 类型、hart、特权级、事件类型、寄存器号 |
| 16–19 | `data` | 架构写回数据；被 WAW 取消时为 0 |
| 20–23 | `waw_cancel_number` | 取消本条写回的较新指令 sequence；无取消为 0 |

`metadata[31:30]` 是 `waw_cancel_kind`：0 无取消，1 同周期直接 WAW，2 nonblock load 被取消，3 nonblock divide 被取消。其余定义为 `[29:17]=0`、`[16]=hart`、`[15:14]=privilege`、`[13:12]=event type`、`[11:0]=寄存器号`。

DDR1 中每条记录为 256 bit/32 Byte：高 192 bit 是 Info Struct，低 64 bit 为 0。一个 512-bit MIG beat 正好携带两条记录。每 hart 的 FIFO 深度为 1024 条，可在一个 50 MHz 周期同时接收最多四条结构；DDR1 266.525 MHz 侧每拍弹出一条或两条。

同周期 direct WAW 将较老 victim 的 kind 标为 1、数据清零，并把同 hart 较新写者的 sequence 写入 `waw_cancel_number`。nonblock load/divide 按 hart 和目标寄存器保存待回填结构；若返回前被更新指令覆盖，则写 kind 2/3 和造成取消的同 hart sequence。两个 hart 的 sequence、待回填槽和配对逻辑物理分离，避免旧设计中 hart1 序号污染 hart0 的问题。

当前 `eh2logcomp` 不再计算或发送旧系统的 CRC64/hash 归约结果；这里保存的是原归约前的逐指令信息。以太网链路仍由 MAC 生成/检查标准 Ethernet FCS。

## 5. 以太网帧协议

### 5.1 程序帧：主机到 FPGA

- 目的 MAC：`02:12:34:56:78:FF`
- 源 MAC：`02:32:05:25:00:FE`
- EtherType：`0x88B6`
- Payload：4-Byte 大端帧号 + 1024 Byte 程序数据，共 1028 Byte
- 帧号从 0 严格连续；只有后 1024 Byte 写入 DDR0
- 写地址：`0x80000000 + frame_number × 1024`

每帧建立固定 BTT=1024 的 DataMover S2MM 命令。仅当返回状态同时满足 EOP、实际 1024 Byte、OKAY、无错误且 tag 正确时，DMA 完成计数才加一。

### 5.2 程序结束帧和停止确认帧

系统帧使用目的 MAC `02:32:05:25:00:FF`、源 MAC `02:32:05:25:00:FE`、EtherType `0x88B5`、Payload 46 Byte。

- 结束帧：`FFFFFFFF + 32-bit 总程序帧数 + 38 Byte 0`
- 错误停止确认：`44124445 + 42 Byte 0`

主机可在最后一个程序帧提交给网卡后立即发送结束帧，不必等待 DMA。FPGA 只有在“连续接收帧数 = 结束帧声明数 = 成功 DMA 数”且 DMA idle 时才认为烧写完成。序号不连续、长度错误、FCS 错误等在接收期间立即发一次错误码，不等待结束帧。

### 5.3 FPGA 系统信息帧

- 目的 MAC：广播
- 源 MAC：`02:32:05:25:00:FF`
- EtherType：`0x88B5`
- Payload：4-Byte code + `03 20` + 40 Byte 0，共 46 Byte

### 5.4 FPGA Info 数据帧

- 目的 MAC：广播
- hart0 源 MAC：`02:32:05:25:10:00`
- hart1 源 MAC：`02:32:05:25:10:01`
- EtherType：`0x88B7`
- Payload：4-Byte 大端帧号 + 60 条 24-Byte Info Struct = 1444 Byte
- 不含 FCS 的帧长：1458 Byte，不需要 jumbo frame

帧构造器为一帧固定接收 `30 × 512 bit = 1920 Byte`，即 60 条 32-Byte DDR 记录槽；DDR1 读 DMA 只真实读取 `ceil(valid_records/2)` 个有效行。若有效读取地址到达 AXI 4 KiB 边界，AR 被拆为多笔，但记录索引和以太网顺序仍连续；有效行读完后由 DMA 本地补零到 30 beat，不访问未写 ECC 行。每个 256-bit 有效 DDR 记录仅发送高 192 bit，低 64-bit 保留区丢弃。最后一帧不足 60 条时，仅在 payload 尾部补 0。

两个 TX 帧槽都保存完整 1458 Byte。DDR1 UI 域先占用空槽并置 dirty，30 beat 全部返回后原子 publish；125 MHz TX 域只读取已 publish 的槽。MAC 背压期间字节索引和 `tlast` 保持，整帧最后一个字节握手后才 release。一个槽发送时另一个槽可以构造下一帧，因此正常情况下 DDR DMA 与 MAC 发送并行，不降低连续帧发送能力；两个槽都被占用时对 DMA施加帧粒度背压，不会接收不可撤销、却无处保存的 AXI 返回数据。

### 5.5 每 hart 完成帧

- EtherType：`0x88B8`；Payload 46 Byte；源 MAC 仍按 hart 区分
- Payload 开头为 ASCII `H0DN` 或 `H1DN`
- 后续包含 hart id、协议版本、记录字节数 24、有效记录总数、数据帧总数和最后 sequence
- 固定发送顺序：hart0 数据 → H0DN → hart1 数据 → H1DN

## 6. 六状态和信息码

### 6.1 状态流程

1. **PRECONFIG**：EH2 保持复位；等待 MAC 配置、PHY 初始化/链路/RX 确定性放行、两套 MIG 校准完成，发送 `11111111`。主机发送一帧 sequence 0、1024 Byte 全 FF 程序帧和声明总数 1 的结束帧；系统发 `44004444`、`44114444`，按正式烧写逻辑完成 DMA 配对，从 DDR0 `0x80000000` 回读 1024 Byte。DDR1 同时由 ATG 写读检查。通过后发 `22222222`。
2. **READY**：EH2 保持复位，使用 DDR0 512-bit UI 清零低 4 GiB。全部结束后清程序会话，发送 `33333333`；该帧物理发送完成时系统已进入 PROGRAM_WRITE。
3. **PROGRAM_WRITE**：第一笔程序 AXI 写发生时发 `44004444` 并启动 20 s watchdog；收到结束帧发 `44114444`；计数、连续性、DMA 状态和 idle 全部通过后发 `44444444` 并进入 EXECUTE。
4. **EXECUTE**：DDR0 所有权完全交给 EH2，DDR1 交给 Info 写 DMA；16 个控制时钟 guard 后释放 EH2，启动双 hart。实际首条提交分别发 `55000000/55010000`，实际停止分别发 `550000FF/550100FF`。两个 hart 停止、Info FIFO/DMA 排空且 IFU/LSU AXI 连续 idle 16 个控制周期后进入 END。
5. **END**：先发 `55555555`，再发送 hart0/H0DN、hart1/H1DN，最后发 `77777777`。所有帧都在物理 MAC 完成计数中出现后，请求 64 个 100 MHz 控制周期的全局复位，重新进入 PRECONFIG。
6. **ERROR**：锁存第一次错误、停止 EH2 和普通日志发送、点亮 LED0，向主机发送一次错误码。WebUI 立即停止程序发送并回发 `44124445`；FPGA 收到确认后执行同样的全局复位，再从 PRECONFIG 开始。错误不再永久停死在 ERROR。

### 6.2 正常信息码

| code | 含义 |
| --- | --- |
| `11111111` | PREINIT_DONE |
| `22222222` | PRECONFIG 指令/数据 DDR 检查通过 |
| `22220011` / `22220022` | 数据 DDR / 指令 DDR 检查失败 |
| `33333333` | READY 完成，程序烧写窗口已开启 |
| `44004444` | PROGRAM_WRITE_START |
| `44114444` | 已收到结束帧 |
| `44444444` | 包数、连续性和 DMA 全部核对通过 |
| `55000000` / `55010000` | hart0 / hart1 实际开始提交 |
| `550000FF` / `550100FF` | hart0 / hart1 实际执行结束 |
| `55555555` | EH2 双 hart 执行完成，开始日志回传 |
| `77777777` | END 完成 |

### 6.3 主要错误码

| code | 含义 |
| --- | --- |
| `44440011` | 程序烧写超过 20 s |
| `44440022/33/44` | 程序写、程序 FIFO、程序 DMA 错误 |
| `44440055` | 程序帧号不连续 |
| `44440066` | 结束帧总数与接收/DMA 数不一致 |
| `66660011/12` | hart0/hart1 nonblock buffer overflow |
| `66660033/44` | TX MAC FIFO/stream 错误 |
| `66660071/72` | 系统 RX/TX 信息 FIFO overflow |
| `66660073/74/75` | RX frame buffer、帧长、MAC RX FCS 错误 |
| `66660081/82/83` | MAC 配置、PHY 初始化、PHY link 错误 |
| `66660091/92` | DDR0/DDR1 MIG 错误 |
| `666600A1/A2` | DDR 清零/检查错误 |
| `666600B1/B2/B3` | EH2 初始化、IFU AXI、LSU AXI 错误 |
| `666600C1/C2` | hart0/hart1 Info FIFO overflow |
| `666600C3` | Info DDR 写 DMA 错误 |
| `666600C4` | Info 回传总错误 |
| `666600C5/C6` | hart0/hart1 WAW 配对错误 |
| `666600C7/C8/C9` | DDR 读协议、帧构造协议、双槽释放协议错误 |
| `666600F1` | 非法状态 |

`66660021/22`、`66660051/52`、`66660061/62` 是兼容旧系统保留的命名/编码；当前数据产品是逐指令 Info Struct，不是 CRC/hash 包。

## 7. 时钟、复位与 CDC

| 时钟 | 频率 | 主要用途 |
| --- | ---: | --- |
| `core_clk` | 50 MHz | EH2、双 hart Info 捕获、Info FIFO 写侧 |
| `ctrl_clk` | 100 MHz | 六状态、错误、MAC/PHY 管理、程序解析/DMA 控制、系统信息 |
| `clk125` | 125 MHz | 由 50 MHz MMCM 产生，TEMAC TX/RGMII TX、TX client FIFO 和双帧槽读侧 |
| `rgmii_rxc` | 125 MHz | 外部 PHY 恢复的 RX 时钟，RGMII RX/MAC 接收域 |
| `refclk` | 333.333 MHz | IDELAYE3/ODELAYE3 延迟标定，不承载帧业务 |
| DDR0/DDR1 `ui_clk` | 266.525 MHz | 由各 MIG 产生，512-bit AXI 用户接口 |
| MDC | 1.667 MHz | PHY MDIO 配置 |

外部板级复位由 `sw3_1 && sw4_1` 电平控制。复位不是 AXI 事务，也不会通过 AXI 总线传播；顶层把复位线分别接到自研模块、XPM FIFO、AXI Clock/Width Converter、DataMover、MIG 用户接口和 MAC/PHY 管理模块的 reset/aresetn。各时钟域异步进入复位、在本地时钟同步释放。

正常 END 或 ERROR 停止握手完成后，独立 supervisor 把全局复位保持 64 个 100 MHz 周期。跨时钟域数据使用 AXI Clock Converter、XPM async FIFO、Gray pointer/bus-skew 约束或“稳定数据 + toggle”；单 bit 状态使用多级 `ASYNC_REG`。禁止把多 bit 总线逐 bit 用普通两级触发器同步后直接解释。

## 8. RGMII RX 稳定性修改

原板级“复位后本轮一直正常、一直丢包或一直超时”的主要根因是 DP83867 内部 RGMII delay、FPGA IDELAY 校准和 RXC 启动相位共同使采样点落在数据眼边缘。单帧 PRECONFIG 可能侥幸通过，但连续程序帧会放大 FCS 错误概率。

当前组合为：PHY TX delay 2.00 ns、PHY RX delay 1.00 ns、FPGA RX IDELAYE3 1100 ps；RXC 全局时钟根采用 `X2Y2`。最终外部 RGMII RX setup/hold 为 `+0.254/+0.306 ns`。系统只有在 refclk 校准 guard、PHY 初始化、link 稳定、RXC 本地域边沿计数和同步回控制域全部完成后才拉高 `rgmii_rx_ready`。MAC 丢弃 FCS 错帧时同时产生 32-bit 计数和一次 `66660075` 错误报告。

曾测试 1250 ps IDELAY，但器件在 333.333 MHz 参考时钟下合法上限是 1100 ps，DRC 报 `AVAL-174`，因此该试验被明确废弃，没有用于最终位流。

## 9. 本轮前仿与软件验证

### 9.1 两轮完整顶层自动化

证据目录：`output/verification/automation_10x10k/campaign_20260825_005851`。

| 轮次 | seed | 程序大小 | 程序帧 | 结果 | 用时 |
| ---: | ---: | ---: | ---: | --- | ---: |
| 1 | 32052531 | 80024 Byte | 79 | PASS | 1168.937 s |
| 2 | 32052532 | 80024 Byte | 79 | PASS | 1120.486 s |

每轮分别目标 hart0/hart1 约 10000 条，使用不同 seed。hart0 因启动流程产生 10001 条记录，hart1 为 10000 条。每轮最终结果均为：

```text
FULL_SYSTEM_RGMII_PASS frames=350 info=14 data=334 done=2
records=10001/10000 rgmii_cycles=492132 min_ifg=80 rx_overflow=0
```

程序不是直接预装 DDR，而是由顶层 RGMII 驱动以 96 ns 的协议允许最小 IFG 连续注入 79 个程序帧，再发结束帧；路径经过 TEMAC RX FIFO、分类器、帧号检查、DataMover 和 DDR0。执行结束后，334 个 Info 数据帧和两个完成帧从实际顶层 RGMII TX 采集，再交给真实 WebUI 解码器。解码器检查源/目的 MAC、EtherType、帧号、尾部 padding、每 hart sequence 覆盖、重复/缺失和完成帧计数。

两轮严格串行：上一轮完整顶层仿真和 WebUI 检查均 PASS 后，下一轮才开始。`round_03_seed_32052533` 只包含用户取消前产生的程序文件，从未启动 Vivado、没有仿真结果，不属于通过轮次。自动化脚本默认轮数已从 10 改为 2。

本轮为了节省时间，程序由本地直接 RV32IM 指令生成器产生，不依赖 Ubuntu/riscv-dv；硬件仍按 RV32IMAC 配置，C/A 保持使能，但该快速生成器主体使用 32-bit I/M 指令。这里验证的是硬件完整数据流和随机双 hart 执行，不是 Spike 逐条参考比较。

### 9.2 定向与压力测试

- `tb_info_fifo_read_elastic`：1000 beat、1999 条记录、随机背压；
- `tb_info_elastic_dma_integration`：hart0 259、hart1 150 条，覆盖随机 AXI 背压、公平轮转、尾记录；
- `tb_info_ddr_read_dma_fixed30`：按有效记录数真实读取、本地补零到固定 30 beat、4 KiB 边界拆分；
- `tb_info_tx_frame_fifo_2slot`：两个整帧槽的 full、背压、顺序、release 和恢复；
- `tb_info_log_dump_subsystem_multiframe`：419 帧、12510 次 DDR read，超过旧板级约 205 帧的故障位置；
- `tb_info_fifo_async_tail`：真实 XPM async FIFO，17 条奇数尾记录；
- capture 新旧结构差分：50000 周期逐周期等价；
- 控制状态机、PRECONFIG 只能一帧的正反例、RX 分类、程序 DMA 序号、DDR 检查、FCS/overflow/error CDC 均通过；
- Windows WebUI 单元测试 24 项全部通过，包括状态映射、错误后可再次启动自动化、日志保存和 sequence coverage。

## 10. 综合、实现与时序结果

| 项目 | 最终结果 |
| --- | --- |
| 生产层级 | EH2、双 MIG、MAC、程序 DMA、Info 双 FIFO/DDR DMA/双帧槽、控制器均存在 |
| unexpected blackbox | 0 |
| route | 376352/376352 routable nets fully routed，error 0 |
| setup | WNS `+0.045 ns`，TNS 0，失败端点 0 |
| hold | WHS `+0.009 ns`，THS 0，失败端点 0 |
| pulse width | 最差 `+0.046 ns` |
| RGMII RX | setup `+0.254 ns`，hold `+0.306 ns` |
| bus skew | 74 组全部通过，最差 `+2.218 ns` |
| DRC | 0 Error，0 Critical Warning；102 Warning，6 Advisory |
| Bitgen | 0 Error，0 Critical Warning |

生产捕获路径使用 `instr_info_capture_dual_hier` 和两个 `instr_info_capture_hart_bank`；旧的单体模块仅更名为差分测试 reference，不进入生产网表。hart0/hart1 bank 分别引导到 SLR1/SLR2，DDR0/EH2 关键路径做物理引导，以降低跨 SLR 拥塞。Info FIFO 与 DDR1 写 DMA 之间的 elastic register 切断 266.525 MHz 下的长组合反馈路径。

最终路由峰值约 19.3 GB，超过本机约 16.9 GB 物理内存时依赖分页文件。本次保持单个 Vivado 任务；综合内部最多 4 线程、place 2 线程、route 报告内部最多 8 线程，没有采用曾导致超过 50 GB 风险的 AggressiveExplore。后续应把避免内存崩溃置于速度之前。

## 11. 实际遇到的问题、原因与解决办法

### 11.1 WAW 跨 hart 污染

旧结构共享/错位了 WAW 事件与 sequence 配对，所以 hart0 多出的编号常恰好落在 hart1 WAW 相邻序号之间。当前按 hart 完全分离捕获 bank、sequence、nonblock 寄存器槽和匹配，只允许同 hart cancel number；差分和双 hart 测试覆盖了配对。

### 11.2 程序下载偶发丢包、超时或无响应

根因不是“RX FIFO 读时钟比写时钟快就一定安全”。RGMII 边缘采样错误会让 TEMAC 直接丢弃 FCS 错帧，帧根本不会进入用户 FIFO；复位会重建 PHY/IDELAY/RXC 相位，因此表现为一次复位后的多轮结果高度相关。修复包括重新标定 PHY/FPGA delay、合法选择 RXC clock root、确定性 RX 放行、FCS 计数/错误码、程序帧 sequence 和结束帧总数核对。

### 11.3 RX 分类器溢出

旧分类逻辑可能先缓存整帧再决定去向，1028-Byte payload 连续到达时占用过高。当前只缓存判断目的 MAC 所需的前三个 16-bit 字，随后流式送往程序或系统通路；两个目的 MAC、EtherType 和 FIFO 分开，结束帧不会污染程序 DMA payload。

### 11.4 PROGRAM_WRITE 提前完成

仅收到结束帧不能证明最后一帧已写入 DDR。当前必须同时比较连续接收帧数、结束帧声明总数、成功 DMA 数和 DMA idle。`44114444` 只表示“看见结束帧”，`44444444` 才表示烧写校验和 DMA 全完成。

### 11.5 DDR1 写 DMA 永久 busy

旧代码把 XPM `rd_occupancy` 与 elastic 中的 `buffered_records` 相加；由于跨域计数在 pop 后滞后，同一条数据可能被计算两次，DMA 会声明比真实数据更长的 AW burst，最后等待不存在的 W beat。修复后 burst 规划只使用保守的 XPM occupancy；empty 同时要求 XPM 和 elastic 都空，尾部使用单 beat fallback。这样可能少合并一笔 burst，但不会破坏 AXI 完整性。

### 11.6 DDR1 读 DMA/旧发送 FIFO overflow

旧读 DMA使用跨域同步后、存在延迟的 FIFO 剩余空间来规划最多 64-beat 的 AR。AR 握手后 DDR 已承诺返回整笔数据，MAC 背压时无法撤回，因而可能 overflow。最终架构不再按滞后 byte free-count冒险：每帧先原子占用完整帧槽，再按有效记录数发出不可撤销的 DDR 读拍，并在本地补零到构帧侧固定 30 beat；帧未 publish/释放前不会复用。两槽提供一读一写并行和确定的帧粒度背压。

### 11.7 END 同一帧重复启动

旧调度器发出注册的 `read_start/build_start` 后，下游 `busy` 下一拍才生效，空窗期可能再次启动同一 frame number。修复后启动条件显式排除 start、busy 和 done，并由 `read_done` 优先更新 frame number/remaining，之后才允许下一帧。

### 11.8 为什么以前短前仿未发现板级 overflow

以前的测试存在三类覆盖缺口：没有持续走真实顶层 RGMII/MAC；回传只有少量帧或 MAC 几乎不背压；仿真程序通过短循环制造动态提交而不是多帧烧写和长回传。因此未覆盖跨域计数滞后、第二帧槽满、几百帧后的重复启动和 FCS 丢帧。当前用完整顶层两轮、419 帧定向回传、随机 AXI/TX 背压和真实 XPM 奇数尾记录补齐这些场景。

### 11.9 拥塞和时序违例

双 MIG、EH2 网表、宽 AXI、四写 Info 采集和跨 SLR 路径集中造成拥塞，新增日志功能会提高布线压力。修复不是删除功能，而是将双 hart 捕获拆为物理 bank、增加等价 elastic pipeline、合理分散 SLR 并重跑完整差分仿真。RGMII hold 则通过合法重建 RXC clock tree解决，没有使用非法 IDELAY 数值。

### 11.10 Vivado Run Manager 停滞

工程 Run Manager 曾只把任务标为 started，却未真正产生 child process 或 run log。确认没有在运行的综合进程后，使用工程自动生成的 `synth_1/runme.bat` 启动同一综合；综合检测到改动较大并自动放弃增量复用，执行了完整重建。最终 `.vds`、DCP 和后续 link/route 都证明当前 RTL 实际进入了生产网表。

## 12. 后续修改和上板前必须检查

1. 当前全局 WNS/WHS 只有 `+0.045/+0.009 ns`，是正裕量但很小。任何 RTL、约束、IP、PHY delay、Vivado 版本、seed 或 directive 变化都必须重新综合实现和签核。
2. 不只看 WNS：必须同时检查 TNS、WHS/THS、pulse width、unconstrained endpoints、route status、bus skew、blackbox 和 DRC。
3. PHY MDIO 配置、FPGA IDELAY 和 XDC input/output delay 是同一个物理模型，不能只改其中一项。
4. `rgmii_phy_timing.xdc` 必须正确覆盖 IP 默认外部延迟；重复或错误加载会产生“报告通过、物理模型错误”的假象。
5. 新增异步 FIFO 或改变层级名后，确认 Gray pointer bus-skew 约束仍匹配实例；不能只用 broad false path 掩盖 CDC。
6. AXI INCR burst 不能跨 4 KiB；AW/AR 一旦握手，主机必须完成整笔 W 或接收整笔 R。不能用滞后的跨域瞬时计数控制不可撤销 burst。
7. DDR owner 只在前一 master 完全 idle 后切换，并确保 response 不会遗留给下一会话。
8. DRC Warning 目前主要是 EH2 netlist DSP/URAM 建议、LED 跨 SLR、dbg_hub 和 MIG 内部提示。它们在本版无 severe violation，但换版本或改层级后必须重新逐条分类，不能按旧结论直接忽略。
9. 生成位流时保持单个 Vivado 进程和足够分页文件；增加线程必须先看内存，不能再次采用高内存 AggressiveExplore。
10. 上板后先核对 bitstream SHA-256，再观察 `11111111 -> 44004444 -> 44114444 -> 22222222 -> 33333333`，确认 PRECONFIG 和 READY 全部完成后再发正式程序。

## 13. 文档索引

- `output/doc/README.md`：系统、Info Struct、帧和状态的主说明；
- `output/doc/system_board_readme.md`：板级引脚、时钟、RGMII 约束、实现签核；
- `output/doc/veri_readme.md`：全部前仿项目和证据；
- `output/doc/webui_automation_readme.md`：Windows WebUI 自动化、日志保存和比较；
- `output/doc/build_issue_readme.md`：历史问题、原因、修复和实现注意事项；
- `output/doc/latest_error_and_fix_readme.md`：最新 10k、DMA、帧重复与 RGMII 问题记录；
- `output/board/reports_latest/`：最终 timing、route、DRC、CDC、bus-skew 和拥塞报告。
