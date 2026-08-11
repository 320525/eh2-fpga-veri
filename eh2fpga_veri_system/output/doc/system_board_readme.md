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

上述信号使用 LVCMOS18。DP83867 使用 RGMII_ID：MDIO 初始化将 TX 内部延时设为约 2.00 ns、RX 内部延时设为约 1.25 ns。FPGA 侧 TXC 保持边沿对齐；板级 XDC 对 TX 数据设置 `-1.000 ns` 最大、`-3.000 ns` 最小输出延时，对 RX 数据设置 `-0.250 ns` 最大、`-1.250 ns` 最小输入延时，并保留 1100 ps FPGA RX IODELAY。RX 从原 1.50 ns 调到 1.25 ns，是把旧实现中过多的 setup 裕量转移到仅 0.047 ns 的 hold 侧；最终数值仍必须以本次重新实现的定向 setup/hold 报告为准。

## 4. 复位与上电初始化

`sw3_1` 位于 `BU21`，`sw4_1` 位于 `BU28`，两者均为 LVCMOS12。板级有效复位条件为：

```text
board_resetn = sw3_1 && sw4_1
```

板级复位开关先经过 16 个控制时钟的上电释放管线。系统运行中不再使用旧版“只复位程序/EH2/日志会话”的软复位：正常 `END` 的最后一帧物理发送完成后，或 `ERROR` 错误帧发送完成且上位机回送 `HOST_SEND_STOPPED=0x44124445` 后，控制器向独立的全局复位监督器提出请求。监督器在 `ctrl_clk=100 MHz` 域把全系统复位连续拉低 64 个周期（640 ns），覆盖 TEMAC、PHY/MDIO、两个 MIG、所有 FIFO、程序 DMA、控制器、EH2、CRC/WAW 和日志路径，然后从 `PRECONFIG` 重新开始初始化。

`READY` 清零完成后仅发出一个控制时钟的 `program_session_clear`，用于把 PRECONFIG 的程序帧序号、包数、DMA 完成计数和首地址重新装载为正式 PROGRAM_WRITE 初值；它不是时钟域复位，也不复位 MAC、PHY、MIG、EH2 或日志模块。

上电必须完成：MMCM 锁定、TEMAC AXI4-Lite System-Init ATG、DP83867 ID/延时写入及回读、自动协商、链路连续稳定 100 ms、MIG0 校准和 MIG1 校准。上述条件成立后再等待 1 ms IDELAY guard，并在恢复的 `rgmii_rxc` 域连续观察 4096 个稳定边沿，才允许 MAC RX 客户端数据进入分类器。任何重新全局复位都会重新执行这套确定性放行。板上时钟发生器目前假定已由板卡上电配置产生所需频率。

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

帧长固定为 1042 byte：

| 字节偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC `02:12:34:56:78:FF` |
| 6 | 6 | 上位机源 MAC |
| 12 | 2 | 建议 EtherType `0x88B6` |
| 14 | 4 | `frame_sequence`，32 bit 大端序，从 0 严格连续递增 |
| 18 | 1024 | 程序数据；仅此字段写入 DDR |

程序帧必须恰好具有 1028-byte payload。最后一帧程序数据不足部分由上位机补零，不能直接发送短帧。FPGA 剥离并检查 4-byte 序号，只把后 1024 byte 依次写入 `0x80000000 + frame_index*0x400`。

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
| 14 | 4 | 命令字段；结束帧为 `FF FF FF FF` |
| 18 | 4 | 本次程序帧总数，32 bit 大端序 |
| 22 | 38 | 保留，必须全 0 |

只有目的 MAC 和总长度都正确的帧才进入专用系统信息 RX FIFO。payload 前 4 byte 为 `FF FF FF FF` 时产生结束标记；该帧与程序帧使用不同目的 MAC，因此不会进入程序 DataMover，也不会污染程序数据。

结束标记到达并不立即表示写入完成。FPGA 在结束标记到达时锁存声明总数，比较其与从 0 连续接收的帧数，并等待成功 DMA 完成数追上该总数且 DataMover 为 idle，才判定结束帧之前的最后一个程序帧已经真正写入 DDR。

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

