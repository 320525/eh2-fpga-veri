# EH2 自动化全流程、阶段耗时与 RESETTING 修复说明

## 1. 本次日志结论

对 `webui/runlog/session_*` 中完整事件顺序逐轮统计：58 次 `77777777 EXE_END` 后直接收到 `11111111 PREINIT_DONE`；3 次在收到 `77777777` 后没有自动出现 `11111111`，必须由用户点击复位并发送 `0x44134445` 才恢复；日志末尾还有 1 次停在 `77777777`、尚未出现后续 `11111111`。这些异常轮次此前均已收到 H0DN、H1DN，两个 hart 的帧数、记录数和 sequence 覆盖核对也已通过。因此问题不在程序生成、程序烧写、EH2 停止条件或 Info 数据未发完，而在 END 最后一帧之后的全局复位放行。

旧 RTL 在 `77777777` 的最后一个字节进入 TEMAC 客户端后，等待：

```text
tx_frame_complete_count == tx_submitted_frame_count
```

两个量分别来自“物理发送统计时钟域”和“125 MHz 客户端提交时钟域”，均通过独立 Gray 计数器 CDC 到 100 MHz 控制域。客户端提交计数只在 `valid && ready && last` 时加一；旧物理统计计数却在 `tx_statistics_valid` 为高的每个 TX 时钟都加一。Xilinx 随 TEMAC 生成的 `tri_mode_ethernet_mac_0_vector_decode.v` 明确先用 `tx_statistics_valid && !tx_statistics_valid_reg` 取上升沿，因为统计有效电平可能连续保持多个使能时钟。旧 RTL 没有做该取边沿，一帧可能被物理计数两次或多次，从而形成永久差值。即使统计有效只有一拍，发送 FIFO 流水线和两条 CDC 的观察延迟也会造成暂时不等。严格相等一旦错过就可能永远不再成立。控制器于是已经发出 `77777777`，上位机显示 `RESETTING`，但 `global_reset_request` 没有产生。手工 `0x44134445` 绕过该相等条件直接请求复位，所以能够恢复，这与板级日志完全一致。

日志还出现过一次 VM 共享目录错误：Linux 在更新 `status.json` 时，HGFS 对 `status.json.tmp -> status.json` 的替换短暂返回 `Permission denied`。这是 Windows 正在轮询同一共享文件时的 HGFS 文件锁竞争，与 FPGA RESETTING 无关，但会使该轮 VM 任务错误停止。

## 2. RTL 修复

END 的发送排空改为以下顺序：

1. 物理统计计数改成与 Xilinx TEMAC 解码器一致的 `tx_statistics_valid` 上升沿计数。专项仿真连续保持统计有效 1、4、2 个 TX 时钟，最终只累计 3 帧而不是 7 帧。
2. `info_frame_done && info_sent_code == 0x77777777` 证明 EXE_END 的最后字节已被 125 MHz MAC 客户端接口接受。
3. 再等待 16 个 100 MHz 控制周期，让“已提交帧计数”完整跨过 Gray CDC。
4. 锁存该稳定值为 `end_tx_target_count`，后续不再追逐变化中的当前提交值。
5. 使用模 32 位差值判断物理完成计数已经“达到或越过”目标；物理计数领先 1 也能通过，不再要求两个异步累计量精确相等。
6. 默认再提供 10 ms 的物理排空上限。10 ms 在 1 Gb/s 下可发送约 1.25 MB，远大于 TEMAC 客户端 FIFO 能保留的数据；即使一次物理统计事件丢失，也不会让系统永久停在 RESETTING。
7. 条件通过后仍由原有 supervisor 把全局复位保持 64 个 100 MHz 周期，并由各本地时钟域各自同步释放复位，系统功能和复位范围不变。

`tb_system_controller` 已增加专门反例：让最后一个 EXE_END 的物理完成计数比提交计数多 1。旧相等逻辑会永久等待；修复后仿真在发送完 14 个既有系统帧后正常产生全局复位请求。完整 RTL 单元回归全部通过。

## 3. WebUI 二级恢复

WebUI 在以下事件后启动 8 秒 PREINIT 看门狗：

- 收到 `0x77777777`；
- 错误处理已发送 `0x44124445 HOST_SEND_STOPPED`；
- 用户发送 `0x44134445 HOST_GLOBAL_RESET`。

8 秒内收到 `0x11111111` 会用复位代次号取消旧看门狗。该窗口大于 RTL 的 5 秒初始化超时，不会在 MIG/PHY 合法的慢启动期间误触发。若仍处于 RESETTING，WebUI 自动补发 `0x44134445`，最多重试 2 次。自动恢复不会停止正在等待 Spike/FPGA 比较的自动化轮次，也不会删除其日志；只有两次重试后仍无 PREINIT，页面才显示 `RESET_TIMEOUT` 并提示检查 PHY、MIG 初始化或执行真正的板级硬复位。

