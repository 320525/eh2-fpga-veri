# EH2 双 Hart 以太网加载、执行与日志归约系统

## 1. 系统目标

本工程将四个已上板验证的 Vivado 工程组合为一套完整系统：

- 从以太网接收程序帧，通过 AXI DataMover 写入指令 DDR；
- 使用独立数据 DDR 为 EH2 的 LSU 提供存储空间；
- FPGA 上电后自动完成 MAC、PHY、MIG 和 DDR 通路自检；
- 在 `READY` 阶段用 512 bit MIG UI 原生 AXI 主机清零数据 DDR 的低 4 GiB；
- 在 `EXECUTE` 阶段运行 EH2 的两个 hart；
- 对两个 hart 的提交指令分别执行 CRC-64 和归约；
- 发送 package number、归约值和该 package 内全部 WAW 取消序号；
- 使用独立的系统信息收发 FIFO 上报状态和错误；
- 任一受监测的致命错误发生后发送第一条错误码；上位机立即停止程序发送并回送停止确认，随后 FPGA 对全系统执行 64 个控制时钟的全局复位并从 `PRECONFIG` 重启。

EH2 当前复位向量的字节地址为 `0x8000_0000`。程序 DataMover 的首帧也从指令 DDR 地址 `0x8000_0000` 开始写入，每个合法程序帧使目标地址增加 `0x400`。

## 2. 已复用工程与边界

| 来源工程 | 复用内容 | 本工程中的集成方式 |
| --- | --- | --- |
| `log_eh2_crc_fpga` | EH2 网表、提交指令采集、CRC/归约思路、125 MHz 时钟生成方式 | 综合/实现使用 `netlist/eh2_veer_wrapper.edf`；行为级仿真使用相同配置的 EH2 RTL；归约路径位于 `rtl/crc` |
| `eh2_veri_iss_proj` | EH2 指令/数据外部 AXI 存储结构和处理器初始化流程 | 指令 DDR、数据 DDR、AXI 宽度转换及 DCCM/ICCM 初始化路径 |
| `eth_tx` | TEMAC 发送 FIFO、MAC AXI4-Lite 初始化、RGMII 发送方法 | 复用 TEMAC FIFO 结构；MAC 配置由 ATG 完成；日志帧和系统信息帧共用同一个 TX MAC |
| `mac_fifo_dma_proj` | 以太网 RX FIFO 到 AXI DataMover S2MM 的程序烧写方式 | 每帧固定搬运 1024 byte，写地址从 `0x8000_0000` 连续递增 |

系统只实例化一套全双工 TEMAC 和一颗 DP83867 PHY。接收和发送使用同一物理 MAC/PHY 配置，不存在两套互相不一致的 PHY 初始化。RX 和 TX 客户端各有自己的 FIFO，但都接在同一 TEMAC 上。

## 3. 总体结构

```mermaid
flowchart LR
    PC["上位机"] <-->|"RGMII / Ethernet"| MAC["TEMAC + DP83867"]
    MAC --> RX["RX 流式目的 MAC 分类"]
    RX -->|"02:12:34:56:78:FF<br/>1042 byte"| PDMA["程序 DataMover"]
    RX -->|"02:32:05:25:00:FF<br/>60 byte"| IRX["系统信息 RX FIFO"]
    PDMA --> M0["指令 DDR / MIG0"]
    IRX --> CTRL["六状态控制器"]
    CTRL --> ITX["系统信息 TX FIFO"]
    ITX --> ARB["逐帧锁定 TX 仲裁"]
    EH2["EH2 双 hart"] -->|"IFU"| M0
    EH2 -->|"LSU"| M1["数据 DDR / MIG1"]
    EH2 --> HASH["双 hart CRC 与归约"]
    HASH --> LOG["日志帧组包器"]
    LOG --> ARB
    ARB --> MAC
    CTRL --> ATG["数据 DDR ATG / 检查 / 清零主机"]
    ATG --> M1
```

RX 分类器先缓存目的 MAC 的前三个 16 bit word，判别目的地址后以单遍流式方式转发：程序帧的完整 Ethernet frame 进入程序 DataMover，系统帧只把 46-byte payload 写入系统信息 RX FIFO，其余目的地址直接排空并丢弃。分类器在 TLAST 处核对精确帧长，因此两类帧互不污染，同时不会因“整帧缓存后再整帧重放”降低 MAC RX FIFO 的持续排空速率。

早期整帧缓存/重放实现曾在连续程序帧压力下触发 RX FIFO overflow。MAC FIFO 写侧是 8 bit @ 125 MHz（125 MB/s），集成系统读侧是 16 bit @ 100 MHz（200 MB/s），裸带宽本来足够；但旧分类器会先采集整帧、再在停读 MAC FIFO 时重放，使平均服务时间接近线速到达时间的两倍。流式分类修正后只暂存目的 MAC 的 3 个 word；当前 1042-byte 程序帧为 521 个 16-bit word，持续接收时分类器同时排空 RX FIFO，不再形成逐帧积压。

TX 仲裁器在帧首选择来源并锁定到 `TLAST`，不会在一个以太网帧中交叉系统信息和日志数据：

- `PRECONFIG`、`READY`、`PROGRAM_WRITE`、`END` 和 `ERROR`：系统信息 FIFO 使用 MAC；
- `EXECUTE`：日志 FIFO 优先且正常流程中只有日志帧使用 MAC；
- 如果 `EXECUTE` 中出现错误，已开始的日志帧先完整结束，再发送错误信息帧。

## 4. 时钟与复位

| 时钟域 | 频率 | 使用模块 |
| --- | ---: | --- |
| `core_clk` | 50 MHz | EH2、EH2 硬件初始化、提交指令采集、数据 DDR 自检 ATG |
| `ctrl_clk` / 板上 `atg_clk` | 100 MHz | 六状态控制器、程序 DataMover、RX 分类器、系统信息 RX/TX FIFO、系统信息组帧、TX 仲裁、MAC AXI4-Lite 和 PHY MDIO 初始化 |
| `clk125` | 125 MHz | TEMAC GTX 时钟、CRC FIFO 读出与归约、日志结果输出 |
| `refclk` | 约 333.333 MHz | TEMAC 参考时钟 |
| `c0_ui_clk` | 由 MIG0 生成 | 指令 DDR 的 512 bit AXI UI |
| `c1_ui_clk` | 由 MIG1 生成 | 数据 DDR 的 512 bit AXI UI |
| `rgmii_rxc` | 链路提供，千兆时约 125 MHz | TEMAC RGMII 接收；随后由 MAC RX FIFO 跨到 `ctrl_clk` |

状态控制器与两个系统信息 FIFO 都使用 `ctrl_clk=100 MHz`。这样系统状态码、程序结束标记和 MAC 客户端 FIFO 位于同一时钟域，不需要在系统信息路径中再增加异步 FIFO。