EH2 保持复位。等待 MAC 配置、PHY 初始化与链路、MIG0/MIG1 校准全部完成，发送 `0x11111111`。上位机随后只发送编号 0 的一帧 1024 byte 全 `FF` 程序数据和声明总数 1 的结束帧；首帧写入和结束帧到达分别发送 `0x44004444`、`0x44114444`。程序写入与 PROGRAM_WRITE 使用完全相同的序号、总数、DMA 完成计数和 idle 配对逻辑。与此同时 50 MHz ATG 向数据 DDR 地址 0 写入 1024 byte 全 `FF`。

两套写入完成后独占 DDR 回读：指令 DDR 检查 `0x80000000` 开始的 1024 byte，数据 DDR 检查地址 0 开始的 1024 byte。PRECONFIG 必须恰好收到一个程序帧；零帧或两帧及以上均为错误。两路均通过时发送 `0x22222222` 并进入 READY。

### 8.2 READY

EH2 保持复位。使用 MIG1 原有 512-bit UI 和最大 16 KiB INCR burst 清零数据 DDR 的低 4 GiB，不改 MIG 配置。清零完成且没有错误后，发出一个控制时钟的 `program_session_clear`，只清除 PRECONFIG 留下的程序会话记账；随后发送 `0x33333333`，该帧物理发送完成后进入 PROGRAM_WRITE。READY 本身不执行全局复位；全局复位发生在上一轮 END 完成或 ERROR/上位机停止握手完成之后，并会先返回 PRECONFIG。

### 8.3 PROGRAM_WRITE

EH2 保持复位，DDR0 只归程序 DataMover。若没有程序帧则一直等待。首次程序 AXI 写握手后启动 20 s 定时器并发送 `0x44004444`。上位机将大程序拆为连续的编号+1024-byte 数据帧，最后一帧发完后立即发送带总包数的结束帧，不等待 FPGA 的 DMA done；收到结束帧时 FPGA 发送 `0x44114444`。

控制器只有在“收到结束帧、声明总数等于连续接收帧数、成功 DMA 完成数等于该总数、DataMover idle”同时成立后才发送 `0x44444444`，发送完成后进入 EXECUTE。20 s 超时、序号、总数、DMA、FIFO、帧长或 MAC FCS 错误均立即进入 ERROR。上位机收到错误码后必须立即停止后续程序帧并回送 `0x44124445`；FPGA 收到该确认且错误帧已完成后才请求全局复位，避免复位时仍有帧进入旧会话。

### 8.4 EXECUTE

先把两个 DDR 的控制权完整交给 EH2并保持 16 个控制时钟保护时间，再释放 EH2 周期复位。硬件初始化通过 EH2 DMA slave 清零各 64 KiB DCCM/ICCM并生成 ECC，随后 debug run hart0。

hart0 从 `0x80000000` 执行，仅 hart0 在程序开头写 `CSR 0x7FC = 2`，解除 hart1 的启动门控。hart1 的 `mpc_reset_run_req[1]=1`，因此门控解除后直接从同一复位向量运行；hart0 仍由 debug halt/run 受控。

每个 hart 向结束 MMIO 写指定值后停止收集其后续提交并封闭最后一个 package。等待两个 hart 均停止、全部日志帧发完、IFU/LSU 所有已接受事务返回且空闲稳定 16 个控制时钟后，进入 END。EXECUTE 不设运行超时。

### 8.5 END

DDR 控制权仍留给 EH2，先发送 `EH2_DONE=0x55555555`，再发送 `EXE_END=0x77777777`。控制器用物理 MAC TX 完成计数确认两帧都已真正离开 TEMAC，随后请求持续 64 个控制周期的全局复位；复位释放后从 PRECONFIG 重新验证 MAC、PHY 和两套 DDR，而不是直接跳到 READY。

### 8.6 ERROR

错误监测器采用 first-error-wins：第一项错误锁存后不被后续错误覆盖。若正在发送日志帧，先让当前帧完整结束，再发送一次错误信息。ERROR 处理期间 EH2 保持复位、DDR 所有者置空、LED0 点亮。上位机一旦收到错误码就立即终止程序发送，并向系统 MAC 发送 `HOST_SEND_STOPPED=0x44124445`；FPGA 只有在该确认和错误帧物理发送完成两个条件都成立后才请求全局复位。复位覆盖 MAC、PHY、MIG、FIFO 和全部业务模块，持续 64 个 `ctrl_clk` 周期，释放后回到 PRECONFIG；错误码只发送一次。

