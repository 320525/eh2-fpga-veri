# EH2LOGCOMP WebUI 使用说明

双 hart riscv-dv/Spike 一键自动化的环境、状态流程、文件格式、WAW 比较规则、清理屏障和验证结果详见 [AUTOMATION_README.md](AUTOMATION_README.md)。当前默认规模为每 hart 10,000 条随机 RV32IMAC 指令。

## 1. 功能

该 WebUI 是运行在 Windows 主机上的本地程序烧写和板级日志工具。浏览器负责界面，本机 Python 后端通过 Npcap 直接收发二层以太网帧，不使用 IP、UDP 或 TCP。Windows 接收热路径直接调用 libpcap/Npcap，不在抓包回调中构造 Scapy Packet 对象；Scapy 仅保留为非 Windows 兼容后端和辅助解析依赖。

当前版本对应 `eh2logcomp` 逐指令 Info Struct 协议，主要功能包括：

- 枚举并选择与 FPGA 连接的物理有线网卡；
- 在发包前持续监听系统帧、双 hart Info 数据帧和完成帧；
- PRECONFIG 发送一帧 1024-Byte 全 FF 程序数据及结束帧；
- 检查原始 `.bin`，补零并拆成连续编号的程序帧；
- 用同一二层 socket 连续发送程序帧，并在最后一帧之后立即提交结束帧；
- 实时显示系统码、时间戳、板卡状态、逐指令 Info 记录和双 hart 完整性结果；
- 检查每个 hart 的帧号、sequence、metadata hart、尾部补零、记录总数、总帧数和最后 sequence；
- FPGA 报错时立即停止尚未发送的程序帧，并回送 `0x44124445`；
- 保存原始 PCAP、可直接打开的逐条 TXT 日志和手工 TXT 快照；清理页面日志时不删除磁盘历史。

旧 CRC/hash package 归约值不属于本工程输出。手工模式的 PASS/FAIL 只核对 Info 数据流和 H0DN/H1DN 完成帧；一键自动化模式会另外运行 Spike，并在 Windows 严格比较逐指令 Info Struct。

## 2. 安装和启动

要求 Windows 10/11 x64、Python 3.11/3.12 x64、Npcap 和物理有线网卡。不要选择 Wi-Fi、VMware 虚拟网卡、Bluetooth 或 Microsoft Wi-Fi Direct。

首次使用，在 PowerShell 中进入 `webui`：

```powershell
.\install.ps1
```

Npcap 是独立驱动，必须先在 Windows 安装；`install.ps1` 只安装 Python 环境和 `requirements.txt`。随后启动：

```powershell
.\run.ps1
```

也可以直接双击 `run.bat`。启动器会先安全结束由本工程同一虚拟环境启动的旧 WebUI
进程，再启动当前目录中的 `app.py`。首页、JavaScript 和 CSS 使用统一的启动版本号并
返回 `no-store`，因此每次点击 `run.bat` 打开的都是磁盘上的最新页面，不需要手动清理
浏览器缓存，也不会出现旧 HTML 与新 JavaScript 控件不匹配的问题。

浏览器访问：

```text
http://127.0.0.1:3205
```

默认只监听本机回环地址。端口和最大程序大小在 `config.json` 配置，当前最大程序为 512 MiB。

## 3. 正常使用顺序