硬复位由两个板级开关、上电释放管线和独立的 `system_global_reset_supervisor` 共同控制。正常 END 的 `EXE_END` 物理发送完成后，或 ERROR 的错误帧发送完成且上位机回送 `HOST_SEND_STOPPED` 后，监督器把覆盖 TEMAC、DP83867/MDIO、双 MIG、全部 FIFO、程序 DMA、控制器、EH2、CRC/WAW 和日志路径的全局复位连续拉低 64 个 `ctrl_clk` 周期，然后从 PRECONFIG 重新初始化。

READY 清零完成后的 `program_session_clear` 只持续一个控制时钟，用于把 PRECONFIG 留下的帧序号、包数、DMA 完成数和程序首地址恢复到正式写入初值；它不是模块软复位，不复位任何时钟域或 MAC/MIG/EH2/日志硬件。

PHY RX 使用确定性初始化和放行。MDIO 将 DP83867 配置为 RGMII_ID，TX 内部 delay code 为 7（约 2.00 ns），RX code 为 4（约 1.25 ns），并对两个寄存器回读核对；自动协商完成后要求链路连续稳定 100 ms。FPGA 侧保留 1100 ps RX IODELAY，XDC 对 RX 建模为 `-0.250/-1.250 ns` 输入延时。上述条件成立后，接收路径还等待 1 ms IDELAY guard，并在 `rgmii_rxc` 域观察 4096 个连续稳定边沿才释放客户端 FIFO。TEMAC 统计中的 FCS 错误通过专用 CDC 计数器送到控制域并上报 `0x66660075`，因此物理采样错误导致的坏帧不再只表现为静默丢包或程序超时。

在 EH2 停止后，控制器还会等待 IFU/LSU 的所有已接受 AXI 事务返回，并要求空闲状态连续保持 16 个 `ctrl_clk` 周期，然后才允许进入 `END`、复位 EH2 或在下一轮把 DDR 所有权交给清零主机。

## 5. 地址、MAC 和 EtherType

| 项目 | 值 |
| --- | --- |
| EH2 复位向量 | `0x8000_0000` |
| EH2 `rst_vec[31:1]` 端口值 | `31'h4000_0000` |
| 程序 DataMover 首地址 | `0x8000_0000` |
| 程序帧地址步长 | `0x0000_0400` |
| 程序路径目的 MAC | `02:12:34:56:78:FF` |
| 系统信息路径 MAC | `02:32:05:25:00:FF` |
| 系统信息/日志发送目的 MAC | `FF:FF:FF:FF:FF:FF` |
| 系统信息与日志 EtherType | `0x88B5` |
| 程序帧建议 EtherType | `0x88B6` |
| 执行结束 MMIO 地址 | `0xD058_0000` |
| 执行结束 MMIO 数据 | `0x0032_0525` |

`0x88B5` 和 `0x88B6` 用作本地实验协议，避免被 PC 的 IPv4/ARP 协议栈误处理。RTL 的 RX 隔离以目的 MAC 和精确长度为主要判据；程序控制器还会再次检查程序目的 MAC。

## 6. 六状态控制器

```mermaid
stateDiagram-v2
    [*] --> PRECONFIG
    PRECONFIG --> READY: MAC/PHY/MIG 正常且双 DDR 1024 byte 自检通过
    PRECONFIG --> ERROR: 初始化、ATG 或 DDR 比较失败
    READY --> PROGRAM_WRITE: 数据 DDR 低 4 GiB 清零、程序记账清除、READY 帧发送完成
PROGRAM_WRITE --> EXECUTE: 收到结束标记、结束帧前一程序帧的 DMA 成功完成、DMA 空闲、PROGRAM_DONE 发送完成
    PROGRAM_WRITE --> ERROR: 首次写入后 20 s 未结束或程序通路错误
    EXECUTE --> END: 两个 hart 停止、全部日志帧发送、AXI 完全排空
    EXECUTE --> ERROR: EH2、hash、FIFO、AXI 或 MAC 错误
    END --> PRECONFIG: EH2_DONE/EXE_END 物理发送完成后全局复位
    ERROR --> PRECONFIG: 错误帧完成且收到 HOST_SEND_STOPPED 后全局复位
```

### 6.1 `PRECONFIG`

1. EH2 始终保持复位。
2. 等待下列条件全部满足：
   - 50 MHz 到 125 MHz 的 MMCM 锁定；
   - TEMAC AXI4-Lite ATG 配置完成且无响应错误；
   - DP83867 扫描、ID 校验、RGMII delay 配置与回读、自动协商完成；
   - PHY 链路连续稳定 100 ms，1 ms IDELAY guard 和 4096 个 RX clock 稳定边沿检查完成；
   - MIG0、MIG1 校准完成。
3. 通过系统信息 FIFO 发送 `PREINIT_DONE = 0x11111111`。
4. 上位机收到该帧后，按正常程序路径向指令 DDR 发送一帧 1024 byte 的 `0xFF`。该程序 DMA 的 AXI 起始地址为 `0x80000000`；前仿紧凑 DDR 模型把它折叠到内部存储数组第 0 行，但总线地址不是 `0x00000000`。
5. 首帧开始写 DDR 时发送 `PROGRAM_WRITE_START = 0x44004444`；收到结束帧时发送 `RECEIVE_DONE = 0x44114444`。PRECONFIG 与正式 PROGRAM_WRITE 使用相同的可观测信号。
6. 同时，50 MHz 数据 ATG 向数据 DDR 写入 1024 byte 的 `0xFF`。
7. 收到系统结束标记、确认结束帧声明总数为 1、已接收连续帧数为 1、该程序帧 DMA 成功完成、程序 DMA 空闲且数据 ATG 完成后，独占两个 DDR：
   - 指令 DDR 读取比较 1024 byte；
   - 数据 DDR 读取比较 1024 byte。
8. 两路均正确时发送 `CHECK_PASS = 0x22222222` 并进入 `READY`。
9. 数据或指令 DDR 失败时分别发送 `DATA_FAIL`、`INSTR_FAIL`；完成错误发送/上位机停止握手后执行全局复位并回到 PRECONFIG。

该状态中 DDR0 只允许程序 DataMover/指令检查器访问，DDR1 只允许数据 ATG/数据检查器访问，EH2 没有总线所有权。

### 6.2 `READY`

1. EH2 保持复位。
2. DDR1 所有权只交给 `ddr_fill_master`。
3. 使用 MIG 原有 512 bit AXI UI，以 256 beat、16 KiB 的 INCR burst 清零数据 DDR 的低 4 GiB；不修改 MIG 配置。
4. 清零完成后发出一个 `ctrl_clk` 周期的 `program_session_clear`，只恢复程序帧序号、包数、DMA 完成数和程序首地址，不复位其他模块。
5. 发送 `READY = 0x33333333`。
6. 该帧物理发送完成后进入 `PROGRAM_WRITE`。