## 9. 系统信息码

| Code | 含义 |
| --- | --- |
| `11111111` | PREINIT_DONE |
| `22222222` | 双 DDR 通路检查通过 |
| `22220011` / `22220022` | 数据 DDR / 指令 DDR 检查失败 |
| `33333333` | READY |
| `44004444` | PROGRAM_WRITE_START（PRECONFIG与正式写入均发送） |
| `44114444` | RECEIVE_DONE（仅表示收到结束帧） |
| `44124445` | HOST_SEND_STOPPED（上位机收到任一错误后停止程序发送并回送） |
| `44444444` | PROGRAM_WRITE_DONE |
| `44440011` | 程序写入超时 |
| `44440022` / `44440033` / `44440044` | 程序写入 / FIFO / DMA 错误 |
| `44440055` / `44440066` | 程序帧序号错误 / 结束帧总包数错误 |
| `55000000` / `55010000` | hart0 / hart1 第一次实际提交指令 |
| `550000FF` / `550100FF` | hart0 / hart1 已停止 |
| `55555555` | EH2 执行与日志完成 |
| `66660011` / `66660012` | hart0 / hart1 nonblock buffer overflow |
| `66660021` / `66660022` | hart0 / hart1 to-hash FIFO overflow |
| `66660033` / `66660044` | TX MAC FIFO / TX stream 错误 |
| `66660051` / `66660052` | hart0 / hart1 WAW 容量溢出 |
| `66660061` / `66660062` | hart0 / hart1 package bank 冲突 |
| `66660071` / `66660072` | 系统信息 RX / TX FIFO overflow |
| `66660073` / `66660074` | RX 帧缓冲 overflow / 识别帧长度错误 |
| `66660075` | TEMAC RX FCS 错误统计增加；坏帧已被 MAC 丢弃 |
| `66660081` / `66660082` / `66660083` | MAC 配置 / PHY 初始化 / PHY 链路错误 |
| `66660091` / `66660092` | MIG0 / MIG1 初始化超时 |
| `666600A1` / `666600A2` | DDR 清零 / DDR 检查错误 |
| `666600B1` / `666600B2` / `666600B3` | EH2 初始化 / IFU AXI / LSU AXI 错误 |
| `666600F1` | 非法状态 |
| `77777777` | EXE_END |

## 10. Hash、package 与归约

每个提交条目将 hart、序号、PC、指令及架构相关字段组成 160-bit 数据。CRC 使用 CRC-64/ECMA-182 多项式 `0x42F0E1EBA9EA3693`，初值和最终异或均为 0，按硬件定义的字节/位顺序逐项更新。

CRC 结果经过与 package、序号相关的 G 混合后形成归约输入。每个 hart 独立累计六个 64-bit 量：两个 XOR 槽和四个模 `2^64` 加法槽。package 正常容量为 65536 个有效条目；package 封闭后把 count、六个归约值及同一 package 的 WAW 取消序号作为原子快照发送。

同一 hart 的后写覆盖前写时，被取消的旧指令不进入最终有效归约，其 16-bit `sequence_number` 按发生顺序记录。50 MHz 提交域最多同拍产生四个 WAW 槽：两路 direct commit victim 加两路 pending-nonblocking victim；每槽各用一个 `33 bit × 16` 异步 FIFO 跨到 100 MHz。四路用于保存同拍并发，不增加协议容量。100 MHz store 按 hart 和 package 奇偶 bank 保存，并用完整 16-bit package number 校验 bank 所有权；同拍同组事件用前缀计数写入连续地址。发送完成后才能释放 bank，避免结果与序号错配；第 484 条触发对应 hart 的 overflow。算法逐位定义、四路信号产生、CDC 和黄金值见同目录 `README.md` 与 `veri_readme.md`。

## 11. LED

| LED | 引脚 | 含义 |
| ---: | --- | --- |
| 0 | `BE22` | 正在 ERROR 处理；收到上位机停止确认并开始全局复位后熄灭 |
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
9. `EXE_END` 物理发送完成后 FPGA 全局复位；下一轮先等待新的 `PREINIT_DONE`，重做 PRECONFIG 检查后才会再收到 `READY`。

