# EH2LOGCOMP 系统说明

最新的自动化全流程、阶段耗时、Spike TXT 保存、RESETTING 根因与修复见 `automation_timing_reset_recovery_readme.md`。此前 ECC 尾帧、Windows 线速抓包、验证、实现和 bitstream 记录见 `final_20260825_ecc_capture_bitstream_readme.md`；板级烧写前请以 `output/board/SHA256SUMS.txt` 的当前哈希为准。

## 1. 系统目标

系统在一块 FPGA 中集成双 hart VeeR EH2、两套 DDR4 MIG、单个全双工 TEMAC/RGMII、程序接收 DMA、逐指令信息采集/存储/回传、六状态控制器、错误监测和 WebUI。

当前版本的关键区别是：不再发送 CRC/hash 归约结果，而是保留每条有效提交指令的 Info Struct。每个 hart 有独立的 32-bit `sequence_id`，均从 0 递增；不存在 package 概念。

## 2. 顶层数据流

```text
PC 程序帧 -> RGMII RX -> TEMAC RX FIFO -> 目的 MAC 分类
             -> 程序帧序号检查 -> 1024-byte S2MM DMA -> DDR0@0x80000000

EH2 IFU ----64->512 AXI CDC--+
EH2 LSU ----64->512 AXI CDC--+-> 仲裁 -> DDR0

EH2 提交/WAW/非阻塞返回
  -> 每 hart 最多同周期 4 条 Info Struct
  -> 每 hart 独立 4-write/2-record-read 异步 FIFO
  -> 弹性寄存器 -> DDR1 写 DMA
  -> hart1: DDR1[0,4GiB)，hart0: DDR1[4GiB,8GiB)

END：DDR1 读 DMA（按有效行读 DDR，本地补零为构帧侧固定 30×512 bit）
  -> 两个完整帧槽（UI 域构帧、125 MHz 域读帧）
  -> TEMAC TX -> RGMII TX -> PC
```

DDR0 在不同时期只允许一个功能组获得所有权：PRECONFIG/PROGRAM_WRITE 为程序 DMA 或检查器，READY 为 4 GiB 清零器，EXECUTE/END 为 EH2 IFU+LSU。DDR1 在 PRECONFIG 为 ATG/检查器，EXECUTE 为 Info 写 DMA，END 为 Info 读 DMA。所有权先在 100 MHz 控制域寄存，再同步到对应 MIG UI 时钟域；切换前等待原主设备空闲。

## 3. Info Struct

### 3.1 有效结构

每条逻辑结构为 192 bit（24 Byte），网络按大端字节顺序发送：

| 字节偏移 | 长度 | 字段 | 说明 |
| ---: | ---: | --- | --- |
| 0 | 4 | `sequence_id` | 每 hart 独立，从 0 连续递增 |
| 4 | 4 | `pc` | 提交指令 PC |
| 8 | 4 | `instruction` | 32-bit 指令字 |
| 12 | 4 | `metadata` | 见下表 |
| 16 | 4 | `data` | GPR/CSR 写入数据；被 WAW 取消时为 0 |
| 20 | 4 | `waw_cancel_number` | 取消本条写回的较新指令 sequence；无取消时为 0 |

`metadata` 位定义：

| 位 | 字段 |
| --- | --- |
| 31:30 | `waw_cancel_kind`：0 无，1 同周期直接 WAW，2 nonblock load，3 nonblock divide |
| 29:17 | 保留 0 |
| 16 | hart id |
| 15:14 | privilege |
| 13:12 | event type：0 无架构写回，1 GPR，2 CSR |
| 11:0 | GPR/CSR 编号 |

### 3.2 WAW 的产生和配对

同周期直接 WAW 时，EH2 标记较老的 victim 指令。该 victim 的 `waw_cancel_kind=1`，`data=0`，`waw_cancel_number` 写入同 hart 的较新写者 sequence。

非阻塞 load/divide 提交时，采集器按 hart 和目标寄存器保存该指令的完整结构；结果返回后再补写数据。如果在结果返回前发生 WAW，则把原结构改为 kind 2/3、数据清零，并写入造成取消的指令 sequence。每个 hart 独立维护 32 个寄存器槽，匹配错误或冲突分别触发错误码，而不会把 hart1 的 sequence 混入 hart0。