该二级机制同时覆盖两种情况：FPGA 确实未产生内部复位请求；FPGA 已复位但上位机恰好漏收新的 `11111111`。它不是替代 RTL 修复，而是避免任一单点故障让连续自动化永久阻塞。

## 4. 自动化执行全流程

### 4.1 启动与 PRECONFIG

1. 用户选择 FPGA 物理网卡、开始监听，然后点击“一键自动化”。此时本次显示的总比较、PASS、FAIL 和累计已比较指令数全部清零。
2. FPGA 完成 MAC、PHY、RX 确定性放行、MIG0/MIG1 初始化后发送 `0x11111111 PREINIT_DONE`。
3. WebUI 立即通过程序帧 MAC/EtherType 发送 1 个编号为 0、数据区为 1024 Byte 全 FF 的程序帧，随后通过系统帧路径发送结束帧，结束帧总包数为 1。
4. FPGA 走正式程序接收、编号检查、RX FIFO、DMA 和 DDR0 `0x80000000` 写入路径，发送 `0x44004444 PROGRAM_WRITE_START` 和 `0x44114444 RECEIVE_DONE`；同时数据 DDR 检查路径按 RTL 定义执行。
5. DDR 回读与数据通路均通过后，FPGA 发送 `0x22222222 SYSTEM_FUNCTION_CHECK_PASS`。

### 4.2 VM 何时开始，以及 FPGA READY 并行阶段

WebUI **在收到 `0x22222222` 时**通过 SSH 调用 VM，而不是等到 `0x33333333` 才调用。这样 VM 的程序生成可与 FPGA READY 阶段并行：

1. Windows 创建唯一 `run_id` 和随机 seed，在 `D:\share\comp_log_dvspike\runs\run_id` 建立共享轮次目录。
2. WebUI 通过 SSH/SFTP 更新 VM 私有 helper，然后以后台进程启动 `remote_runner.py`。
3. VM 使用缓存好的双 hart riscv-dv VCS 生成器产生 RV32IMAC 随机汇编；加入 EH2 hart0 写 CSR `0x7FC` 启动 hart1、两个 hart 的停止 store、必要 fence 和停驻跳转。
4. VM 编译随机块，分别链接硬件镜像与 Spike 镜像，检查程序区 `0x80000000–0x9fffffff`、普通数据区 `0xa0000000–0xcfffffff`、真实 64 KiB DCCM 原子窗口 `0xf0040000–0xf004ffff` 不重叠，然后生成 `program.bin` 和 `manifest.json`。
5. FPGA READY 同期完成 DDR0 规定范围清零、会话复位和总线隔离，随后发送 `0x33333333 READY`，硬件此时已经进入 PROGRAM_WRITE。

程序发送有两个严格条件，缺一不可：已经收到本轮 `0x33333333`；VM 的 `status.json` 已声明 `program_ready=true` 且 `program.bin` 完整存在。先到的一方只锁存状态，不能提前发送。

### 4.3 程序发送与 Spike 并行

VM 链接完成后立即运行：

```text
spike -p2 --isa=RV32IMAC --log-commits ... program_spike.elf
```

原始 commit trace 写入共享目录 `spike.log`。与此同时 Windows 从同一轮 `program.bin` 逐块读取，以 1028-Byte payload 程序帧全速发送：前 4 Byte 是从 0 递增的包号，后 1024 Byte 是程序数据；最后一帧不足部分补零。所有程序帧提交后立刻发送系统结束帧，其 `FFFF_FFFF` 后 32 bit 是总程序帧数。

FPGA 依次返回：

- `0x44004444`：第一帧已经开始写 DDR0；
- `0x44114444`：结束帧已经收到；
- `0x44444444`：结束帧总数、连续包号、最后一帧 DMA 完成和 DMA idle 全部通过；
- `0x55000000 / 0x55010000`：hart0/hart1 首条指令提交；
- `0x550000ff / 0x550100ff`：两个 hart 到达停止标记；
- `0x55555555`：EH2 执行与 DDR1 Info 写入完成，开始回传。

### 4.4 FPGA Info 回传、复位与比较屏障

FPGA 先发送 hart0 的 1444-Byte payload Info 数据帧和 H0DN，再发送 hart1 数据帧和 H1DN。每个数据帧为 4-Byte 帧号加 60 条 24-Byte记录，最后一帧不足 60 条用全零记录补齐。WebUI 全速接收时只做轻量完整性核对并写紧凑二进制捕获，不在页面展开所有记录。

全部 Info 帧物理发送后 FPGA 发送 `0x77777777` 并进入上述全局复位流程。Windows 只有同时满足以下三项才开始比较：H0DN 和 H1DN 都收到；`0x77777777` 已收到；VM 的 Spike 日志已经结束。即使新的 `0x11111111` 已先到达，也只记录为下一轮 PRECONFIG 待处理，绝不会跨过比较屏障提前生成下一轮。

比较在 Windows 本机按 `hart + 32-bit sequence` 索引进行，核对 PC、instruction、metadata、架构写回数据，并按 WAW cancel kind/number 验证被取消记录与后续同 hart、同目标 GPR writer 的关系。Spike 在 `0x80000000` 前的启动内容不参与比较，停止 store 后 fence 之外的停驻跳转也不参与比较。