## 13. 实现签核结果

最终器件为 `xcvu19p_CIV-fsva3824-1-e`，顶层为 `eh2_veri_system_top`。以下数值来自 2026-08-06 最新 RTL/XDC 的 fully-routed DCP 和由该 DCP 生成的未压缩 bitstream，不是 2026-08-01/04 的早期实现结果。综合层次和 `post_opt/post_route` 黑盒门禁确认 EH2 EDIF、两套 MIG、TEMAC、DataMover、程序/系统 FIFO、六状态控制器、全局复位监督器、确定性 RX 放行、FCS 统计 CDC、双 hart hash、四路 WAW CDC/store 以及日志组包路径全部进入最终网表；未解析系统黑盒为 0。

| 项目 | 最终值 |
| --- | --- |
| 综合 | `0 Error / 0 Critical Warning`；系统未解析黑盒 `0`；综合阶段仅有 Vivado 延迟插入的 `dbg_hub` 占位，`post_opt=0`、`post_route=0` |
| 综合资源 | CLB LUT `372309`、CLB Register `181219`、BRAM Tile `89.5`、URAM `20`、DSP `10` |
| 布线状态 | logical nets `621931`；routable nets `471183`，fully routed `471183`，unrouted/routing errors `0` |
| Setup WNS / TNS | `+0.082 ns / 0.000 ns`，失败端点 `0 / 456650` |
| Hold WHS / THS | `+0.010 ns / 0.000 ns`，失败端点 `0 / 454811` |
| Pulse-width WPWS / TPWS | `+0.046 ns / 0.000 ns`，失败端点 `0` |
| Bus skew | `113` 个 corner/constraint 项全部满足，最小 slack `+2.508 ns`，`0 VIOLATED` |
| DRC | `0 Error / 0 Critical Warning / 102 Warning / 6 Advisory` |
| Bitstream | 未压缩，`199112135 byte` |
| Bitstream SHA-256 | `1A201E64A760228E298B285A723EBD2D911B7F275CF80E9733EE6826BBF2D2FC` |
| 最新 routed DCP SHA-256 | `2A8C84692268E6967B26175D4C9AC1A2FDE960F43A16F15726224D8BF7049DAA` |
| 前仿 BIN SHA-256 | `5D073F32602F986E6AE253F425046271C4255402067632DA7C6FFD43E4A1CCFC` |

最终关键报告保存在 `output/board/reports_latest`：`timing_summary.rpt`、`bus_skew.rpt`、`route_status.rpt` 和 `drc.rpt` 均由 `eh2_veri_system_routed_latest.dcp` 在同一恢复流程中生成。`output/board/reports_final` 和无 `latest` 后缀的旧 DCP/报告只保留历史诊断价值，交付判断必须以 `reports_latest` 和 `SHA256SUMS.txt` 为准。

中间布局/物理优化报告曾出现负 hold；它们都不能作为签核结论。最终 route 的延迟/偏斜修复把 hold 收敛到 `+0.010 ns`，setup 为 `+0.082 ns`，pulse width 为 `+0.046 ns`，三类失败端点均为 0。这说明必须检查与最终 bitstream 同源的 fully-routed DCP。

### 13.1 DRC 分类

最终 DRC 共 108 项，其中 102 项为 Warning，6 项为 Advisory：

| 规则 | 数量 | 解释和处理 |
| --- | ---: | --- |
| `DPIP-2` | 7 | EH2 乘法器 DSP 输入未完全流水化；属于性能/功耗建议，最终时序已通过 |
| `DPOP-3` / `DPOP-4` | 3 / 3 | EH2 DSP 的 PREG/MREG 未使用；不修改已验证处理器网表 |
| `DPOR-2` | 64 | EH2 乘法路径使用异步复位，妨碍寄存器并入 DSP；不是功能错误 |
| `IOBUSSLRC-1` | 1 | LED 总线因固定板卡引脚跨 SLR0/SLR2；LED 不是高速并行接口 |
| `PDCN-1569` | 3 | Vivado 生成的 `dbg_hub` LUT 未用方程输入 |
| `REQP-1859` | 20 | EH2 DCCM/ICCM/I-cache URAM parity-interleaved BWE8 提示；保留原验证网表结构 |
| `RTSTAT-10` | 1 | 417 条无可路由负载网络，主要是 MIG 校准/XSDB 未使用分支；路由错误仍为 0 |
| `AVAL-155` | 4 | DSP 功耗优化建议 |
| `SECHK-3` / `SECHK-4` | 1 / 1 | 器件 line-rate 和 I/O 数量检查均在允许范围内 |

