# EH2 双 Hart 整机系统上板与接口说明

## 1. 文档范围

本文面向 VeriTiger-V19P-A14 板卡上的最终整机工程，说明器件、约束来源、时钟与引脚、复位、DDR 所有权、以太网帧、六状态流程、错误码、LED、上板步骤及运行限制。

工程顶层为 `eh2_veri_system_top`，目标器件为 `xcvu19p_CIV-fsva3824-1-e`。最终硬件文件统一放在 `output/board`，设计说明和完整前仿说明统一放在 `output/doc`。

## 2. 四个已验证工程的复用关系

| 参考工程 | 本系统复用内容 |
| --- | --- |
| `mac_fifo_dma_proj` | PC 端程序帧经 MAC RX、FIFO、AXI DataMover 写入 DDR 的路径与 DDR0/MIG 连接方式 |
| `eth_tx` | 单个全双工 TEMAC、DP83867 MDIO 初始化、RGMII 收发、TX 仲裁及板级以太网时序约束 |
| `log_eh2_crc_fpga` | EH2 网表、双 hart 提交信号采集、CRC-64、package 归约和日志帧发送方法 |
| `eh2_veri_iss_proj` | EH2 IFU/LSU 到双 DDR 的 AXI 存储结构、双 MIG 引脚和时钟约束 |

DDR、EH2、复位、LED 和以太网物理引脚没有重新猜测，均以四个上板通过工程中的对应约束为依据。RGMII 的板级输入/输出延时文件和 RX 时钟放置文件按 `LATE` 顺序处理，以覆盖 TEMAC IP 的通用默认值。

## 3. 时钟、引脚和频率

### 3.1 外部时钟

| 顶层端口 | P/N 引脚 | I/O 标准 | 约束频率 | 用途 |
| --- | --- | --- | ---: | --- |
| `core_clk_p/n` | `BY44 / CA44` | LVDS | 50 MHz | EH2、EH2 初始化、提交采集、数据 DDR 自检 ATG |
| `atg_clk_p/n` | `BN55 / BP55` | LVDS | 100 MHz | 控制器、系统信息 FIFO、程序 DMA 客户端、MAC 管理、PHY 初始化 |
| `refclk_p/n` | `CA36 / CA37` | LVDS | 333.333 MHz | TEMAC/IDELAY 参考时钟 |
| `c0_sys_clk_p/n` | `BN26 / BP26` | MIG 定义 | 76.15 MHz | 指令 DDR（MIG0）参考时钟 |
| `c1_sys_clk_p/n` | `F32 / E32` | MIG 定义 | 76.15 MHz | 数据 DDR（MIG1）参考时钟 |
| `rgmii_rxc` | `BJ43` | LVCMOS18 | 链路提供；1 Gb/s 时约 125 MHz | TEMAC RX 和 MAC RX FIFO 写侧 |

四组板载差分时钟彼此独立。`core_clk`、`atg_clk`、MIG0 及 MIG1 的生成时钟分为异步时钟组；跨域数据通过 AXI Clock Converter、异步 FIFO、两级/三级同步器或事件 toggle CDC 传递。

### 3.2 内部时钟

| 时钟 | 频率 | 来源及主要负载 |
| --- | ---: | --- |
| `core_clk` | 50 MHz | 外部 `core_clk_p/n` 经 IBUFDS/BUFG；EH2 和硬件初始化 |
| `ctrl_clk` | 100 MHz | 外部 `atg_clk_p/n` 经 IBUFDS/BUFG；六状态控制器和两个系统信息 FIFO |
| `clk125` | 125 MHz | 100 MHz 经 MMCM；TEMAC GTX、CRC 结果读出 |
| `c0_ui_clk` | MIG 生成 | 指令 DDR 512-bit AXI UI |
| `c1_ui_clk` | MIG 生成 | 数据 DDR 512-bit AXI UI |

状态机、系统信息 RX FIFO、系统信息 TX FIFO、系统信息解码/组帧和 TX 仲裁均接 `ctrl_clk=100 MHz`。MAC RX 客户端 FIFO 把 RGMII RX 域数据跨到该时钟域。RX FIFO 的溢出事件可能短于一个 `ctrl_clk` 周期，因此先在 RX 域转换为 toggle，再经三级 `ASYNC_REG` 同步并恢复成一个控制域脉冲。