硬件参数 `DATA_CLEAR_BYTES` 默认为 `0x1_0000_0000`。完整前仿为缩短时间把该参数改成 1 MiB，但仍使用同一个 512 bit 清零主机和同一条 AXI 路径。

### 6.3 `PROGRAM_WRITE`

1. EH2 保持复位。
2. DDR0 所有权只交给程序 DataMover；DDR1 空闲。
3. 若没有程序帧到达，状态一直等待。
4. 第一次程序 AXI 写地址握手后启动 20 s 计时器：
   - `ctrl_clk=100 MHz`；
   - 超时阈值为 `2,000,000,000` 个周期。
5. 每个合法程序帧固定含 4 byte 连续序号和 1024 byte 程序数据，程序数据依次写入：
   - 第 0 帧：`0x8000_0000`；
   - 第 1 帧：`0x8000_0400`；
   - 依此递增。
6. 上位机发送完最后一帧程序帧后立即发送系统信息结束帧；上位机不知道也不等待 FPGA 内部的 DMA done。
7. 第一帧开始 AXI 写入时发送 `PROGRAM_WRITE_START = 0x44004444`；收到结束帧时立即发送 `RECEIVE_DONE = 0x44114444`，此时不要求最后一帧 DMA 已完成。
8. RTL 在收到结束帧时锁存其声明总数和内部连续接收数，并等待成功 DMA 完成累计数追上该总数；这明确关联了“结束帧前一程序帧”和它自己的 DMA 完成。仅当“声明总数=连续接收数=DMA完成数”且 DataMover 空闲时，才发送 `PROGRAM_DONE = 0x44444444`。只有结束帧，或只有更早程序帧的 DMA 完成，都不能离开本状态。
9. `PROGRAM_DONE` 整帧发送完成后进入 `EXECUTE`。
10. 超时或序号/总数/DMA/FIFO/帧长/FCS错误发送对应错误码。上位机立即停止发送并回送 `HOST_SEND_STOPPED`，FPGA 完成握手后全局复位。

### 6.4 `EXECUTE`

1. DDR0、DDR1 的所有权都切换到 EH2，保持 16 个 `ctrl_clk` 周期保护时间。
2. EH2 调试复位先释放，hart0 保持 debug halt。
3. `eh2_hw_init` 通过 EH2 DMA slave：
   - 清零 64 KiB DCCM；
   - 清零 64 KiB ICCM；
   - 由 EH2 正常存储路径生成 SECDED ECC；
   - 初始化完成后向 hart0 发出 debug run。
4. hart0 从 `0x8000_0000` 开始执行。
5. 程序开头只有 hart0 执行：

   ```asm
   csrr s0, mhartid
   bnez s0, hart_start_done
   li   t6, 2
   csrw 0x7FC, t6
   hart_start_done:
   ```

6. `CSR 0x7FC[1]=1` 解除 EH2 内部的 hart1 启动门控，hart1 从同一复位向量开始执行。
7. 每个 hart 在结束时向 `0xD0580000` 写 `0x00320525`。日志路径据此停止接收该 hart 的后续提交，并封闭最后一个 package。
8. `EXECUTE` 期间 TX 以日志帧为主，系统状态 FIFO不参与正常发送。
9. 同时满足以下条件才进入 `END`：
   - `stopped == 2'b11`；
   - 两个 hart 的全部 package 归约结果已经发送；
   - IFU/LSU 所有已接受的 AXI 读写事务已经返回；
   - AXI 空闲连续保持 16 个 `ctrl_clk` 周期。

`EXECUTE` 没有运行时间超时，程序可按需要长时间运行。

### 6.5 `END`

1. DDR 所有权仍保留给 EH2，不在状态边界中截断事务。
2. 依次发送：
   - `EH2_DONE = 0x55555555`；
   - `EXE_END = 0x77777777`。
3. 两帧均由物理 MAC 完成计数确认发送后，请求全局复位。
4. 全局复位连续保持 64 个 `ctrl_clk` 周期，释放后从 `PRECONFIG` 重新完成 MAC/PHY/MIG 初始化和双 DDR 通路检查。

### 6.6 `ERROR`

1. 第一条错误优先锁存，后续错误不覆盖它。
2. 若 MAC 正在发送日志帧，先让该帧完整结束。
3. 通过系统信息 FIFO 发送一次对应错误码。
4. 错误帧发送期间 EH2 保持复位、DDR 所有者置空，`LED0` 点亮。
5. 上位机收到错误码后立即终止正在进行的程序发送，并向系统 MAC 回送 `HOST_SEND_STOPPED = 0x44124445`。
6. 错误帧物理发送完成和停止确认均成立后，FPGA 请求覆盖 MAC、PHY、MIG、FIFO 和所有业务模块的 64-cycle 全局复位；释放后回到 PRECONFIG。错误码只发送一次。

## 7. 以太网帧格式

以下长度均不包括线上的 7 byte preamble、1 byte SFD 和 4 byte FCS。TEMAC 负责线侧前导码/SFD/FCS。

### 7.1 程序接收帧

总长度固定为 `14 + 1028 = 1042 byte`。

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC：`02:12:34:56:78:FF` |
| 6 | 6 | 上位机源 MAC；测试程序使用 `02:32:05:25:00:FE` |
| 12 | 2 | 建议 EtherType：`0x88B6` |
| 14 | 4 | `frame_sequence`，32 bit 大端序，首帧为 0，之后严格加 1 |
| 18 | 1024 | 程序数据；只有这 1024 byte 写入 DDR |

最后一帧程序数据不足 1024 byte 时由上位机在数据区尾部补零；不能发送短帧。RX 分类器要求帧长精确为 1042 byte，程序控制器剥离 4-byte 序号，检查序号从 0 连续递增，并只把后续 512 个 16-bit word交给 DataMover。序号缺失、重复、回退或跳号均上报 `ERR_PROGRAM_SEQUENCE`。

当前双 hart 压力程序包含 200,000 条实际静态指令，二进制大小为 800,640 byte；补零到 800,768 byte 后拆成 782 个连续程序帧。每帧的以太网 payload 是“4-byte 序号 + 1024-byte 程序数据”。完整前仿把这 782 帧从测试平台顶层作为真实 RGMII 数据送入 TEMAC RX，经过 RX FIFO、流式分类器、序号检查、DataMover 和 AXI 转换后写入指令 DDR，并逐字节回读核对全部 800,768 byte；不是用 `$readmemh` 直接预装指令 DDR，也不是用小程序循环制造约 20 万条动态提交。

### 7.2 系统信息接收帧

总长度固定为 `14 + 46 = 60 byte`。

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC：`02:32:05:25:00:FF` |
| 6 | 6 | 上位机源 MAC |
| 12 | 2 | 建议 EtherType：`0x88B5` |
| 14 | 4 | 命令字段；结束帧固定为 `FF FF FF FF` |
| 18 | 4 | 结束帧声明的程序帧总数，32 bit 大端序 |
| 22 | 38 | 保留，必须填 0 |