1. 给 FPGA 上电或硬复位，等待 PHY 链路稳定。
2. 在 WebUI 选择与 FPGA 直连的有线网卡，点击“开始监听”。必须先监听再发送，否则可能漏掉 FPGA 立即返回的系统帧。
3. 收到 `11111111 PREINIT_DONE` 后点击“发送 PRECONFIG 检查帧”。WebUI 发送 sequence 0 的一帧全 FF 数据及声明总数 1 的结束帧。
4. 正常应收到 `44004444`、`44114444`、`22222222`，随后 READY 清零 DDR0；收到 `33333333` 时，硬件已经处于 PROGRAM_WRITE，而不是仍处于 READY。
5. 选择 `.bin` 并点击检查。页面显示原始大小、补零、帧数、DDR 地址范围和 SHA-256。
6. 点击“发送全部程序帧”。正常使用保持帧间隔为 0，以协议允许的最高软件提交速率发送。只有定位主机或网卡问题时才增加间隔。
7. WebUI 在最后一个程序数据帧提交后，使用同一发送 socket 立即发送结束帧，不等待 FPGA DMA done。
8. FPGA 内部核对结束帧总数、帧号连续性、最后一帧 DMA 完成和 DMA idle，成功后发送 `44444444` 并执行双 hart。
9. END 阶段依次接收：`55555555`、hart0 Info 数据、H0DN、hart1 Info 数据、H1DN、`77777777`。双 hart 完成帧都与主机实际接收结果一致时显示 PASS。
10. `77777777` 物理发送完成后 FPGA 全局复位，重新进入 PRECONFIG。

“忽略状态限制”仅用于调试。强制在错误状态或错误阶段发送程序可能让结束帧计数失配，正常运行不要勾选。“只发送结束帧”同样只用于明确的协议定位。

## 4. 主机发送帧

### 4.1 程序数据帧

| 字段 | 内容 |
| --- | --- |
| 目的 MAC | `02:12:34:56:78:FF` |
| 源 MAC | `02:32:05:25:00:FE` |
| EtherType | `0x88B6` |
| Payload | 4-Byte 大端帧号 + 1024-Byte 程序数据 |

帧号从 0 连续递增。最后一帧不足 1024 Byte 时仅在末尾补零。FPGA 把后 1024 Byte 写入 DDR0 `0x80000000 + frame_number*1024`，4-Byte 帧号不写入 DDR。

20 万条测试镜像为 800640 Byte，补为 800768 Byte，共 782 帧，SHA-256 为：

```text
5D073F32602F986E6AE253F425046271C4255402067632DA7C6FFD43E4A1CCFC
```

### 4.2 结束帧

| 字段 | 内容 |
| --- | --- |
| 目的 MAC | `02:32:05:25:00:FF` |
| 源 MAC | `02:32:05:25:00:FE` |
| EtherType | `0x88B5` |
| Payload | `FFFFFFFF` + 4-Byte 大端总程序帧数 + 38 Byte 0 |

结束帧与程序帧使用不同目的 MAC，所以分类器不会把系统帧的 46-Byte payload 送入固定 1024-Byte 程序 DMA。

### 4.3 主机停止确认

FPGA 发出任何错误码后，WebUI 设置发送取消事件。发送线程在当前帧边界停止、关闭批量发送 socket，不再发普通结束帧；随后通过串行化的发送锁发出：

```text
目的 MAC 02:32:05:25:00:FF
源 MAC   02:32:05:25:00:FE
类型     0x88B5
Payload  44124445 + 42 Byte 0
```

FPGA 收到该确认后执行 64 个 100 MHz 控制周期的全局复位。若 PC 的监听或网卡已经关闭，停止确认无法发出，板卡会保持 ERROR，需恢复连接或进行硬复位。

## 5. FPGA 返回帧

### 5.1 系统信息帧

目的 MAC 为广播，源 MAC 为 `02:32:05:25:00:FF`，EtherType 为 `0x88B5`，payload 固定 46 Byte：

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 4 | 系统状态或错误代码 |
| 4 | 2 | 固定 `03 20` |
| 6 | 40 | 全 0 |

WebUI 会校验固定字段、显示实际接收时间、名称、状态和说明。常用流程码：

| 代码 | 含义 |
| --- | --- |
| `11111111` | MAC、PHY、MIG 完成初始化，等待 PRECONFIG 检查帧 |
| `22222222` | PRECONFIG 的 DDR0/DDR1 功能检查通过 |
| `33333333` | READY 流程完成，FPGA 已进入 PROGRAM_WRITE |
| `44004444` | 第一帧程序开始写 DDR，20 秒 watchdog 开始 |
| `44114444` | FPGA 收到主机结束帧 |
| `44444444` | 帧数/连续性/DMA/idle 全部核对通过，进入 EXECUTE |
| `55000000/55010000` | hart0/hart1 首条指令提交 |
| `550000FF/550100FF` | hart0/hart1 到达执行结束标志 |
| `55555555` | 双 hart 执行完成，进入 END 并开始 Info 回传 |
| `77777777` | Info 回传完成，即将全局复位 |