### 3.3 RGMII、MDIO 引脚

| 信号 | 引脚 |
| --- | --- |
| `rgmii_txd[3:0]` | `BF42, BF41, BE44, BJ47`（按 bit3 到 bit0） |
| `rgmii_tx_ctl` | `BN49` |
| `rgmii_txc` | `BN45` |
| `rgmii_rxd[3:0]` | `BR43, BL42, BK44, BH43`（按 bit3 到 bit0） |
| `rgmii_rx_ctl` | `BM44` |
| `rgmii_rxc` | `BJ43` |
| `mdc` | `BJ42` |
| `mdio` | `BM42` |
| `phy_resetn` | `BM47` |

上述信号使用 LVCMOS18。DP83867 使用 RGMII_ID：MDIO 初始化将 TX 内部延时设为约 2.00 ns、RX 内部延时设为约 1.50 ns。FPGA 侧 TXC 保持边沿对齐；板级 XDC 对 TX 数据设置 `-1.000 ns` 最大、`-3.000 ns` 最小输出延时，对 RX 数据设置 `-0.500 ns` 最大、`-1.500 ns` 最小输入延时，并覆盖 TEMAC 默认 RX IODELAY。

## 4. 复位与上电初始化

`sw3_1` 位于 `BU21`，`sw4_1` 位于 `BU28`，两者均为 LVCMOS12。板级有效复位条件为：

```text
board_resetn = sw3_1 && sw4_1
```

100 MHz 到 125 MHz 的 MMCM 锁定后，顶层再等待 16 个 `ctrl_clk` 周期才释放硬复位。硬复位覆盖 TEMAC、PHY 初始化、控制器、系统信息 FIFO、程序路径、日志路径和 EH2 会话。

READY 状态中的软复位只重置程序烧写会话、DataMover 写地址、EH2 执行周期、WAW/归约/日志会话和错误锁存，不复位以下硬件：

- TEMAC；
- DP83867 及 MDIO 配置；
- 两个已校准 MIG；
- 系统信息 RX/TX FIFO 及其发送路径。

上电必须完成：MMCM 锁定、TEMAC AXI4-Lite System-Init ATG、DP83867 ID/延时/自动协商、PHY 稳定链路、MIG0 校准和 MIG1 校准。板上时钟发生器目前假定已由板卡上电配置产生所需频率。

## 5. DDR 地址与总线所有权

| 项目 | 地址或范围 |
| --- | --- |
| EH2 复位向量 | `0x8000_0000` |
| 程序 DataMover 首地址 | `0x8000_0000` |
| 每个程序帧地址步长 | `0x0000_0400`（1024 byte） |
| READY 数据 DDR 清零范围 | 低 4 GiB，即 `0x0000_0000` 到 `0xFFFF_FFFF` |
| EH2 结束 MMIO | 地址 `0xD058_0000`，数据 `0x0032_0525` |

DDR0 为指令 DDR，DDR1 为数据 DDR。任何状态只允许明确的主人访问：

| 状态 | DDR0 | DDR1 |
| --- | --- | --- |
| PRECONFIG 写阶段 | 程序 DataMover | 数据自检 ATG |
| PRECONFIG 检查阶段 | 指令回读比较器 | 数据回读比较器 |
| READY | 空闲 | 4 GiB 清零主机 |
| PROGRAM_WRITE | 程序 DataMover | 空闲 |
| EXECUTE / END | EH2 IFU | EH2 LSU |
| ERROR | 无主人 | 无主人 |

所有权切换前要求当前 AXI 主机空闲；EH2 停止后还要求 IFU/LSU 已接受事务全部返回，并连续 16 个控制时钟保持空闲。

## 6. 以太网接收帧

以下长度不包含线上的 7-byte preamble、1-byte SFD 和 4-byte FCS；这些字段由 TEMAC 处理。系统不使用 VLAN 标签。

### 6.1 程序帧

帧长固定为 1038 byte：

| 字节偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC `02:12:34:56:78:FF` |
| 6 | 6 | 上位机源 MAC |
| 12 | 2 | 建议 EtherType `0x88B6` |
| 14 | 1024 | 程序 payload |

程序帧必须恰好具有 1024-byte payload。最后一帧不足部分由上位机补零，不能直接发送短帧。连续帧依次写入 `0x80000000 + frame_index*0x400`。

接收流程为：