只保留目的 MAC 正确且总长度恰好为 60 byte 的帧。46 byte payload 被送入专用 RX FIFO；当 payload 前 4 byte 为 `FF FF FF FF` 时，产生一次程序写入结束脉冲并锁存其声明的总包数。结束标记帧不会进入程序 DataMover。内部只有在声明总数、连续接收数、成功 DMA 完成数三者一致且 DataMover idle 时才判定写入完成。

### 7.3 系统信息发送帧

总长度固定为 60 byte。

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC：`FF:FF:FF:FF:FF:FF` |
| 6 | 6 | 源 MAC：`02:32:05:25:00:FF` |
| 12 | 2 | EtherType：`0x88B5` |
| 14 | 4 | 32 bit 状态/错误码，大端序 |
| 18 | 2 | 固定为 `03 20`，即字段值 `0x0320` |
| 20 | 40 | 全 0 |

系统信息发送 FIFO 深度为 16 个 32 bit code。格式化器每取出一个 code 就生成一帧，控制器只有在确认该 code 的整帧已经发完后才推进关键状态。

### 7.4 日志归约发送帧

每个 hart 的每个 package 发送一帧，总长度固定为 `14 + 1024 = 1038 byte`。

以太网头：

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC：广播 |
| 6 | 6 | 源 MAC：`02:12:34:56:78:FF` |
| 12 | 2 | EtherType：`0x88B5` |

1024 byte payload：

| payload 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 2 | `package_number`，大端序 |
| 2 | 1 | bit0=`hart_id`，其余位 0 |
| 3 | 1 | 保留，0 |
| 4 | 4 | 本 package 的有效归约条目数，大端序 |
| 8 | 8 | `xor0`，大端序 |
| 16 | 8 | `xor1`，大端序 |
| 24 | 8 | `sum0`，大端序 |
| 32 | 8 | `sum1`，大端序 |
| 40 | 8 | `sum2`，大端序 |
| 48 | 8 | `sum3`，大端序 |
| 56 | 2 | WAW 取消序号数量，9 bit 有效，大端序 |
| 58 | `2*N` | 依提交顺序排列的 WAW `sequence_number`，每项 16 bit 大端序 |
| `58+2*N` | 其余 | 全 0 |

固定字段共占 58 byte，因此 1024 byte payload 最多保存：

```text
(1024 - 58) / 2 = 483
```

个 WAW 序号。系统不会把一个 package 拆为多帧；同一 hart、同一 package 出现第 484 个 WAW 取消事件时进入 `ERROR`，分别上报 `ERR_WAW_HART0` 或 `ERR_WAW_HART1`。

## 8. 系统信息码

### 8.1 正常状态与自检

| Code | 符号 | 含义 |
| --- | --- | --- |
| `0x11111111` | `MSG_PREINIT_DONE` | MAC、PHY 和双 MIG 初始化完成，可以开始上电通路检查 |
| `0x22222222` | `MSG_CHECK_PASS` | 指令 DDR 与数据 DDR 的 1024 byte `0xFF` 检查均通过 |
| `0x22220011` | `MSG_DATA_FAIL` | 数据 DDR 自检失败，发送后进入 `ERROR` |
| `0x22220022` | `MSG_INSTR_FAIL` | 指令 DDR 自检失败，发送后进入 `ERROR` |
| `0x33333333` | `MSG_READY` | 数据 DDR 清零和程序会话记账清除完成，可以发送程序 |
| `0x44004444` | `MSG_PROGRAM_START` | PRECONFIG 或 PROGRAM_WRITE 的首帧程序数据已开始写 DDR |
| `0x44114444` | `MSG_RECEIVE_DONE` | 已收到上位机结束帧；此时仍可能在等待最后一帧 DMA 完成 |
| `0x44124445` | `MSG_HOST_SEND_STOPPED` | 上位机收到错误码后已停止发送；FPGA 可进入全局复位 |
| `0x44444444` | `MSG_PROGRAM_DONE` | 已收到程序结束标记、结束帧前一程序帧的 DMA 已成功完成，且 DataMover 当前空闲 |
| `0x55000000` | `MSG_HART0_START` | hart0 第一次实际提交指令；不是仅释放复位的预测信号 |
| `0x55010000` | `MSG_HART1_START` | hart1 第一次实际提交指令；证明 `mhartstart[1]` 已生效 |
| `0x550000FF` | `MSG_HART0_DONE` | hart0 已进入停止状态 |
| `0x550100FF` | `MSG_HART1_DONE` | hart1 已进入停止状态 |
| `0x55555555` | `MSG_EH2_DONE` | 两个 hart 均结束，全部日志帧已发送，EH2 AXI 已排空 |
| `0x77777777` | `MSG_EXE_END` | 本次执行会话正式结束；物理发送完成后全局复位并回到 PRECONFIG |

### 8.2 程序写入错误

| Code | 符号 | 含义 |
| --- | --- | --- |
| `0x44440011` | `ERR_PROGRAM_OVERTIME` | 第一次程序 DDR 写入后 20 s 内未收到结束标记 |
| `0x44440022` | `ERR_PROGRAM_WRITE` | 程序帧长度、DataMover 状态或写事务错误 |
| `0x44440033` | `ERR_PROGRAM_FIFO` | 预留的程序接收 FIFO 专用错误码；当前共用 MAC RX FIFO overflow 同时连到优先级更高的 `ERR_RX_FRAME_BUF` |
| `0x44440044` | `ERR_PROGRAM_DMA` | AXI DataMover 报错 |
| `0x44440055` | `ERR_PROGRAM_SEQUENCE` | 程序帧 32-bit 序号不是从 0 开始严格连续递增 |
| `0x44440066` | `ERR_PROGRAM_COUNT` | 结束帧声明总包数与连续接收帧数不一致，或 DMA 完成计数越过目标 |

### 8.3 运行与基础设施错误

