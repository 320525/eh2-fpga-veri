# 2026-08-25 最终错误修复、验证、实现与比特流说明

## 1. 最终结论

本轮已完成 RTL、WebUI、前仿、综合、实现、时序签核和 bitstream 生成。最终结果如下：

- DDR1 尾帧 `0x666600C4` 的确定根因已修复：旧读 DMA 会读取未写入 ECC 的 DDR 行；新设计只读取有效行并在本地补零。
- “只收到 hart0 的前若干帧、后续编号跳变、H0DN/H1DN/77777777 丢失、页面保持 END”的主因已修复到主机接收路径：Windows 改用 Npcap 原生热路径、64 MiB 内核缓冲和轻量字节队列，解码与 TXT 写入移出抓包线程。
- WebUI 所有解码日志改为 TXT，统一存入 `webui/runlog`；页面只提供打开 TXT 的链接，并新增板级全局复位按钮。
- 单元仿真、最终一次 10k 双 hart 顶层 RGMII 闭环和 WebUI 25 项测试均通过。
- 综合后及实现后 blackbox 均为 0；376352 个可路由网络全部布通。
- 最终 WNS `+0.045 ns`、WHS `+0.009 ns`；74 组 bus-skew 全部满足，最差 `+2.218 ns`；严重 DRC 为 0。
- 未压缩 bitstream 已成功生成。

本轮没有代替用户进行实体开发板烧写和物理链路长时间运行，因此“RTL/实现已签核”和“主机在特定机器上永不丢包”仍应区分。板级每轮比较前必须检查 Npcap drop 计数。

## 2. DDR1 DMA 错误的根因

每条 DDR1 记录为 256 bit，一个 512-bit MIG UI beat 保存两条记录。一个网络数据帧最多发送 60 条记录，因此满帧需要 30 个 DDR beat。

旧读 DMA 不区分满帧和尾帧，始终向 DDR1 发出 30 个真实读拍。若尾帧只有 53 条记录，写 DMA 实际只创建 27 个有效 DDR 行，但读 DMA仍读取第 28～30 行。MIG1 开启 ECC，从未写过的行没有由本系统生成确定 ECC，可能返回非 OKAY `RRESP`，错误监测器据此发送 `0x666600C4`。

普通 RTL DDR 模型对未写地址直接返回零和 OKAY，不模拟 MIG 的未初始化 ECC 行响应。这就是旧前仿能通过，而开发板在程序结束、读取最后一帧时稳定进入 DDR1 DMA 错误的原因。

## 3. DDR1 RTL 修复

### 3.1 读 DMA

`info_ddr_read_dma.sv` 新增每帧 `valid_records`：

```text
real_ddr_beats = ceil(valid_records / 2)
```

模块只为这些有效行发出 AXI AR。每笔 burst 仍同时受三个条件限制：剩余有效拍数、最大 64 beat、当前地址到下一个 4 KiB 边界的拍数。AR 握手后，模块完整接收该 burst 的所有 R beat，并检查 `RRESP` 和 `RLAST`。

真实 DDR 行读完后，模块进入本地补零状态，向帧构造器继续输出全零 512-bit beat，直到对外仍完成固定 30 次 beat 握手。补零不产生 AR，不访问 DDR。帧构造器、双帧槽、TX Client FIFO 的长度、索引和 `last` 机制保持不变。

示例：

- 60 条记录：真实读取 30 beat，本地补 0 beat；
- 53 条记录：真实读取 27 beat，本地补 3 beat；
- 1 条记录：真实读取 1 beat，本地补 29 beat。

### 3.2 写 DMA

奇数尾部只有一条 256-bit 记录时，写 DMA 仍写完整 512-bit 行：低 256 bit 保存有效记录，高 256 bit 清零，64 Byte WSTRB 全部有效。这样 MIG 为整行生成确定 ECC；逻辑记录计数仍只增加 1。

### 3.3 功能不变项

- 网络仍发送 24-Byte Info Struct，不发送 DDR 记录低 64-bit 保留区。
- payload 仍固定 1444 Byte，即 4-Byte frame number + 60×24 Byte 记录槽。
- 尾帧只在末尾补零；两个完整帧槽的 dirty/publish/release 和 125 MHz MAC 读口不变。
- hart0 仍使用 DDR1 高 4 GiB，hart1 仍使用低 4 GiB。