```text
RGMII RX → TEMAC → 异步 RX FIFO → 16-bit AXI-Stream
→ 目的 MAC/精确长度分类 → 程序流控制器
→ AXI DataMover S2MM → 32-to-512 位宽转换/跨时钟
→ MIG0 → 指令 DDR
```

### 6.2 系统信息/结束帧

帧长固定为 60 byte：

| 字节偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC `02:32:05:25:00:FF` |
| 6 | 6 | 上位机源 MAC |
| 12 | 2 | EtherType `0x88B5` |
| 14 | 4 | 命令字段 |
| 18 | 42 | 保留，必须全 0 |

只有目的 MAC 和总长度都正确的帧才进入专用系统信息 RX FIFO。payload 前 4 byte 为 `FF FF FF FF` 时产生结束标记；该帧与程序帧使用不同目的 MAC，因此不会进入程序 DataMover，也不会污染程序数据。

结束标记到达并不立即表示写入完成。FPGA 在结束标记到达时快照“已接收程序帧数”，随后等待成功 DMA 完成数追上该快照且 DataMover 为 idle，才判定结束帧之前的最后一个程序帧已经真正写入 DDR。

## 7. 以太网发送帧

同一个 TEMAC 同时承担系统信息和日志发送；TX 仲裁不会在一帧中切换源。

### 7.1 系统信息帧

帧长固定为 60 byte：

| 字节偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 6 | 广播目的 MAC `FF:FF:FF:FF:FF:FF` |
| 6 | 6 | 源 MAC `02:32:05:25:00:FF` |
| 12 | 2 | EtherType `0x88B5` |
| 14 | 4 | 32-bit 状态/错误码，大端序 |
| 18 | 2 | 固定 `03 20`（字段值 `0x0320`） |
| 20 | 40 | 全 0 |

关键状态只有在目标 code 对应的整帧发送完成后才推进。PRECONFIG、READY、PROGRAM_WRITE、END 和 ERROR 使用系统信息 FIFO；EXECUTE 正常期间不让系统信息 FIFO 抢占日志帧。

### 7.2 日志归约帧

帧长固定为 1038 byte，以太网头为广播目的 MAC、源 MAC `02:12:34:56:78:FF`、EtherType `0x88B5`。1024-byte payload 如下：

| payload 偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 2 | `package_number`，大端序 |
| 2 | 1 | bit0=`hart_id` |
| 3 | 1 | 保留 0 |
| 4 | 4 | package 有效条目数，大端序 |
| 8 | 8 | `xor0` |
| 16 | 8 | `xor1` |
| 24 | 8 | `sum0` |
| 32 | 8 | `sum1` |
| 40 | 8 | `sum2` |
| 48 | 8 | `sum3` |
| 56 | 2 | WAW 取消序号数，大端序 |
| 58 | `2*N` | WAW `sequence_number`，每项 16 bit，大端序 |
| `58+2*N` | 剩余 | 全 0 |

固定字段占 58 byte，因此最多保存 `(1024-58)/2 = 483` 个 WAW 序号。第 484 个 WAW 事件不会拆分到第二帧，而是触发相应 hart 的 WAW overflow 错误并进入 ERROR。

## 8. 六状态运行过程

### 8.1 PRECONFIG

EH2 保持复位。等待 MAC 配置、PHY 初始化与链路、MIG0/MIG1 校准全部完成，发送 `0x11111111`。上位机随后只发送一帧 1024 byte 全 `FF` 的程序帧和一个结束帧；程序写入与 PROGRAM_WRITE 使用完全相同的帧计数、DMA 完成计数和 idle 配对逻辑。与此同时 50 MHz ATG 向数据 DDR 地址 0 写入 1024 byte 全 `FF`。

两套写入完成后独占 DDR 回读：指令 DDR 检查 `0x80000000` 开始的 1024 byte，数据 DDR 检查地址 0 开始的 1024 byte。PRECONFIG 必须恰好收到一个程序帧；零帧或两帧及以上均为错误。两路均通过时发送 `0x22222222` 并进入 READY。

### 8.2 READY

EH2 保持复位。使用 MIG1 原有 512-bit UI 和最大 16 KiB INCR burst 清零数据 DDR 的低 4 GiB，不改 MIG 配置。完成后对程序会话、EH2 会话和日志会话做 16 个控制时钟的软复位，MAC、PHY、MIG 及系统信息 FIFO 不复位。发送 `0x33333333` 完成后进入 PROGRAM_WRITE。