| Code | 符号 | 含义 |
| --- | --- | --- |
| `0x66660011` | `ERR_NB_HART0` | hart0 nonblocking instruction buffer 冲突/溢出 |
| `0x66660012` | `ERR_NB_HART1` | hart1 nonblocking instruction buffer 冲突/溢出 |
| `0x66660013` | `ERR_NB_HART1` | hart0 nonblocking instruction buffer 未记录non block |
| `0x66660014` | `ERR_NB_HART1` | hart1 nonblocking instruction buffer 未记录non block |
| `0x66660021` | `ERR_HASH_HART0` | hart0 to-hash FIFO overflow |
| `0x66660022` | `ERR_HASH_HART1` | hart1 to-hash FIFO overflow |
| `0x66660033` | `ERR_TXMAC_FIFO` | TEMAC TX FIFO overflow |
| `0x66660044` | `ERR_TXMAC_STREAM` | TX AXI stream/日志待发送缓存异常 |
| `0x66660051` | `ERR_WAW_HART0` | hart0 某 package 的 WAW 数超过 483 |
| `0x66660052` | `ERR_WAW_HART1` | hart1 某 package 的 WAW 数超过 483 |
| `0x66660061` | `ERR_BANK_HART0` | hart0 package 奇偶 bank 未释放即被重用 |
| `0x66660062` | `ERR_BANK_HART1` | hart1 package 奇偶 bank 未释放即被重用 |
| `0x66660071` | `ERR_INFO_RX_FIFO` | 系统信息 RX FIFO overflow |
| `0x66660072` | `ERR_INFO_TX_FIFO` | 系统信息 TX FIFO overflow |
| `0x66660073` | `ERR_RX_FRAME_BUF` | 共用 MAC RX FIFO overflow，或分类器识别帧超过最大保护长度 |
| `0x66660074` | `ERR_RX_FRAME_LEN` | 目的 MAC 被识别但帧长不符合协议、系统 payload 长度错误或程序 payload 长度错误 |
| `0x66660075` | `ERR_MAC_RX_FCS` | TEMAC RX 统计发现 FCS 错误；坏帧已由 MAC 丢弃且错误不再静默 |
| `0x66660081` | `ERR_MAC_CONFIG` | TEMAC AXI4-Lite 初始化失败 |
| `0x66660082` | `ERR_PHY_INIT` | DP83867 扫描、ID 或 RGMII 配置失败 |
| `0x66660083` | `ERR_PHY_LINK` | PHY 自动协商/稳定链路失败或运行时链路丢失 |
| `0x66660091` | `ERR_MIG0` | 指令 DDR MIG 校准超时 |
| `0x66660092` | `ERR_MIG1` | 数据 DDR MIG 校准超时 |
| `0x666600A1` | `ERR_DDR_ZERO` | 数据 DDR 清零主机收到 AXI 错误响应 |
| `0x666600A2` | `ERR_DDR_CHECK` | DDR 检查主机发生 AXI 错误 |
| `0x666600B1` | `ERR_EH2_INIT` | DCCM/ICCM 初始化或 debug run 失败 |
| `0x666600B2` | `ERR_EH2_IFU_AXI` | EH2 IFU AXI 错误响应 |
| `0x666600B3` | `ERR_EH2_LSU_AXI` | EH2 LSU AXI 错误响应 |
| `0x666600F1` | `ERR_ILLEGAL_STATE` | 控制器进入未定义 phase/state |

错误监测器采用 first-error-wins。上表中的先后顺序也是同一周期多个错误同时出现时的优先级。任一错误码只发送一次；错误帧发送期间停在 ERROR，收到上位机停止确认后执行全局复位并从 PRECONFIG 重启。

本工程只实现本表列出的系统信息符号；Excel 中多出的信号未加入协议。

## 9. Hash 与归约算法

### 9.1 160 bit 指令结构

每条被归约的指令构造为：

```text
instruction_struct[159:0] = {
    package_number[15:0],
    sequence_number[15:0],
    pc[31:0],
    instruction[31:0],
    metadata[31:0],
    data[31:0]
}
```

其中：

```text
metadata = {
    15'b0,
    hart_id[0],
    privilege_mode[1:0],
    event_type[1:0],
    register_number[11:0]
}
```

`event_type`：

- `0`：无寄存器写事件；
- `1`：GPR 事件，`register_number` 为 `rd`；
- `2`：CSR 事件，`register_number` 为 CSR 地址。

事件选择优先级：

1. WAW victim：记录 GPR 号，`data=0`；
2. CSR write：记录 CSR 地址和写入数据；
3. 已完成的 GPR write：记录 `rd` 和实际写回数据；
4. nonblocking load/div 写回意图：同周期返回则直接使用返回值，否则把结构保存到对应 hart/rd 的 nonblocking buffer，等待结果后再计算 CRC；
5. 其他指令：event、register 和 data 均为 0。

WAW 取消的原指令序号不丢弃，而是另外写入 WAW sequence store，最终随同该 package 的归约值发送。

#### WAW 事件的四路产生、CDC 与存储

`instr_crc_hash_dual` 在 EH2 50 MHz 提交域产生四个并行槽。槽 0/1 分别对应两个 commit lane 上 `process_valid && rv_commit_waw_victim && rd!=0` 的直接 WAW victim；此时 package 和 sequence 就是该 commit lane 当前分配的编号。槽 2/3 对应 EH2 的两路 `rv_nb_waw_valid` pending-nonblocking victim，只有相应 hart/rd 的 nonblocking 表项仍有效且未 resolved 时才产生，package/sequence 从保存该旧指令的 160-bit 结构中取回。两路 nonblocking sideband 若在同周期重复指出完全相同的 hart/rd，只保留一份，避免同一取消事件重复上报。

`waw_event_cdc` 为四个槽各实例化一个 `33 bit × 16` 深度、FWFT 的 `xpm_fifo_async`：

- 写时钟为 EH2 `core_clk=50 MHz`，写数据为 `{hart[0], package[15:0], sequence[15:0]}`；
- 读时钟为日志/控制 `ctrl_clk=100 MHz`，只要某路 FIFO 非空就同时给出 `dst_valid` 和队首数据，并在该拍读走；
- 四路 FIFO 的目的，是在同一个 50 MHz 周期最多保留四个不同 WAW 事件；它不会把每个 package 的协议容量从 483 增加为四倍；
- 任一路在 `src_valid` 到达时已满，该事件不写入，并按事件的 hart 永久锁存 `src_overflow_hart`，随后由错误监测器上报 `ERR_WAW_HART0/1`。

`waw_sequence_store` 在 100 MHz 域按 `[hart][package bit0]` 组织成四个逻辑 bank。奇偶位只用于快速选择 bank，`bank_package` 仍保存完整 16-bit package number；如果同奇偶的新 package 在旧 bank 发完并清除前到达，就置 `bank_conflict_hart`，防止把不同 package 的序号混在一起。同周期多个槽属于同一 hart、同一完整 package 时，每个槽先统计它前面有多少个同组槽，以 `旧 count + prior_same_count` 写入连续地址；count 只增加该拍同组事件总数。因此即使四个事件同拍到达，存储顺序和数量也不会丢失。

每个 hart、每个完整 package 的存储上限仍为 483。目标索引达到 483，即第 484 条事件，立即锁存 overflow 并进入错误处理；协议不拆成第二个日志帧。日志组包器读取时还会比较完整 package number，按 `0..count-1` 依序发出 WAW 序号，整帧发送结束后才通过 `clear_bank` 释放该 bank。

### 9.2 Package 和序号