错误码和具体含义在页面及 `output/doc/README.md` 中显示。程序帧序号错误、总数错误、FCS 错误、FIFO 溢出、DMA/AXI 错误和 Info/WAW 配对错误都会使板卡进入 ERROR。

### 5.2 Info 数据帧

| 字段 | hart0 | hart1 |
| --- | --- | --- |
| 目的 MAC | 广播 | 广播 |
| 源 MAC | `02:32:05:25:10:00` | `02:32:05:25:10:01` |
| EtherType | `0x88B7` | `0x88B7` |
| Payload | 1444 Byte | 1444 Byte |

payload 为 4-Byte 大端帧号加 60 条 24-Byte Info Struct。最后一帧不足 60 条时只允许尾部连续补零。每个 hart 的帧号和 sequence 都分别从 0 开始。

每条网络 Info Struct：

| 偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 4 | `sequence_id` |
| 4 | 4 | `pc` |
| 8 | 4 | `instruction` |
| 12 | 4 | `metadata` |
| 16 | 4 | `data` |
| 20 | 4 | `waw_cancel_number` |

`metadata[31:30]` 为 WAW kind：0 无取消，1 direct，2 nonblock load，3 nonblock divide；bit16 为 hart；bit15:14 为 privilege；bit13:12 为 event type；bit11:0 为寄存器号。`waw_cancel_number` 表示哪条较新的同 hart sequence 取消了当前 victim 的架构写回。

DDR1 中每条记录实际为 32 Byte，网络只发送其中高 24 Byte，低 8 Byte 保留区不发送。

### 5.3 H0DN/H1DN 完成帧

源 MAC 仍按 hart 区分，EtherType 为 `0x88B8`，payload 为 46 Byte：

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 4 | ASCII `H0DN` 或 `H1DN` |
| 4 | 1 | hart id |
| 5 | 1 | 版本 1 |
| 6 | 2 | 记录大小 24 |
| 8 | 4 | 总有效记录数 |
| 12 | 4 | 总数据帧数 |
| 16 | 4 | 最后 sequence；无记录为 `FFFFFFFF` |
| 20 | 3 | 0 |
| 23 | 1 | 对端 hart 标记 |
| 24 | 22 | 0 |

主机只有在以下条件全部满足时才把该 hart 显示为 PASS：协议字段合法、数据帧号连续、sequence 连续、metadata hart 一致、补零只位于末尾、声明帧数等于实收帧数、声明记录数等于实收记录数、最后 sequence 一致。两个 hart 都 PASS 时总结果才为 PASS。

## 6. 日志文件与页面时间

每次点击“开始监听”会建立独立目录：

```text
webui/runlog/session_YYYYMMDD_HHMMSS_xxxxxx/
```

按实际发生情况生成：

| 文件 | 内容 |
| --- | --- |
| `session.json` | 会话开始时间和所选网卡 |
| `events.txt` | UI/发送/接收事件；TXT 内容不保存时间字段 |
| `raw_packets.pcap` | WebUI 接受的返回帧及本工具提交的发送帧 |
| `system_messages.txt` | 当前监听会话最近 100 条系统信息，新消息自动淘汰最早一条，不含时间戳 |
| `error_codes.txt` | 当前监听会话的全部有效 FPGA 错误码，独立追加且不受 100 条限制，不含时间戳 |
| `decoded_info_frames.txt` | Info 数据帧、每条有效 Info Struct、padding 和 H0DN/H1DN 核对结果；不再混入系统帧，不含时间戳 |
| `saved_log_*.txt` | 用户点击“保存当前日志快照”时的页面/后台快照；递归移除时间字段 |
| `comparison_result.txt` | 自动化比较结果；FAIL 时明确记录首条错误的 hart、sequence、原因和已比较指令数 |