### 8.3 PROGRAM_WRITE

EH2 保持复位，DDR0 只归程序 DataMover。若没有程序帧则一直等待。首次程序 AXI 写握手后启动 20 s 定时器。上位机将大程序拆为连续的 1024-byte payload 帧，最后一帧发完后立即发送结束帧，不等待 FPGA 的 DMA done。

控制器只有在“收到结束帧、成功 DMA 完成数等于结束时快照帧数、DataMover idle”三个条件同时成立后才发送 `0x44444444`，发送完成后进入 EXECUTE。20 s 超时发送 `0x44440011` 并进入 ERROR。

### 8.4 EXECUTE

先把两个 DDR 的控制权完整交给 EH2并保持 16 个控制时钟保护时间，再释放 EH2 周期复位。硬件初始化通过 EH2 DMA slave 清零各 64 KiB DCCM/ICCM并生成 ECC，随后 debug run hart0。

hart0 从 `0x80000000` 执行，仅 hart0 在程序开头写 `CSR 0x7FC = 2`，解除 hart1 的启动门控。hart1 的 `mpc_reset_run_req[1]=1`，因此门控解除后直接从同一复位向量运行；hart0 仍由 debug halt/run 受控。

每个 hart 向结束 MMIO 写指定值后停止收集其后续提交并封闭最后一个 package。等待两个 hart 均停止、全部日志帧发完、IFU/LSU 所有已接受事务返回且空闲稳定 16 个控制时钟后，进入 END。EXECUTE 不设运行超时。

### 8.5 END

DDR 控制权仍留给 EH2，先发送 `EH2_DONE=0x55555555`，再发送 `EXE_END=0x77777777`。两帧完成后返回 READY，开始下一轮数据 DDR 清零和会话软复位。

### 8.6 ERROR

错误监测器采用 first-error-wins：第一项错误锁存后不被后续错误覆盖。若正在发送日志帧，先让当前帧完整结束，再发送一次错误信息。随后永久停留 ERROR，EH2 保持复位、DDR 所有者置空、LED0 点亮。

## 9. 系统信息码

| Code | 含义 |
| --- | --- |
| `11111111` | PREINIT_DONE |
| `22222222` | 双 DDR 通路检查通过 |
| `22220011` / `22220022` | 数据 DDR / 指令 DDR 检查失败 |
| `33333333` | READY |
| `44444444` | PROGRAM_WRITE_DONE |
| `44440011` | 程序写入超时 |
| `44440022` / `44440033` / `44440044` | 程序写入 / FIFO / DMA 错误 |
| `55555555` | EH2 执行与日志完成 |
| `66660011` / `66660012` | hart0 / hart1 nonblock buffer overflow |
| `66660021` / `66660022` | hart0 / hart1 to-hash FIFO overflow |
| `66660033` / `66660044` | TX MAC FIFO / TX stream 错误 |
| `66660051` / `66660052` | hart0 / hart1 WAW 容量溢出 |
| `66660061` / `66660062` | hart0 / hart1 package bank 冲突 |
| `66660071` / `66660072` | 系统信息 RX / TX FIFO overflow |
| `66660073` / `66660074` | RX 帧缓冲 overflow / 识别帧长度错误 |
| `66660081` / `66660082` / `66660083` | MAC 配置 / PHY 初始化 / PHY 链路错误 |
| `66660091` / `66660092` | MIG0 / MIG1 初始化超时 |
| `666600A1` / `666600A2` | DDR 清零 / DDR 检查错误 |
| `666600B1` / `666600B2` / `666600B3` | EH2 初始化 / IFU AXI / LSU AXI 错误 |
| `666600F1` | 非法状态 |
| `77777777` | EXE_END |

## 10. Hash、package 与归约

每个提交条目将 hart、序号、PC、指令及架构相关字段组成 160-bit 数据。CRC 使用 CRC-64/ECMA-182 多项式 `0x42F0E1EBA9EA3693`，初值和最终异或均为 0，按硬件定义的字节/位顺序逐项更新。

CRC 结果经过与 package、序号相关的 G 混合后形成归约输入。每个 hart 独立累计六个 64-bit 量：两个 XOR 槽和四个模 `2^64` 加法槽。package 正常容量为 65536 个有效条目；package 封闭后把 count、六个归约值及同一 package 的 WAW 取消序号作为原子快照发送。