任何新增的 DRC Error、Critical Warning、未解析黑盒、route error，或不属于上表实例范围的新 Warning，都必须阻止 bitstream 交付，不能通过简单降级告警来绕过。

### 13.2 CDC 与复位告警解释

从最终 routed DCP 重新生成的原始 `report_cdc` 统计如下。这里的 Severity 是 Vivado 对无法仅凭网表识别其协议的结构分类，不等同于已经观察到同数量的功能故障。

| CDC ID | Severity | 数量 | 本系统中的主要来源/结论 |
| --- | --- | ---: | --- |
| `CDC-1` | Critical | 160 | POR、EH2/hash 网表及部分握手保持总线；必须按实例审查，不能只按总数放行 |
| `CDC-3` | Info | 532 | 带 `ASYNC_REG` 的单比特同步链；RX overflow 数据 toggle 属于这一类 |
| `CDC-6` | Warning | 4 | 多比特同步器提示；逐实例确认不是彼此独立采样的业务数据总线 |
| `CDC-7` | Critical | 338 | 全局 POR、XPM FIFO、MIG/TEMAC/EH2 内部的异步复位跨域 |
| `CDC-9` | Info | 122 | 带 `ASYNC_REG` 的异步复位同步释放链 |
| `CDC-10` | Critical | 9 | 同步器前有组合逻辑；本次包含 reset 网络，不能误解释为 RX overflow 数据事件 |
| `CDC-15` | Warning | 25894 | XPM/TEMAC FIFO 的 Gray/clock-enable 结构，以及结果握手的源端保持数据 |
| `CDC-17` | Warning | 1 | MUX-hold 控制的跨域结构，按实例保留基线 |

WAW 事件不是裸露的 33-bit 总线跨域：四个槽分别进入 `33 bit × 16` XPM 异步 FIFO，写端为 EH2 50 MHz，读端为控制/日志 100 MHz。最终报告能够看到四个 XPM FIFO 内部的 `CDC-15` 数据/Gray 结构和 reset synchronizer；目的域只在 FIFO 非空时读取 `{hart, package, sequence}`，因此四个槽不会因同拍发生而互相覆盖。

必须单独检查系统自建数据跨域。RX FIFO overflow 的数据事件在最终报告中被识别为 `CDC-3 Info`：源域 toggle 到目的域三级 `ASYNC_REG` 链，第一阶段有定向 false path；前仿另用异步相位和窄脉冲做了针对性验证。该结构的 `CDC-10` 条目只指向其异步置位、同步释放的 reset pipe，不是 overflow 数据脉冲直跨。结果/日志宽总线使用“源端保持数据、toggle/ack 同步、目的端在同步事件后采样”的闭环握手；程序数据使用 AXI Clock Converter/异步 FIFO。

以后修改 RTL 时，必须对 `CDC-1/6/7/10/17` 做实例级 diff。任何新出现且不是已审查 reset/XPM/TEMAC/MIG/EH2 网表内部结构的条目，尤其是裸多位总线、组合逻辑后接同步器或单周期错误脉冲，都视为阻断问题。

最终 `report_methodology` 仍有 2893 项方法学提示：`DPIR-2=131`、`HPDR-2=2520`、`LUTAR-1=13`、`TIMING-9=1`、`TIMING-18=18`、`TIMING-24=174`、`TIMING-47=16`、`XDCC-1/4/7/8=6/3/5/3`，以及 Advisory `CLKC-56=1`、`RTGT-1=2`。其中 `DPIR/HPDR` 主要来自保持不改的 EH2 EDIF/DSP 层次，`XDCC` 是 MIG/TEMAC scoped XDC 重复导入同名同源时钟，`TIMING-47` 主要是 TEMAC IP 对同源 DDR 边沿和 RGMII RX 时钟的例外，`RTGT` 是 TEMAC 地址过滤 RAM 优化建议。`LUTAR-1` 包含程序 DMA 计数、owner/start 同步链、全局 POR、MIG PLL 和 MAC reset 等由组合条件驱动异步清零的结构；它们在本版中按实例记录为保留风险，不能在没有重跑相关前仿、综合和实现的情况下仅为消除告警而改写复位语义。