### 3.3 DDR1 存储格式和容量

DDR 中每条记录固定 256 bit（32 Byte）：高 192 bit 是上述结构，低 64 bit 保留为 0。这样一个 512-bit MIG beat 恰好存两条记录。

- hart1 基地址 `0x000000000`，范围 `[0, 4 GiB)`；
- hart0 基地址 `0x100000000`，范围 `[4 GiB, 8 GiB)`；
- 每 hart 最大记录数为 `4 GiB / 32 = 134217728` 条；
- 每 hart 使用独立深度 1024 条记录的异步 FIFO；同周期最多写 4 条，读侧每次输出 1 或 2 条组成 512 bit。

写 DMA 在正常执行中仅在 FIFO 至少有两条记录时启动；收到 capture done 后允许处理最后一条奇数尾记录。奇数尾记录放在 512-bit 行的低 256 bit，高 256 bit 清零，并用全 64 Byte WSTRB 写完整行，使 MIG 为整行生成确定的 ECC；记录计数仍只增加 1。每个 AXI INCR burst 最多 64 beat，并在 4 KiB 边界处截断，绝不跨越 AXI4 规定的 4 KiB 边界。

## 4. Info 以太网回传

### 4.1 数据帧

- 目的 MAC：`FF:FF:FF:FF:FF:FF`
- hart0 源 MAC：`02:32:05:25:10:00`
- hart1 源 MAC：`02:32:05:25:10:01`
- EtherType：`0x88B7`
- Payload：固定 1444 Byte
- 不含 FCS 的以太网帧长度：1458 Byte

Payload：

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 4 | 当前 hart 的 32-bit 大端帧号，从 0 连续递增 |
| 4 | 1440 | 60 条连续的 24-Byte Info Struct |

最后一帧不足 60 条时，仅尾部无效记录补 0；中间不允许出现全零记录后再出现有效记录。

为构造一帧，帧构造器固定接收 30 个 512-bit beat（1920 Byte、60 条 32-Byte DDR 记录槽），但 DDR1 读 DMA 只向 MIG 发出 `ceil(valid_records/2)` 个真实读拍。读地址从 `hart_base + frame_number*1920` 开始，若碰到 4 KiB 边界则拆成多个 AR burst；真实数据读完后，DMA 在本地产生全零拍补足索引 0..29，不再访问未写入 ECC 的尾部 DDR 行。构帧器从每个有效 256-bit DDR 记录中只取高 192 bit，丢弃 64-bit 保留区，其余 payload 自动补 0。

### 4.2 两个完整帧槽

两个槽都能保存完整的 14-Byte 帧头、4-Byte 帧号和 1440-Byte记录区。UI 时钟域在启动 DMA 前先原子占用一个槽并置 `dirty`；30 个 beat 全到达后清 `dirty` 并翻转 publish toggle。125 MHz TX 域同步看到 publish 后才读取，因此永远不会发送半帧。

TX 域按帧头、帧号、60 条记录顺序逐字节输出；`tvalid/tready` 背压时所有索引保持不动。最后一个字节握手才拉高 `tlast`，翻转 release toggle 并切到另一个槽。release 同步回 UI 域后该槽才可复用。第二个槽被占用时即报告 full，直到第一槽整帧释放后才允许新的 DMA。这是帧粒度的乒乓缓冲，正常情况下 DDR1 搬运和 MAC 发送并行，不引入帧间空洞。

### 4.3 hart 完成帧

每个 hart 数据帧全部发送并释放后发送一个完成帧：

- 目的 MAC：广播；源 MAC 按 hart 区分；EtherType `0x88B8`；Payload 46 Byte。

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 4 | ASCII `H0DN` 或 `H1DN` |
| 4 | 1 | hart id |
| 5 | 1 | 协议版本 1 |
| 6 | 2 | 记录字节数 `0x0018`（24） |
| 8 | 4 | 总有效记录数 |
| 12 | 4 | 总数据帧数 `ceil(records/60)` |
| 16 | 4 | 最后 sequence；无记录时 `FFFFFFFF` |
| 20 | 3 | 0 |
| 23 | 1 | 对端 hart 标记 |
| 24 | 22 | 0 |