## 4. 页面保持 END 和日志丢帧的根因

100023/100021 条记录对应两个 hart 合计 3336 个 1458-Byte 数据帧，再加完成帧和系统状态帧。FPGA 能在约 40 ms 内以接近 1 Gb/s 连续发送约 4.86 MiB，主机需要承接约 8 万个大包/秒的短时突发。

旧 Windows 接收路径使用 Scapy `AsyncSniffer`。抓包线程会为每帧创建 Python Packet 对象，同时进入解码、页面数据组织和文件处理；Npcap 默认缓冲也较小。主机来不及取走数据时，内核只能丢弃帧。以太网链路没有从 PC 抓包程序反馈给 FPGA 的逐帧背压，FPGA 不知道主机丢包，也不会重传。

因此会出现：

- 第一轮只连续保存 hart0 的 0～850 等部分帧；
- 下一轮在不同位置出现编号跳变；
- H0DN、H1DN、`77777777` 和复位后的 `11111111` 可能一起丢失；
- 页面保留最后收到的 `55555555/END`。

页面显示的是最后一个收到的系统码，不是直接读取 FPGA 内部状态寄存器。缺少 `77777777` 和 `11111111` 时，页面保持 END 不能单独证明 FPGA 未复位。

## 5. WebUI 修复

Windows 抓包路径现在直接调用 Npcap/libpcap：snaplen 2048 Byte，激活前申请 64 MiB 内核缓冲，BPF 只保留 EtherType `0x88B5/0x88B7/0x88B8`。热路径只把原始字节复制到队列；协议解码、sequence coverage、比较和 TXT 写入在后台消费线程执行。

WebUI 同时提供 `ps_recv`、`ps_drop`、`ps_ifdrop`。任一 drop 计数非零时，本轮接收证据不完整，不允许给出 PASS。若这套主机仍不能无丢包承接线速突发，下一步应增加 FPGA/PC 协议级窗口、ACK 和重传，而不是继续增大 FPGA 两帧槽。

日志文件统一为：

```text
webui/runlog/session_*/decoded_info_frames.txt
webui/runlog/automation/session_*/run_*/fpga_info.txt
webui/runlog/saved_log_*.txt
```

页面不再展开全部记录，只提供打开 TXT 的链接。自动化失败后保留该轮文件和第一次失败 sequence，但允许在后台比较线程完全退出后再次启动。新增“复位板卡”按钮，发送独立系统命令 `0x44134445`；该帧不会进入程序帧 RX/DMA 路径。

## 6. 验证结果

### 6.1 RTL 定向仿真

- Info 捕获差分、双 hart FIFO、弹性读出和写 DMA：PASS；
- 奇数尾完整 ECC 行写入：PASS；
- 有效 DDR 行读取、4 KiB 分段、27 个真实 beat + 3 个本地补零 beat：PASS；
- 两个完整帧槽满/空、长背压、释放、复用和顺序：PASS；
- 控制器、PRECONFIG 仅一帧、程序编号、系统帧隔离、全局复位命令和错误 CDC：PASS。

### 6.2 最终一次顶层闭环

最终修改后只执行一次完整顶层 RGMII 闭环：

- PRECONFIG 从实际 RGMII/MAC RX 注入一帧 1024 Byte 全 FF 和结束帧；
- PROGRAM_WRITE 以最小协议 IFG 连续注入 79 个程序帧，从正式 MAC RX/DMA 写入 DDR0；
- hart0 通过 CSR `0x7FC=2` 启动 hart1；两 hart 从 `0x80000000` 执行；
- 记录数 hart0/hart1 为 10001/10000；数据帧 167/167；
- 共发送 334 个数据帧、2 个 hart 完成帧和最终 `77777777`；
- RX/FIFO overflow 为 0，最终执行全局复位；
- 顶层结果 `FULL_SYSTEM_RGMII_PASS`。

该次输出保存为 `output/verification/current_fix_full_top/fpga_info.txt`，生产 WebUI 比较器重新解析后两个 hart 均通过。此前不同种子的两轮 10k 自动化闭环证据仍保存在 `output/verification/automation_10x10k/campaign_20260825_005851`。

### 6.3 WebUI