“清理当前残留日志”只清空页面和后台内存中的当前显示/比较计数，不删除磁盘文件；需要保留问题现场时应先点击“保存当前日志快照”，再清理或复位。

“清理历史运行缓存”只删除旧 `session_*`、Windows/共享目录中的 `run_*` 和未使用的上传缓存。正在执行的自动化轮次、当前监听会话和正在发送程序所需的缓存会被保留。每个删除目标都校验精确父目录与名称前缀，不会删除 `runlog`、`runtime` 或共享根目录，清理后可直接开始后续运行。

实际目录为 `webui/runlog/session_YYYYMMDD_HHMMSS_xxxxxx/`；每次点击“启动一键自动化”会创建 `webui/runlog/automation/session_YYYYMMDD_HHMMSS_xxxxxx/`，同一次连续自动化的每轮随机执行分别保存在其下的 `run_*` 子目录。手工模式继续提供 `decoded_info_frames.txt`；自动化运行中只写紧凑 `fpga_info.eh2log` 供快速比较，PASS 后删除，只有 FAIL 才生成并提供可直接打开的 `fpga_info.txt`。

页面本身仍显示事件到达时间，方便观察状态转换，但系统信息表只保留最近 100 条，时间不会写进用户要求保留的 TXT 内容。自动化区域的“当前已执行 / 已比较指令”左值为本轮已收到的非 padding FPGA Info 记录数，右值为本轮完成 Spike/FPGA 核对的记录数；“本次累计已比较指令”从每次点击自动化按钮时的 0 开始，累加该次连续运行内所有已完成轮次。比较失败时页面和 `comparison_result.txt` 同时显示首条错误的 `hart + sequence`。

自动化的 riscv-dv生成、汇编改写、编译、链接和Spike执行都在虚拟机本地 `/tmp` 工作目录完成。成功后才向 share 顺序发布 `program.bin`、`manifest.json`、`spike.log` 和状态文件，Windows随后烧写和比较；不会把大量汇编、对象、ELF及编译日志逐条写入HGFS。自动化 `runlog/automation/session_*/run_*` 也是单轮临时工作目录。归一化二进制只存在于比较临时目录。比较 PASS 后，先把累计计数和轻量PASS摘要写入 `runtime/automation`，再删除整个本地 `run_*` 目录及共享目录对应的程序、汇编、目标文件、ELF、Spike日志、FPGA二进制捕获、manifest、比较报告和耗时文件；随后才允许下一轮。只有比较FAIL、Info回传缺失、VM失败或用户手动停止时，才保留该轮 `run_*` 及其错误现场；VM失败时还会把虚拟机本地构建目录复制为 `vm_failure_artifacts` 供定位。每个 `session_*` 根目录仍保留不含SSH密码的 `automation_session.json`，记录该次按钮启动使用的配置。

Windows 抓包在激活网卡前把 Npcap 内核缓冲设为 64 MiB，并用 BPF 只接收 `0x88B5/0x88B7/0x88B8`。抓包线程只复制原始字节到无界接收队列；自动化热路径只做协议完整性检查和紧凑二进制顺序写入，不逐条生成 TXT，也不写自动化 PCAP；失败后才离线解码 TXT。页面显示 Npcap 接收数、内核丢包数和接口丢包数。这样可承接 FPGA 在约 40 ms 内连续返回约 4.86 MiB、3336 个大帧的突发；若 `kernel drops` 非零，该轮主机日志必须判为不完整，不能据此判断 FPGA 停在 END。

“复位板卡”按钮先取消并等待当前程序发送线程退出，再发送系统命令 `0x44134445`。FPGA 将全局复位保持 64 个 100 MHz 控制周期，随后重新从 PRECONFIG 发出 `0x11111111`。复位命令与程序 MAC/EtherType 分离，不会进入程序 FIFO 或污染 DDR 烧写路径。

## 7. 常见问题