发送顺序固定为：hart0 所有数据帧 → H0DN → hart1 所有数据帧 → H1DN。

## 5. 程序接收协议

程序帧目的 MAC `02:12:34:56:78:FF`，源 MAC `02:32:05:25:00:FE`，EtherType `0x88B6`，Payload 为 4-Byte 大端帧号加 1024 Byte 程序数据。帧号必须从 0 严格连续；只有后 1024 Byte 写入 DDR0，从 `0x80000000 + frame_number*1024` 开始。每帧创建固定 BTT=1024 的 DataMover S2MM 命令；只有状态返回 EOP、1024 Byte、OKAY、无错误且 tag 正确才增加 DMA done 计数。

结束帧使用系统 MAC `02:32:05:25:00:FF` 和 EtherType `0x88B5`，Payload 为 `FFFFFFFF + 总程序帧数 + 38 Byte 0`。主机可在最后程序帧提交后立即发送结束帧，不等待 FPGA DMA；FPGA 在内部等待三个条件一致后才发送 `44444444`：接收的连续程序帧数 = 结束帧声明数 = 成功 DMA 数，且 DMA idle。

PRECONFIG 使用完全相同的正式程序路径，只允许 sequence 0 的一帧 1024 Byte 全 FF 和声明总数 1 的结束帧，随后从 DDR0 `0x80000000` 回读检查 1024 Byte。

## 6. 六状态流程

1. **PRECONFIG**：EH2 保持复位；等待 MAC 配置、PHY 初始化/链路/RX 稳定、两套 MIG 校准完成；发送 `11111111`。主机发送一帧全 FF 和结束帧，系统同样发送 `44004444`、`44114444`，等待帧数/DMA 配对；DDR0 回读全 FF，DDR1 同时由 ATG 写读检查。通过发 `22222222`。
2. **READY**：EH2 保持复位；使用 DDR0 512-bit UI 清零低 4 GiB。完成后仅清除程序会话计数，发送 `33333333`；该帧物理发送完成后进入 PROGRAM_WRITE。
3. **PROGRAM_WRITE**：第一笔程序 AXI 写发生时发送 `44004444` 并开始 20 s watchdog；收到结束帧发送 `44114444`；严格满足总数、连续性、DMA 完成和 idle 后发 `44444444`，再进入 EXECUTE。没有程序就持续等待。
4. **EXECUTE**：DDR0 全部交给 EH2，DDR1 全部交给 Info 写 DMA；经过 16 个控制时钟 guard 后释放 EH2，执行硬件初始化并启动双 hart。实际首条提交发送 `55000000/55010000`，实际停止发送 `550000FF/550100FF`。两 hart 停止、Info FIFO/DMA 全排空且 IFU/LSU AXI 连续 idle 16 个控制周期后进入 END。
5. **END**：先发 `55555555`，然后回传 hart0/hart1 的全部 Info 数据与完成帧；回传完成后发 `77777777`。确认提交给 MAC 的所有帧都已在物理 MAC 完成计数中出现，才请求持续 64 个 100 MHz 控制周期的全局复位，之后重新进入 PRECONFIG。
6. **ERROR**：第一错误锁存，停止 EH2 和日志优先发送，LED0 点亮并发送一次错误码。WebUI 收到错误后立即停止程序发送并回发 `44124445`；FPGA 收到该确认后执行同样的全局复位并重新进入 PRECONFIG。

## 7. 复位和 CDC

板级复位为 `sw3_1 && sw4_1` 电平有效。MMCM 锁定后还需 16 个 100 MHz 周期形成 base reset release。正常 END 或 ERROR 握手触发的全局复位由独立 supervisor 保持 64 个 100 MHz 周期；它不是 AXI 事务，复位线分别直接接到模块/IP 的 reset 端口。