`TIMING-24=174` 尤其容易遗漏：宽范围 `set_clock_groups -asynchronous` 会覆盖 IP/XPM 原先的 `set_max_delay -datapath_only`。当前版的 113 个 bus-skew corner/constraint 全部通过，最小 slack 为 `+2.508 ns`，WAW 使用 XPM FIFO，RX overflow/FCS 使用事件 CDC，同步结构和最终物理路由均已审查，因此本次不在 routed DCP 后临时改约束并重生成一个未经完整实现验证的 bitstream。以后只要修改时钟/CDC/XDC，就应把宽范围异步组收窄为 CDC 端点级例外，保留各 IP/XPM 的 datapath-only/bus-skew 约束，然后重新 route、重新生成 CDC/methodology/bus-skew/timing 报告和 bitstream。

最终 `check_timing` 为：`no_clock=0`、`constant_clock=0`、`pulse_width_clock=0`、`unconstrained_internal_endpoints=0`、`multiple_clock=0`、`generated_clocks=0`、`loops=0`、`partial_input_delay=0`、`partial_output_delay=0`、`latch_loops=0`。保留的 I/O 提示只有 `no_input_delay=2`（两只异步开关）和 `no_output_delay=13`（两路 DDR reset、8 个 LED、PHY reset、false-path 的 MDC、作为转发时钟的 RGMII TXC）；高速 RGMII TXD/TX_CTL 不在 `check_timing` 的无/部分输出约束列表中。

## 14. 已验证内容与运行限制

完整前仿已经验证 PRECONFIG→READY→PROGRAM_WRITE→EXECUTE→END 的闭环状态序列；200,000 条静态指令被补零后拆成 782 个真实 1024-byte 程序帧，从顶层 RGMII/MAC RX 经 DataMover 写入 DDR0，再由双 hart 执行。四个日志帧的 count 和六项归约值与 Spike 黄金结果逐字段一致；END 后的 64-cycle 全局复位及返回 PRECONFIG 由定向平台另行验证。

运行限制如下：

- 程序帧只能是固定 1028-byte payload（4-byte 大端序编号 + 1024-byte DDR 数据），系统信息帧只能是固定 46-byte payload；
- 不支持 VLAN 标记、IP/UDP 封装或短程序帧；
- 程序帧已有 32-bit 连续编号，结束帧已有 32-bit 总包数；当前没有整幅 image CRC、逐帧 ACK 或重传；
- 指令 DDR 只覆盖本次实际收到的连续 image，不在 READY 清零整个指令 DDR；
- 数据 DDR 每轮清零完整低 4 GiB，所需时间取决于 MIG UI 实际吞吐；
- 程序写入从首次 AXI 写开始计时 20 s；EXECUTE 没有超时；
- 每个 hart、每个 package 最多 483 个 WAW 取消序号；
- 系统信息为二层广播且没有 ACK/重发机制；
- 链路丢失和初始化失败按致命错误处理，不做自动重新协商恢复；
- 当前假定板载时钟发生器已在 FPGA 配置前提供正确频率；
- MIG、TEMAC 和 PHY 配置沿用已上板验证工程，不改变其电气参数；
- 最终 bitstream 为未压缩格式；FPGA 内部功能与压缩格式相同，但主机/配置 Flash 的传输时间和占用空间更大；
- 功耗报告没有真实 SAIF/VCD 活动率，confidence 为 `Low`；板级电源和散热必须以实测为准；
- 四个来源工程分别已上板验证，本次整机已完成闭环前仿和实现签核，但本次会话没有在板上对新整机 bitstream 做最终回归。

更完整的系统算法、模块列表、双 hart 启动问题及前仿证据分别见同目录的 `README.md` 和 `veri_readme.md`。

## 15. 综合、实现与时序分析中最容易忽略的问题

### 15.1 综合阶段