- **收不到帧**：确认选择物理有线网卡、Npcap 可用、网卡未被虚拟交换机占用、PHY link 已建立。
- **收到 `33333333` 后界面状态错误**：该码应显示 PROGRAM_WRITE；如果不是，请确认使用的是本目录的最新 WebUI。
- **程序发送超时**：检查系统事件中的 FCS、frame sequence、frame count、RX FIFO 和 DMA 错误；保存 PCAP 后对照最后成功帧号。
- **Info 总结果 FAIL**：打开当前会话的 `decoded_info_frames.txt`，查看哪个 hart 的 frame/sequence 连续性失败，再比较 HxDN 声明值。
- **最后一帧记录数异常**：只有最后一帧可有尾部全零 padding；有效记录后出现零洞或零后重新出现有效记录均判错。
- **页面很久后变慢**：页面不展开逐条记录，完整记录在 TXT；可先保存快照再清理当前显示。
- **错误后板卡不复位**：检查 WebUI 是否仍在监听且成功发送 `44124445`；若停止确认发送失败，只能恢复网卡后重发或硬复位。

## 8. 软件验证

当前 36 项 WebUI 回归测试覆盖 782 个程序帧镜像、结束帧、停止确认、系统状态、1444-Byte Info 数据帧、24-Byte 记录、WAW 字段、H0DN/H1DN、首错 sequence、自动化显示计数归零、累计比较指令、最近 100 条系统信息、独立错误码 TXT、Spike 原始 TXT、PASS/FAIL 文件保留策略、安全缓存清理、复位恢复看门狗、停止 store 后的 fence 顺序、原子地址运行时审计、VM失败轮次自动跳过/复位，以及模拟接收 hart0 100023 条、hart1 100021 条记录（各 1668 帧）的完整 PASS 流程。

若虚拟机的 `status.json` 报告 `stage=FAILED`，该轮不进入FPGA执行和系统比较，也不增加PASS/FAIL或已比较指令计数。WebUI把完整远端状态及 `remote_runner_console.log` 保存到本轮 `vmwrong.txt`，同时把摘要追加到 `runlog/automation/_wrong.txt`，然后发送 `0x44134445` 全局复位命令并自动跳到下一轮。若系统比较明确报告 `Info frame number discontinuity`、Info完成帧声明计数大于实收计数，或sequence覆盖存在缺口，也视为Info回传传输缺失：本轮解码TXT和比较现场保留，错误追加到同一个 `_wrong.txt`，全局复位后继续下一轮。PC/指令/架构数据/WAW内容不一致仍是终止性FAIL，绝不会被自动跳过。新的 `0x11111111` 到达前，旧轮次残留状态不会释放下一轮屏障；收到新PREINIT后自动执行PRECONFIG并开始下一随机轮次。

自动化生成的程序仍从 DDR0 `0x80000000` 烧写和执行，全部随机 LSU 访问被限制在 `0xA0000000–0xFFFFFFFF`：普通 load/store、栈和 NOLOAD 数据使用 DDR0 `[0xA0000000,0xD0000000)`；EH2 仅允许在 DCCM 中执行的 AMO/LR/SC 严格使用真实 64 KiB DCCM `[0xF0040000,0xF0050000)`，且两个 hart 各用独立 64-Byte 原子页。链接器、Spike 的 `-m` 内存窗口和 Spike commit 日志运行时审计共同保证每个 AMO/LR/SC 的地址都位于相应 hart 私有页。数据段为 NOLOAD，依赖 READY 已完成的 DDR0 清零；hart0 在启动 hart1 前显式清零 DCCM 原子页，因此这些数据不进入以太网烧写镜像。详细地址选择与真实验证结果见 [AUTOMATION_README.md](AUTOMATION_README.md)。

自动化页面显示本次启动后的系统比较总次数、PASS次数、FAIL次数和累计比较指令数，每次点击启动都从0开始；同一次自动循环内逐轮累计。历史总轮次仍保存在 `runtime/automation/comparison_stats.json`，但不再显示在该摘要行。