各时钟域采用异步拉低、在本时钟域同步释放的本地复位或 IP 自带复位接口。多 bit 数据通过 AXI Clock Converter、XPM 异步 FIFO或“稳定数据 + toggle 事件”跨域；状态位采用多级 `ASYNC_REG` 同步。DDR 所有权先 one-hot 寄存再同步，避免状态编码多 bit 同时变化造成瞬时多主。

## 8. 模块职责

- `eh2logcomp_system_top.sv`：顶层时钟/复位、DDR 所有权、CDC、错误和数据流集成。
- `eh2_core_info_subsystem.sv`：EH2 网表封装、初始化、IFU/LSU、提交/WAW 信号导出。
- `instr_info_capture_dual_hier.sv`：双 hart 独立 sequence、停止标记和两个物理 bank 的顶层调度。
- `instr_info_capture_hart_bank.sv`：单 hart 逐指令结构、direct/nonblock WAW 配对和四条并发输出；hart0/hart1 分别独立布局。
- `info_fifo_async_4w2r.sv`：每 hart 四写口、读侧一拍输出最多两条记录的异步 FIFO。
- `info_fifo_read_elastic.sv`：隔离 FIFO 指针逻辑与 266.525 MHz MIG WREADY/写 DMA 组合路径。
- `info_ddr_write_dma.sv`：FIFO 到 DDR1，64-beat 上限、4 KiB 截断、区域保护和记录计数。
- `info_ddr_read_dma.sv`：按有效记录数读取 `ceil(N/2)` 个真实 DDR1 beat，遵守 4 KiB 分段，并在本地补零到帧构造器所需的固定 30 beat。
- `info_tx_frame_fifo_2slot.sv`：两个完整 1458-Byte 帧槽、原子 publish/release、125 MHz 无缝发送。
- `info_log_dump_subsystem.sv`：hart0/hart1 发送顺序、数据帧和完成帧调度。
- `eth_rx_frame_classifier.sv`：只缓存前三个 16-bit 目的 MAC 字，随后流式分类，避免全帧缓存溢出。
- `program_rx_dma_ctrl.v` / `program_dma_subsystem.sv`：程序序号、固定 1024-Byte S2MM 和完成状态校验。
- `eh2_system_controller.sv`：六状态、20 s watchdog、状态信息、完成条件和复位握手。
- `system_error_monitor.sv`：first-error-wins 错误锁存和编码。

## 9. 运行限制

- 程序从 `0x80000000` 执行，当前 EH2 reset vector 同为 `0x80000000`。
- 自动化随机程序的 IFU 区间固定为 `[0x80000000,0xA0000000)`；所有随机 LSU 地址的总包络为 `0xA0000000–0xFFFFFFFF`。普通 load/store、栈和 NOLOAD 数据位于外部 DDR0 `[0xA0000000,0xD0000000)`，AMO/LR/SC 因 EH2 硬件限制放在真实 64 KiB DCCM `[0xF0040000,0xF0050000)`，两个 hart 使用互不重叠的原子页。
- 程序帧只烧写 `0x80000000` 起的连续代码镜像；NOLOAD 数据不进入以太网程序帧，依赖 READY 已完成的 DDR0 清零。链接脚本使用分离 PT_LOAD，避免在稀疏地址之间产生巨大 BIN。
- WebUI 默认最大程序 64 MiB；硬件帧号和计数为 32 bit。
- DDR1 每 hart 最多 4 GiB/134217728 条记录；超界进入 ERROR。
- 系统没有程序帧逐帧 ACK 或重传。序号、总数、FCS 和 DMA 状态用于检测，不用于恢复；错误后必须由主机停止并确认，再全局复位重来。
- Info 数据帧 1458 Byte（不含 FCS），低于标准以太网 1500-Byte payload 上限；网卡/交换机无需 jumbo frame。
- 2026-08-25 最新完整重建的全局时序为 `+0.045 ns` setup 和 `+0.009 ns` hold，TNS/THS 均为 0；74 组 bus-skew 全部通过，最差 `+2.218 ns`；route errors、严重 DRC 和实现后 blackbox 均为 0。裕量仍很小，任何设计、约束、PHY 延迟或实现 seed/directive 变化都必须重新签核。