1. 不能只看 Vivado 最终显示的 Error 数。必须检查综合黑盒报告：允许的 `dbg_hub` 延迟占位应在 `opt_design` 后消失，EH2、MIG、TEMAC、DataMover、两个系统信息 FIFO、hash/WAW/log 路径和六状态控制器不能成为黑盒。
2. 必须检查分层利用率而非只看顶层总资源。某个大模块因文件集、宏或网表路径错误被优化掉时，综合仍可能“成功”；EH2 网表、两套 MIG、TEMAC 和日志系统都应在层次报告中出现并有合理资源量。
3. 不要随意修改 EH2 网表周围的 `DONT_TOUCH`、URAM BWE、DSP reset 或 cache/DCCM/ICCM 结构来消除建议类告警。这些修改可能改变双 hart、ECC 或归约结果，必须重新做完整 Spike/前仿验证。
4. 检查复位极性和复位范围。当前错误/正常结束都必须经过独立监督器的 64-cycle 全局复位并返回 PRECONFIG；READY 只有一个周期的程序会话记账清除。若误把 `program_session_clear` 当作模块 reset，或让全局复位请求绕过 TX 完成/上位机停止握手，可能截断错误/结束帧并把旧会话数据带入下一轮。

### 15.2 时钟与 CDC 约束

1. `core_clk`、`atg_clk`、两个 MIG 参考/UI 时钟和 `rgmii_rxc` 来自不同物理源。异步关系必须按真实 CDC 边界声明，不能让 Vivado错误地把无相位关系的时钟当作同步时钟分析。
2. `atg_clk ↔ rgmii_rxc` 的异步组只能切内部 RX FIFO/同步器边界，不能切 RGMII 引脚到 IDDR/IODELAY 的源同步输入路径。RGMII 输入仍必须相对 IP 的 RX virtual clock 保留当前 `-0.250/-1.250 ns` 板级约束。
3. `set_false_path` 只能到第一拍亚稳态捕获寄存器的 D 端。若把整个同步链或业务逻辑切掉，后级同步器之间将失去时序检查。
4. 多位结果、计数和 hash 不能仅给每一位加两级同步器。必须使用异步 FIFO，或使用源端保持数据且有 request/ack 的闭环握手；报告中的 `CDC-6/CDC-15` 必须结合结构审查。
5. 错误脉冲可能短于目的时钟周期。overflow 等致命事件必须在源域转 toggle 或锁存电平，再同步到控制域；仅对脉冲直接打两拍可能永久漏报。
6. 方法学 `TIMING-6/7` 经常意味着遗漏异步时钟关系。本系统补全前正是 `atg_clk` 与 `rgmii_rxc`；补全后必须在 `clock_interaction.rpt` 中看到双向 `Ignored / Asynchronous Groups`，并确认没有误切外部 RGMII I/O 路径。
7. 不能只看到 `Asynchronous Groups` 就认为 CDC 约束完整。当前 `TIMING-24=174` 明确说明宽范围异步组覆盖了部分 IP/XPM 的 `set_max_delay -datapath_only`；bus-skew 当前通过不代表未来修改仍自动安全。修改任何时钟分组时必须同时对比 `report_methodology`、`report_cdc`、`report_bus_skew` 和 `clock_interaction`。
8. `LUTAR-1` 是组合逻辑驱动异步复位的潜在毛刺提示。若以后改动程序 DMA 计数复位、DDR owner、session reset、POR 或 MAC/MIG reset，必须先把复位改为源域同步产生、目的域异步置位同步释放的明确结构，再重跑受影响前仿和完整实现；不能只把告警降级。

### 15.3 RGMII、DDR 与 I/O 时序

1. 不能只确认 XDC 中写了 `set_output_delay`。必须对 `rgmii_txd[*]` 和 `rgmii_tx_ctl` 做端口定向的 max/min `report_timing`，在路径中确认实际 clock 是 `inst_rgmii_tx_clk`、实际 `Output Delay` 是 `-1.000/-3.000 ns`，且 rise/fall 均有正裕量。
2. `rgmii_txc` 是转发时钟端口，本身出现在 `no_output_delay` 提示中是正常的；TXD/TX_CTL 不得出现在 `check_timing no_output_delay/partial_output_delay` 中。不要因为方法学对重复 IP clock 对象给出 `TIMING-18` 就盲目再叠加一套 delay。
3. DP83867 必须保持 RGMII_ID 配置与 XDC 一致：当前 PHY TX delay 约 2.00 ns、RX delay约 1.25 ns，FPGA TXC 为 edge-aligned。只改 MDIO delay 或只改 XDC 会破坏板级 setup/hold。
4. 两套 MIG 的 P/N 引脚、参考时钟频率、器件型号、数据宽度和校准 ELF 必须配套。bitgen 日志必须出现两个 calibration ELF 成功写入；否则即使逻辑实现通过，DDR 也可能无法校准。
5. `check_timing` 中 sw、LED、MDIO、PHY reset 等低速异步/管理端口可出现无 I/O delay，但 `no_clock`、`unconstrained_internal_endpoints`、`partial_input_delay`、`partial_output_delay` 必须为 0。新增高速接口不能沿用低速端口的豁免解释。