- 两个 hart 分别计数；
- 每个 hart 的 `sequence_number` 从 0 开始；
- 一个 package 最多包含 65536 个序号，即 `0x0000` 到 `0xFFFF`；
- `sequence_number==0xFFFF` 后序号回到 0，`package_number+1`；
- package 奇偶位选择双 bank，允许上一 package 归约/发送时继续采集下一 package；
- bank 在发送完成前不得被同一 hart 的后续同奇偶 package 重用，否则报 bank conflict。

### 9.3 CRC-64

采用非反射 CRC-64/ECMA-182：

```text
polynomial = 0x42F0E1EBA9EA3693
```

160 bit 消息按 bit159 到 bit0、MSB first 输入。

同一结构计算两个 CRC：

```text
c0 = CRC64(message, init=0x0000000000000000)
c1 = CRC64(message, init=0xFFFFFFFFFFFFFFFF)
```

对于固定 160 bit 长度，第二个 CRC 使用 CRC 仿射性质实现为：

```text
c1 = c0 XOR 0xC2D822EDD2DBFBB1
```

该实现保持与双 CRC 网络相同的数值，但只需要一套数据相关的 160 级组合 CRC 网络。

### 9.4 G 混合与归约

定义 64 bit 循环左移 `ROTL`，所有加法均模 `2^64`：

```text
K0 = 0x9E3779B97F4A7C15
K1 = 0xD1B54A32D192ED03

g0 = c0 + ROTL(c1, 17) + K0
g1 = c1 + ROTL(c0, 31) + K1
g2 = (c0 XOR ROTL(c1, 43)) + ROTL(c0, 11)
g3 = (c1 XOR ROTL(c0, 29)) + ROTL(c1, 7)
```

每个 hart、每个 package 的最终结果：

```text
xor0 = XOR(all g0)
xor1 = XOR(all g1)
sum0 = SUM(all g0) mod 2^64
sum1 = SUM(all g1) mod 2^64
sum2 = SUM(all g2) mod 2^64
sum3 = SUM(all g3) mod 2^64
count = 参与归约的有效条目数
```

crc = 初始值

for i 从 159 到 0：
    feedback = crc[63] XOR message[i]
    crc = crc 左移 1 位，只保留64位

    if feedback == 1：
        crc = crc XOR 0x42F0E1EBA9EA3693

CRC 采集在 50 MHz EH2 提交域完成，异步多写单读 FIFO 把 CRC pair 送到 125 MHz 归约域。每个 hart 有两个 package bank；日志结果和 WAW 事件再安全跨到 100 MHz 组帧域。

## 10. 主要模块

### 10.1 顶层与公共模块

| 模块 | 功能与构造 |
| --- | --- |
| `rtl/eh2_veri_system_top.sv` | 系统顶层；实例化时钟、TEMAC、双 MIG、EH2、DDR 主机、状态机、错误监测和全部 CDC |
| `rtl/common/eh2_system_pkg.sv` | 六状态枚举、DDR owner 枚举、MAC 地址和全部消息码 |
| `rtl/common/axi4_if.sv` | 统一 AXI4 interface 定义 |
| `rtl/common/axi_owner_mux2.sv` | 两主机逐阶段 AXI owner mux；状态机保证只在前一所有者空闲后切换 |
| `rtl/common/sync_bits.sv` | 多级位同步器 |
| `rtl/common/sync_fifo.sv` | 系统信息同步 FIFO 基础模块 |

### 10.2 控制与错误模块

| 模块 | 功能与构造 |
| --- | --- |
| `rtl/control/eh2_system_controller.sv` | 六状态控制器；管理初始化、自检、4 GiB 清零、20 s 程序超时、EH2 释放、END/ERROR 消息和 DDR owner |
| `rtl/control/system_error_monitor.sv` | 同步错误源 first-error-wins 编码和锁存 |

### 10.3 以太网与程序加载模块

| 模块 | 功能与构造 |
| --- | --- |
| `rtl/eth/ethernet_subsystem.sv` | 一套全双工 TEMAC、MAC 配置 ATG、DP83867 初始化和客户端 FIFO |
| `rtl/eth/eth_mac_fifo_block.v` | TEMAC 与 RX 8-to-16、TX 8 bit FIFO 封装 |
| `rtl/eth/dp83867_phy_init.v` | 扫描 PHY 地址、核对 ID、配置 RGMII_ID delay、重启自动协商并等待稳定链路 |
| `rtl/eth/eth_rx_frame_classifier.sv` | 缓存目的 MAC 的 3 个 16 bit word后流式分流；程序帧送 DMA、系统 payload 送专用 FIFO，并在 TLAST 核对精确长度 |
| `rtl/eth/program_rx_dma_ctrl.v` | 丢弃 14 byte 头、生成 1024 byte DataMover 命令、检查帧长/状态、地址加 `0x400` |
| `rtl/eth/program_dma_subsystem.sv` | DataMover S2MM 与程序控制器封装，起始地址固定 `0x80000000` |
| `rtl/eth/system_info_rx_fifo.sv` | 128 项、16 bit 的专用系统信息接收 FIFO |
| `rtl/eth/system_info_rx_decoder.sv` | 检查 46 byte payload，识别前 4 byte 全 `FF` 的结束标记 |
| `rtl/eth/system_info_tx_fifo.sv` | 16 项、32 bit code 的专用系统信息发送 FIFO |
| `rtl/eth/system_info_tx_formatter.sv` | 把一个 code 组装为固定 60 byte 广播帧 |
| `rtl/eth/system_tx_arbiter.sv` | 信息/日志 TX 帧级锁定仲裁，不允许帧内交叉 |

### 10.4 DDR 模块

| 模块 | 功能与构造 |
| --- | --- |
| `rtl/ddr/dual_ddr_mig_wrapper.sv` | 两个现有 MIG 的硬件封装 |
| `rtl/ddr/axi32_to_512_cdc.sv` | 程序/ATG 的 32 bit AXI 跨时钟并转换到 512 bit MIG UI |
| `rtl/ddr/axi64_to_512_cdc.sv` | EH2 IFU/LSU 的 64 bit AXI 跨时钟并转换到 512 bit MIG UI |
| `rtl/ddr/data_test_atg_wrapper.sv` | 50 MHz 数据 DDR 1024 byte `0xFF` 写入 ATG |
| `rtl/ddr/ddr_read_compare_master.sv` | 原生 512 bit AXI 读取并逐 byte 比较自检区域 |
| `rtl/ddr/ddr_fill_master.sv` | 原生 512 bit、256 beat burst 的低 4 GiB 快速清零主机 |

### 10.5 EH2、Hash 与日志模块