同一 hart 的后写覆盖前写时，被取消的旧指令不进入最终有效归约，其 16-bit `sequence_number` 按发生顺序记录。WAW 列表分 hart、分 package 奇偶 bank 保存，发送完成后才能释放相应 bank，避免结果与序号错配。算法的逐位定义、160-bit 字段顺序和黄金值见同目录 `README.md` 与 `veri_readme.md`。

## 11. LED

| LED | 引脚 | 含义 |
| ---: | --- | --- |
| 0 | `BE22` | ERROR 锁死 |
| 1 | `BG23` | MAC 配置完成且无错误 |
| 2 | `BJ20` | PHY 初始化成功 |
| 3 | `BN19` | MIG0 校准完成 |
| 4 | `U34` | MIG1 校准完成 |
| 5 | `T37` | 当前为 PROGRAM_WRITE |
| 6 | `K37` | 当前为 EXECUTE |
| 7 | `M39` | 当前为 END |

LED 均为 LVCMOS12、active high。

## 12. 上板运行步骤

1. 确认板载时钟已配置为本文频率，两个复位开关处于释放状态。
2. 下载 `output/board/eh2_veri_system.bit`。
3. 等待上位机收到 `PREINIT_DONE`。
4. 发送一帧 PRECONFIG 全 FF 程序帧，紧接着发送结束帧。
5. 收到 `CHECK_PASS` 后等待 `READY`；READY 之前 FPGA 会清零完整 4 GiB 数据 DDR。
6. 把程序补零并拆为 1024-byte 帧连续发送，最后一帧之后立即发送结束帧。
7. 收到 `PROGRAM_WRITE_DONE` 后停止向程序路径发送数据；EH2 将开始双 hart 执行。
8. 接收并解析一个或多个日志帧，随后接收 `EH2_DONE` 和 `EXE_END`。
9. 下一次 `READY` 表示新一轮会话可以开始。

## 13. 实现签核结果

本节由最终无临时路径错误的布线后检查点填写：

| 项目 | 最终值 |
| --- | --- |
| 综合 | `待最终签核` |
| 布线状态 | `待最终签核` |
| Setup WNS / TNS | `待最终签核` |
| Hold WHS / THS | `待最终签核` |
| Pulse-width WPWS / TPWS | `待最终签核` |
| DRC | `待最终签核` |
| CDC | `待最终签核` |
| Bitstream SHA-256 | `待最终签核` |

所有详细报告保存在 `output/board/reports`。只有最终 setup、hold、pulse-width 均无违例、路由完整、DRC 无 Error、CDC 中自有跨域均为受认可结构后，bitstream 才作为最终交付。

## 14. 已验证内容与运行限制

完整前仿已经验证 PRECONFIG 到第二次 READY 的闭环状态序列；200,000 条静态指令被补零后拆成 782 个真实 1024-byte 程序帧，从顶层 RGMII/MAC RX 经 DataMover 写入 DDR0，再由双 hart 执行。四个日志帧的 count 和六项归约值与 Spike 黄金结果逐字段一致。

运行限制如下：

- 程序帧只能是固定 1024-byte payload，系统信息帧只能是固定 46-byte payload；
- 不支持 VLAN 标记、IP/UDP 封装或短程序帧；
- 程序帧当前没有应用层序号、总长度或 image CRC，依赖有线链路 FCS、固定帧长和顺序发送；
- 指令 DDR 只覆盖本次实际收到的连续 image，不在 READY 清零整个指令 DDR；
- 数据 DDR 每轮清零完整低 4 GiB，所需时间取决于 MIG UI 实际吞吐；
- 程序写入从首次 AXI 写开始计时 20 s；EXECUTE 没有超时；
- 每个 hart、每个 package 最多 483 个 WAW 取消序号；
- 系统信息为二层广播且没有 ACK/重发机制；
- 链路丢失和初始化失败按致命错误处理，不做自动重新协商恢复；
- 当前假定板载时钟发生器已在 FPGA 配置前提供正确频率；
- MIG、TEMAC 和 PHY 配置沿用已上板验证工程，不改变其电气参数。

更完整的系统算法、模块列表、双 hart 启动问题及前仿证据分别见同目录的 `README.md` 和 `veri_readme.md`。