### 15.4 实现与签核

1. 不能只看 setup WNS。交付门限同时要求 WNS/TNS、WHS/THS、WPWS/TPWS、bus skew、route status、DRC 和 unconstrained endpoints 全部合格。
2. 必须在最终 routed DCP 上重新检查黑盒和路由错误。综合阶段允许的 debug placeholder 不能留到 post-route；本次 post-route blackbox 和 routing error 均为 0。
3. 跨 SLR 的 LED 告警与跨 SLR 的高速总线性质不同。固定 LED 引脚可接受；若程序 DMA、MIG 数据、hash 宽总线出现新的 SLR crossing/fanout 告警，应检查拥塞、延迟和复制寄存器，不能套用 LED 的解释。
4. 功耗报告在没有真实活动文件时只能用于数量级参考。`Low` confidence 下不能据此确认电源余量、结温或散热器规格。
5. 修改纯时序例外且不改变布局布线时，可从 routed DCP 重做受影响报告并保存约束版 DCP；若新增/收紧约束后出现负裕量，则必须重新布局布线并重新生成 bitstream。只有 RTL、IP 参数、网表或综合属性变化时才需要重新综合。

### 15.5 位流生成与主机资源

本次 2026-08-06 实现流程在布局/路由可用阶段提高并行度，最终实现峰值约 `23.8 GiB`；位流阶段限制为 2 线程并设置 `BITSTREAM.GENERAL.COMPRESS=FALSE`，成功生成 199112135-byte bitstream。此流程在当前主机完成，但高峰已接近需要谨慎管理的内存范围。以后不得同时运行另一套 Vivado 实现、完整仿真、VMware 或大报告；完整 routed-DCP 报告导出也限制为 2 线程。若可用内存下降，应先降低到 4 核或 2 核，避免内存/提交限制崩溃的优先级高于速度。

## 16. 最终交付文件

`output/board` 中应优先使用以下文件：

| 文件 | 用途 |
| --- | --- |
| `eh2_veri_system_latest.bit` | 2026-08-06 最终未压缩 bitstream；无后缀兼容名也同步到同一内容 |
| `eh2_veri_system_routed_latest.dcp` | 与该 bitstream 同源的最新 fully-routed checkpoint；兼容名同步到同一内容 |
| `checkpoints/latest_post_opt.dcp` | opt_design 后恢复点，黑盒 0 |
| `checkpoints/latest_post_place.dcp` | place_design 后恢复点 |
| `checkpoints/latest_post_physopt.dcp` | phys_opt 后、最终 route 前恢复点 |
| `reports_latest/timing_summary.rpt` | 最终 setup/hold/pulse-width 签核 |
| `reports_latest/bus_skew.rpt` | 最终总线偏斜签核 |
| `reports_latest/route_status.rpt` | 0 未布线/0 route error 证据 |
| `reports_latest/drc.rpt` | 最终 DRC 分类 |
| `reports_latest/cdc.rpt`、`methodology.rpt`、`clock_interaction.rpt`、`check_timing.rpt` | 从最新 routed DCP 生成的 CDC/约束审查 |
| `stress_200k_dualhart_system.bin` | 782帧前仿和上板使用的800640-byte程序BIN |
| `SHA256SUMS.txt` | 最终文件完整性校验 |

全部说明文件集中在 `output/doc`。其中 `README.md` 说明系统与算法，`veri_readme.md` 说明全部前仿，`webui_readme.md` 说明上位机，本文说明板级接口和签核，`build_issue_readme.md` 逐项记录实际错误、原因、修复和防复发门禁。