### 4.5 文件保留与下一轮

每次点击启动自动化建立一个 `webui/runlog/automation/session_*`；每个完成比较的 `session_*/run_id` 都保存：

- `spike.log.txt`：VM 中 Spike 原始可读 commit trace 的逐字节副本；
- `manifest.json`；
- `compare_report.json`；
- `comparison_result.txt`；
- `timing_report.txt`。

旧的 `spike_hart0.expected/spike_hart1.expected` 不再生成到 runlog；内部归一化流只在临时目录存在，比较结束立即删除。PASS 会删除共享目录中的程序、ELF、汇编、VM 日志及本地 `fpga_info.eh2log`，但保留上述 Spike TXT 和小型报告。FAIL 还会保留共享目录全部现场、本地紧凑 FPGA 捕获，并生成可读 `fpga_info.txt` 后停止自动化。

只有比较和对应清理全部完成，且已经收到新一轮 `0x11111111`，WebUI 才再次发送 PRECONFIG 并开始下一轮。

## 5. 阶段耗时分析

现有日志的 10k/hart 样本显示：

| 阶段 | 已观察耗时 | 说明 |
| --- | ---: | --- |
| VM 启动、生成、编译、链接至 `PROGRAM_READY` | 约 3.7 s | 单块 10k/hart、1 worker、生成器已缓存的样本 |
| VM 整轮至 `SPIKE_DONE` | 约 27.9–31.9 s | 主要耗时是 Spike 双 hart commit trace |
| 82–89 个程序数据帧全速提交 | 平均约 0.06 s | 61 个 10k 样本大多为 0.03–0.08 s |
| 782 个 20 万条程序帧提交 | 约 0.347 s | 现有一次完整样本 |
| FPGA 程序写 DDR、EH2 执行、Info 回传 | 通常早于 Spike 完成 | 旧 TXT 已按用户要求去除时间戳，无法从旧文件精确拆分 |
| Windows 比较 | 新版本逐轮精确记录 | 由 `timing_report.txt` 的 `comparison` 给出 |

新版本不再依赖无时间戳事件 TXT 推算耗时。VM `status.json` 保存 STARTING、BUILD_GENERATOR、GENERATING、COMPILING、LINKING、PROGRAM_READY、SPIKE_RUNNING 等阶段累计秒数；Windows 为每轮记录程序就绪、程序发送、`44004444/44444444`、`55555555/77777777`、双完成帧、Spike 完成、比较开始/结束和下一次 PREINIT 的单调时钟标记。页面显示主要阶段，`timing_report.txt` 保存全部秒数，不写墙上时钟时间。

## 6. 额外共享目录稳定性修复

VM 更新 `status.json` 改用进程唯一临时文件并对 HGFS `PermissionError` 做 20 次、每次 50 ms 的有界重试；若 HGFS 仍拒绝原子替换，则退化为直接写目标文件。Windows 读取端本来就会忽略一次不完整 JSON 并在下次轮询重试，因此不会再因为一次共享文件锁竞争终止整轮 riscv-dv/Spike 任务。

## 7. 已完成验证

- WebUI/Python：35 项回归测试全部通过；新增项覆盖两 hart 原子指令只能访问各自 DCCM 私有页的运行时审计。
- RTL：完整 `scripts/run_unit_sims.ps1` 回归全部通过。
- RESETTING 专项：EXE_END 最后一帧的物理完成计数人为领先 1，仍正常产生全局复位请求。
- TEMAC TX 统计专项：`tx_statistics_valid` 连续保持 1～4 拍时只按上升沿累计一帧，Gray CDC 后计数依次为 1、2、3。
- WebUI 专项：8 秒超时后以 `preserve_automation=True` 自动补发复位，不终止当前比较（测试中缩短为 10 ms 以避免延长回归时间）。
- 文件专项：runlog 中存在原始 `spike.log.txt`，不存在 `.expected` 或持久化 normalized 文件；PASS 保留 Spike TXT/报告并删除程序及 FPGA 二进制大文件。

## 8. 当前板级版本说明

按 2026-08-26 的用户要求，本次不继续重新综合、实现或生成比特流。`output/board/eh2logcomp_2slot.bit` 仍是 2026-08-25 21:30:52 的板级文件，不包含本章所述 RTL 发送计数修复；修复源码和专项仿真保留，待下一次 RTL 修改时一并综合。

在旧比特流上可先使用 WebUI 的 8 秒复位恢复看门狗：若 EXE_END 后停在 RESETTING，上位机自动发送 `0x44134445`，FPGA 原有命令路径会绕过 END 的计数相等条件并请求全局复位。该临时方案依赖 MAC RX、PHY 链路和系统信息接收路径仍能工作；若这些路径本身失效，上位机命令无法到达 FPGA，此时仍需板级硬复位。启动或重启 `webui/run.bat` 后才会加载最新看门狗代码。