| 模块 | 功能与构造 |
| --- | --- |
| `rtl/eh2/eh2_core_crc_subsystem.sv` | EH2 网表/RTL 包装、复位向量、hart 启动策略、硬件初始化和提交信号接线 |
| `rtl/eh2/eh2_hw_init.sv` | 通过 EH2 DMA slave 清零 DCCM/ICCM 并发出 hart0 debug run |
| `rtl/eh2/eh2_veer_wrapper_mt_stub.v` | 综合使用 EDIF 时的多 hart 端口声明 |
| `rtl/crc/instr_crc_hash_dual.sv` | 双 hart 序号、WAW/nonblocking 处理、160 bit 结构和 CRC 生成 |
| `rtl/crc/crc64_ecma_pair_160.sv` | CRC-64/ECMA-182 与双 seed 仿射实现 |
| `rtl/crc/crc_pair_fifo_async_4w1r.sv` | 每周期最多四项写入、单读出的异步 CRC FIFO |
| `rtl/crc/crc_mix_accumulator.sv` | G 混合及 XOR/SUM package 归约 |
| `rtl/crc/instr_crc_system_dual.sv` | 双 hart、双 bank CRC/归约系统封装 |
| `rtl/log/log_result_cdc.sv` | 归约结果从 125 MHz 跨到 100 MHz |
| `rtl/log/waw_event_cdc.sv` | WAW 事件从 50 MHz 跨到 100 MHz |
| `rtl/log/waw_sequence_store.sv` | 每 hart、每奇偶 package bank 最多保存 483 个 WAW 序号 |
| `rtl/log/log_frame_packetizer.sv` | 快照一个归约结果和对应 WAW 列表，生成固定 1038 byte 日志帧 |

## 11. LED

| LED | 含义 |
| ---: | --- |
| 0 | 正在处理 `ERROR` 并发送错误帧；收到上位机停止确认并开始全局复位后熄灭 |
| 1 | MAC 配置完成且无错误 |
| 2 | PHY 初始化成功 |
| 3 | MIG0 校准完成 |
| 4 | MIG1 校准完成 |
| 5 | 当前为 `PROGRAM_WRITE` |
| 6 | 当前为 `EXECUTE` |
| 7 | 当前为 `END` |

## 12. 双 Hart 启动异常：原因与解决办法

### 12.1 错误现象

第一次完整系统长仿真中：

```text
mhartstart=11
hart0 commit > 0
hart1 commit = 0
```

`mhartstart=11` 证明 hart0 的：

```asm
li   t6, 2
csrw 0x7FC, t6
```

确实已经把 hart1 启动位写成 1。因此问题不在程序的 hart0 条件分支，也不在 CSR 地址或写入值，而发生在 hart1 被解除 `MHARTSTART` 门控之后的复位/运行模式。

### 12.2 根因

EH2 的 MPC 复位控制满足：

```text
take_reset = reset_allowed & mpc_reset_run_req
```

原连接为：

```systemverilog
.mpc_reset_run_req(2'b00)
.mpc_debug_run_req({1'b0, hw_run_req})
```

它对 hart0 是有意的：hart0 复位后先进入 debug halt，`eh2_hw_init` 才能清零 DCCM/ICCM，之后 `hw_run_req` 启动 hart0。

但同样的 `mpc_reset_run_req[1]=0` 也作用于稍后才由 `CSR 0x7FC[1]` 释放的 hart1。hart1 解除 `MHARTSTART` 后进入 MPC debug halt，而 `mpc_debug_run_req[1]` 永远为 0，因此它虽然显示“已启动”，却不会提交任何指令。

### 12.3 修复

连接改为：

```systemverilog
.mpc_reset_run_req(2'b10)
.mpc_debug_run_req({1'b0, hw_run_req})
```

效果：

- bit0 仍为 0：hart0 保持原有“复位后 debug halt → 初始化 DCCM/ICCM → debug run”流程；
- bit1 为 1：hart1 在被 `MHARTSTART` 释放后直接取复位向量运行；
- hart1 不会提前运行，因为 `MHARTSTART` 门控仍然存在，只有 hart0 写 `CSR 0x7FC[1]` 后才释放。

测试平台增加了两个直接断言点：

```text
HARTSTART_CSR_COMMIT hart=0 lane=0 pc=8000000c data=00000002
HART1_FIRST_COMMIT  lane=0 pc=80000000 insn=f1402473
```

修复后的仿真中，两者只相差约 520 ns。当前 200,000 条静态指令程序最终提交数为 hart0=100023、hart1=100021，说明 hart1 已从复位向量稳定执行，而不是只改变了启动状态位。

## 13. 前仿与 Spike 验证

### 13.1 Spike

硬件 ELF 保留真实的 `csrw 0x7FC,t6`。当前虚拟机里的标准 Spike 不实现 EH2 私有 CSR `0x7FC`，所以只为 Spike 另建兼容 ELF：

- Spike 兼容 ELF 在该位置临时使用 `nop`；
- Spike 运行后，把 hart0 对应 commit 记录恢复成真实 CSR 指令和写值；
- 设置 `mhartstart=2`，由日志后处理生成与硬件语义一致的双 hart 黄金记录；
- 硬件执行的 ELF 本身不做该替换。

最终 Spike/EH2 提交记录比较条目数为 200044：200011 条逐字段精确匹配，33 条属于已识别的 WAW victim 数据清零差异，缺失、额外和未解释 mismatch 均为 0。这里的 33 是 ISS 结构比较器需要接受的“结果被清零”条数，不是最终导出的 WAW 事件总数；整机日志实际导出 hart0/package0 的 4 条和 hart1/package0 的 128 条，共 132 条。

### 13.2 完整 RGMII 前仿覆盖

完整测试平台使用：

- 真实 TEMAC 行为模型和客户端 FIFO；
- RGMII nibble、RX clock、前导码、SFD 和 Ethernet FCS；
- RX 流式目的 MAC 分类器；
- 系统信息 RX/TX FIFO；
- 程序 AXI DataMover；
- AXI clock converter 和 data width converter；
- 两个 1 MiB、512 bit AXI DDR UI 行为模型；
- 完整 EH2 RTL；
- 双 hart CRC、归约和日志帧；
- `END` 两帧的物理发送完成判定以及全局复位请求。

MIG 的物理 DDR4 模型在前仿中被紧凑 AXI UI 内存替换，PHY MDIO 初始化因没有串行 PHY 模型而旁路；硬件工程的默认参数仍启用真实 DP83867 初始化和完整低 4 GiB 清零。

最终长仿真必须同时满足：

- 系统信息码顺序为  
  `11111111 → 44004444 → 44114444 → 22222222 → 33333333 → 44004444 → 44114444 → 44444444 → 55000000 → 55010000 → 550000FF → 550100FF → 55555555 → 77777777`；
- 两个 hart 都提交指令；
- hart0 确实提交 `CSR 0x7FC = 2`；
- 共发送四个日志帧；
- 四个日志帧的 package、count、六个归约值全部等于 Spike 黄金值；
- TX 真实产生 RGMII 活动；
- 两个 DDR AXI 内存模型无协议错误；
- `LED0=0`；
- 无 `$fatal`。