25 项测试全部通过，包括 3336 个数据帧、100023/100021 条记录、两个完成帧、TXT 重构、失败后再次启动、累计比较次数和板级复位帧。Realtek Gaming GbE 的 Npcap 64 MiB 打开、过滤、停止和统计接口已实际验证。

## 7. 综合、实现与时序

- Vivado 2023.2，器件 `xcvu19p_CIV-fsva3824-1-e`；
- 综合完整重建：0 Error、0 Critical Warning；综合网表所需层级全部存在；
- post-opt / post-route blackbox：0；
- `place_design`：0 Error，放置后优化将估算 setup 从负值修到正值；
- `route_design`：376352/376352 个可路由网络 fully routed，routing errors 0；
- 正式 timing summary：WNS `+0.045 ns`、TNS `0`、WHS `+0.009 ns`、THS `0`、WPWS `+0.046 ns`；
- 74 组 bus-skew 全部 `MET`，最差 slack `+2.218 ns`；
- 严重 DRC 0；Bitgen 0 Error、0 Critical Warning；
- 实现峰值内存约 19104 MB。

普通 DRC 有 102 个 Warning、6 个 Advisory，主要来自 EH2 原始 DSP 未使用内部流水、EH2 原始 URAM parity-interleaved 写使能建议、MIG/debug 无可路由负载和 I/O SLR crossing。它们没有造成 DRC Error 或时序失败，但任何 RTL/XDC/IP 变化后仍必须重新审查，不能只看 bitstream 是否生成。

本轮为了避免高内存崩溃，综合内部最多 4 个 helper，opt 1、place 2、bitgen 1；route 脚本设置 2，但 Vivado 路由器内部报告最多使用 8 CPU。跳过了曾导致 50 GiB 以上内存占用的高强度 `AggressiveExplore`。

## 8. 最终产物

| 文件 | 大小 | SHA-256 |
| --- | ---: | --- |
| `output/board/eh2logcomp_2slot.bit` | 199112137 Byte | `EF901C78E23654CBC8741E3DDA76C6D967BC92631A15A882FCA45CF745A150BB` |
| `output/board/eh2logcomp_2slot_routed.dcp` | 201083512 Byte | `A17FA0DA86643C92840675E234045E0F15D2B7179BEA1E009F9AD15B77D0621E` |
| `output/board/implementation_20260825_164411_214114.log` | 211514 Byte | `754F33CAF21F69F51ED4BA2781118012B9C960250F6944AFDA95CB4662F39A96` |
| `output/board/riscvdv_10k_top/riscvdv_10k_program.bin` | 88040 Byte | `065E5AF9C246A612F6504B1A77F2C7DF9FFFE4F19FA30C914C2FABA9C351C70F` |
| `output/board/riscvdv_10k_top/riscvdv_10k_program_frames.bin` | 89612 Byte | `60AFBF36A916C8FFF4A0F832C051E98120D49ED1BDBB16D417ED72156DC40BF0` |
| `output/verification/current_fix_full_top/fpga_info.txt` | 4905101 Byte | `EBBDC30578E763D448EE74D1E3A54998AB3EE375AC248501149D9CC64DD28EE7` |

烧写前应使用 `output/board/SHA256SUMS.txt` 复核，禁止使用历史 `eh2logcomp_2slot_postroute_timing_fixed.dcp` 或旧哈希对应的 bitstream。

## 9. 板级运行注意事项

1. 先启动 WebUI 监听，再复位 FPGA；按 `11111111 -> PRECONFIG 检查 -> 22222222 -> READY 清零 -> 33333333` 的顺序等待。
2. `33333333` 物理发送完成后 FPGA 才处于 PROGRAM_WRITE。收到错误时 WebUI 立即停止发送并回发停止确认。
3. Info 回传后先检查 `ps_drop/ps_ifdrop`，再判断缺包属于 FPGA 还是主机。
4. 当前 setup/hold 余量很小。修改 PHY delay、IDELAY、时钟根、引脚、RTL、IP、Vivado 版本、seed 或 directive 后，必须重新综合、实现、min/max timing、bus-skew、route、DRC 和 bitgen。
5. FPGA 仍没有日志回传 ACK/重传；主机抓包掉帧时不能据此校验 PASS。