本轮最终结果为：

```text
FULL_SYSTEM_RGMII_PASS frames=18 info=14 log=4 rgmii_cycles=5208 min_ifg=783 rx_overflow=0
FULL_SYSTEM_FRAME_PASS frames=18 info=14 log=4 errors=0
```

日志中：

- `Fatal: 0`；
- `AXI_PROTOCOL_ERROR: 0`；
- 标准错误输出为 0 byte；
- `LED0` 未置位；
- `END` 两帧已在 RGMII TX 端完整捕获，之后提出全局复位请求；定向平台另行验证了 64-cycle 复位和返回 `PRECONFIG`。

四个实际发送的日志帧与 Spike 黄金值如下：

| Hart | Package | Count | WAW | xor0 | xor1 | sum0 | sum1 | sum2 | sum3 |
| ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- | --- |
| 0 | 0 | 65536 | 4 | `d31849f405d7893f` | `f362cffb3bd01126` | `40883202d86e0925` | `c155b99763889958` | `f97364871915ade9` | `7ec3152548d669c5` |
| 1 | 0 | 65536 | 128 | `bb84a72d88908184` | `77ae970cea8f03ee` | `f0ba1c03f647a3d4` | `07d2e3a5867b2f14` | `fec9fec6bbd4da0b` | `f9fc10899b8299e5` |
| 0 | 1 | 34487 | 0 | `ca29af3d5afed2de` | `dab2dbaec7cf9013` | `304dcd82a6df56f4` | `594544d87138de09` | `c90918dde2a98436` | `86df023d8dec6168` |
| 1 | 1 | 34485 | 0 | `b2c8ba18b57bb719` | `1d356092b1daae53` | `2f710fa64e36788d` | `ee452c2062e1d3ad` | `d772ad1beae8bdf4` | `cfaf9594c587af03` |

hart0/package0 的 WAW 序号为 `[18, 20, 26, 28]`。hart1/package0 共 128 条，完整列表以 `webui/golden/stress_200k_system_golden.json` 和 `artifacts/sim/full_system_frame_verify.json` 为准；package1 两个 hart 均为 0。离线校验不仅比较 count，还逐项比较全部序号和 WAW 区域之后的零填充。

调试过程中曾出现过一条测试平台 AXI 协议错误。诊断打印把首个触发点定位到 `PRECONFIG` 数据 ATG 的合法 `AWSIZE=2` 窄写。旧 DDR 行为模型错误地要求 512 bit AXI UI 上所有事务必须为 `AWSIZE=6`，并且固定按 64 byte 增加地址。修正后模型：

- 接受 `AWSIZE <= 6` 的 AXI4 INCR burst；
- 窄事务按 `1 << AxSIZE` 增加地址；
- 由 `AxADDR[5:0]` 和 `WSTRB` 选择 512 bit 总线中的有效 byte lane。

修正后的完整重跑先通过 1024 byte `0xFF` 写入/读取比较，再完成双 hart 执行；最终无 AXI 协议错误。该问题只在前仿 DDR 行为模型中，不是 MIG、DataMover 或 EH2 的硬件协议错误。

最终仿真输出和逐帧黄金值核对文件位于：

```text
artifacts/sim/full_system_vivado.log
artifacts/sim/full_system_tx_frames.log
artifacts/sim/full_system_frame_verify.json
artifacts/sim/eh2_spike_straight_200k_compare.json
artifacts/sim/spike_straight_200k_golden.json
```

## 14. 构建与验证命令

在工程根目录执行：

```powershell
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source scripts\create_project.tcl
powershell -ExecutionPolicy Bypass -File scripts\build_stress_program.ps1
powershell -ExecutionPolicy Bypass -File scripts\run_unit_sims.ps1
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source scripts\run_full_system_sim.tcl
python scripts\verify_full_system_frames.py artifacts\sim\full_system_tx_frames.log artifacts\sim\spike_straight_200k_golden.json --json artifacts\sim\full_system_frame_verify.json
```

生成的 Vivado 工程：

```text
build/vivado/eh2_veri_system.xpr
```

综合命令：

```powershell
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source scripts\run_synthesis.tcl
```

综合成功后执行完整板级实现和比特流生成：

```powershell
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source scripts\run_latest_board_implementation.tcl
```

最终比特流输出到 `output/board/eh2_veri_system_latest.bit`，并同步无后缀兼容名。脚本依次完成 `opt_design`、布局、物理优化、布线、实现报告和 `write_bitstream`，并在关键阶段保存 checkpoint、检查未解析黑盒。若前台执行环境超时但已留下有效的 `latest_post_physopt.dcp`，可使用 `scripts/resume_latest_board_route_and_bitstream.tcl` 从物理优化点继续路由、签核和位流生成，无需重做综合或布局。

综合和实现使用 EH2 EDIF 网表；完整行为级前仿用相同配置的 EH2 RTL 替代 EDIF，以便观察双 hart 提交信号。

## 15. 仍需用户决定的初始化/保护项目

当前系统已经实现正常工作所需的板级/监督器全局复位、MMCM、TEMAC、DP83867、确定性 RX 放行、双 MIG、自检、DDR1 清零和 EH2 DCCM/ICCM 初始化。以下项目不是当前功能的前提，但在最终长期运行产品中可考虑增加：

1. **外部时钟发生器初始化**：当前假设板卡已由上电配置提供 50 MHz、100 MHz、333.333 MHz 和 MIG 参考时钟。如果板上 SI5338/同类器件并非自动配置，需要增加主机或 FPGA 内部 I²C 初始化。
2. **指令 DDR 全空间清理**：当前每次程序会话只覆盖实际收到的连续 1024 byte 块；不会清零未被新程序覆盖的旧指令区。若软件可能跳到旧区域，可增加指令 DDR image 范围清理或长度上限保护。
3. **运行期 PHY 自动恢复**：当前链路丢失被视为致命错误并进入 `ERROR`。如需无人值守恢复，可增加重新协商、重新配置和有限次数重试。
4. **Image CRC 与重传**：当前 1028-byte payload 已包含 32-bit 连续 frame index，结束帧也包含 32-bit 总帧数，能够发现丢帧、重复帧和错序；仍未包含整幅 image CRC、ACK 或重传机制。若要求对内容提供独立于 Ethernet FCS 的端到端校验，可在不破坏现有编号字段的前提下扩展新协议版本。
5. **DDR ECC scrub**：如果最终 MIG 打开 ECC，可在上电后增加全空间 scrub；当前工程沿用现有 MIG 配置，不额外改变 ECC 设置。
6. **系统信息可靠确认**：系统信息帧当前是广播且不重传。若上位机必须保证收到每一个状态，可增加 ACK/序号/超时重发，但这会改变现有协议和状态推进条件。

以上项目均未擅自加入，避免改变四个已验证参考工程的板级假设和当前上位机协议。
