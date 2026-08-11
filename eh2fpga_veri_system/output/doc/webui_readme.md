# EH2 Board WebUI 使用说明

## 1. 功能和运行方式

EH2 Board WebUI 是运行在 Windows 主机上的本地 Web 应用（Local Web Application）。浏览器只负责界面显示和操作，本机 Python 后端通过 Npcap 直接收发二层以太网帧。

```text
浏览器 http://127.0.0.1:3205
       ↕ HTTP + WebSocket
Windows 本地 Python 后端
       ↕ Scapy + Npcap 原始二层以太网
有线网卡 ↔ FPGA TEMAC/RGMII
```

本工具不使用 IP、TCP 或 UDP，不需要给 FPGA 配置 IP 地址。主要功能包括：

- 枚举并选择 Windows 有线网卡；
- 在任何发送动作之前启动持续监听；
- 发送 PRECONFIG 的一帧 1024-byte 全 `FF` 程序帧及结束帧；
- 读取原始 `.bin` 程序文件，补零并拆成“4-byte 连续编号 + 1024-byte 程序数据”的固定帧；
- 连续发送全部程序帧，并在最后一帧提交后立即用同一发送句柄提交结束帧；
- 解码 FPGA 返回的系统状态和错误码；
- 解码 hart、package、count、六项归约值及所有 WAW 取消序号；
- 自动与本工程最终20万条程序的 Spike 黄金结果逐字段比较；
- 实时显示带接收时间戳的状态时间线、全部归约结果、最后一条归约及黄金比较结论；
- “清理当前残留日志”只清除页面和后台内存中的当前显示，不删除磁盘历史会话；
- “保存当前日志快照”以及持续会话记录可保留 PCAP、CSV、JSONL，便于离线检查。

WebUI 默认只监听 `127.0.0.1`，局域网中的其他电脑不能访问，不应把该控制接口直接暴露到不可信网络。

## 2. 目录结构

```text
webui/
├── app.py                         FastAPI/HTTP/WebSocket入口
├── config.json                    HTTP端口和软件限制
├── requirements.txt               Python依赖
├── install.ps1                    创建隔离环境并安装依赖
├── run.ps1 / run.bat              启动WebUI
├── eh2web/
│   ├── protocol.py                帧构造、系统码和日志帧解码
│   ├── program_image.py           原始.bin检查及镜像信息
│   ├── network.py                 Npcap监听和发送
│   ├── service.py                 状态、发送线程和黄金比较
│   ├── session.py                 PCAP/CSV/JSONL会话记录
│   └── golden.py                  归约黄金值比较
├── static/                        本地HTML/CSS/JavaScript界面
├── golden/stress_200k_system_golden.json
├── tests/test_protocol.py
└── runtime/
    ├── uploads/                   WebUI检查过的.bin及manifest
    └── sessions/session_*/        每次监听产生的会话证据
```

所有由本工具产生的文件都保存在 `webui/runtime` 下，不会写入 FPGA RTL、Vivado 输出或原程序目录。

## 3. Windows 依赖

| 依赖 | 用途 | 说明 |
| --- | --- | --- |
| Windows 10/11 x64 | 运行平台 | 当前在 Windows、Python 3.12.4 上验证 |
| Python 3.11或3.12 x64 | 本地HTTP后端 | 安装时建议勾选 Add Python to PATH |
| Npcap | 原始以太网捕获和注入 | 必须安装；推荐移除过时的 WinPcap |
| FastAPI | HTTP/WebSocket API | 由 `install.ps1` 安装 |
| Uvicorn | 本地HTTP服务器 | 由 `install.ps1` 安装 |
| Scapy | Npcap网卡枚举、抓包和发包 | 由 `install.ps1` 安装 |
| python-multipart | 浏览器上传 `.bin` | 由 `install.ps1` 安装 |

本次开发验证安装的版本为 FastAPI 0.141.1、Uvicorn 0.52.1、Scapy 2.7.0、python-multipart 0.0.32。`requirements.txt` 使用兼容范围，重新部署时会安装当时满足范围的版本。

必须使用物理有线网卡。不要选择 Wi-Fi、Bluetooth、VMware 虚拟网卡或 Microsoft Wi-Fi Direct。建议主机与 FPGA 直连，或只经过普通二层交换机。

## 4. 首次部署

### 4.1 安装 Npcap

从 Npcap 官方网站安装当前受支持版本。若安装器提供 `WinPcap API-compatible Mode`，保持启用。若 Scapy 启动时提示正在使用已废弃的 WinPcap，应卸载旧 WinPcap 并改装 Npcap。

Npcap 是 Windows 驱动，不能由普通 Python 依赖文件代替。若安装时启用了“仅管理员访问”，启动 WebUI 后首次打开网卡句柄会触发 UAC。

### 4.2 安装 Python 依赖

在 PowerShell 中进入 `webui`：

```powershell
cd D:\eh2_fpga\eh2fpga_veri_system\webui
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

脚本在 `webui/.venv` 创建独立环境，不修改系统 Python 包。若不允许执行 PowerShell 脚本，可手动执行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

### 4.3 启动

```powershell
.\run.ps1
```

也可双击 `run.bat`。服务启动后自动打开：

```text
http://127.0.0.1:3205
```

修改端口的方法：

```powershell
$env:EH2_WEB_PORT = '3210'
.\run.ps1
```

关闭运行 WebUI 的终端窗口或按 `Ctrl+C` 可停止服务。停止前应先在页面中点击“停止监听”，以便关闭 PCAP 文件。

## 5. 上板使用步骤

1. 用有线网卡直连 FPGA，确认 Windows 显示物理链路已建立。
2. 启动 WebUI，在网卡列表中选择连接 FPGA 的物理有线网卡。
3. 点击“开始监听”。必须先监听再复位/上电 FPGA，否则可能漏掉 `PREINIT_DONE`。
4. FPGA 发出 `11111111 PREINIT_DONE` 后，页面状态变为 `PRECONFIG`。
5. 点击“发送 PRECONFIG 检查帧”。工具发送一帧1024字节全 `FF`，随后立即发送结束帧。
6. PRECONFIG 期间还会依次看到 `44004444 PROGRAM_WRITE_START` 和 `44114444 RECEIVE_DONE`；等待 `22222222 SYSTEM_FUNCTION_CHECK_PASS`，然后等待 `33333333 READY`。WebUI 收到该 READY 帧时把板卡状态显示为 `PROGRAM_WRITE`，因为 FPGA 是在 READY 帧整帧发送完成后才切入正式 PROGRAM_WRITE。
7. 在“载入原始程序”中选择 `.bin`，点击“检查 .bin”。确认文件大小、SHA-256、帧数、补零量和 DDR 范围。
8. 帧间隔默认 `0 us`，即连续发送。除非板测需要限速，否则不要增加间隔。
9. 点击“发送全部程序帧”并再次确认。WebUI 对程序帧从 0 连续编号，在最后一帧后立即发送带总包数的结束帧，不等待 FPGA DMA done。
10. 只有收到 `44444444 PROGRAM_WRITE_DONE` 才能确认 FPGA 已收到结束帧，而且结束帧之前的最后一次 DMA 已完成并空闲。
11. EXECUTE 期间持续观察双 hart start/done 状态和 package 日志。`黄金比较=PASS` 表示 count、六项归约值、WAW 数量和全部 WAW 序号都与20万条程序黄金值一致。
12. 等待 `550000FF/550100FF`、`55555555 EH2_DONE` 和 `77777777 EXE_END`。`EXE_END` 物理发送完成后 FPGA 将全局复位，下一轮应重新观察 `11111111 PREINIT_DONE`，而不是立即等待第二个 READY。
13. 在“当前会话文件”中下载 PCAP、系统事件CSV、归约CSV或事件JSONL。

若 WebUI 是在 FPGA 已经进入 READY 后才启动的，页面没有收到此前状态码。确认 LED 和板卡状态无误后，可以勾选“忽略状态限制（调试）”发送；正常上板流程不要勾选。

## 6. `.bin` 程序处理规则

WebUI 只接受原始二进制 `.bin`，不接受 ELF、汇编、TXT、HEX、MEM64 或反汇编文件。

`.bin` 中第一个字节直接写入指令 DDR `0x80000000`，后续字节按文件顺序连续写入，不做任何大小端转换：

```text
frame 0 payload → 0x80000000 ... 0x800003FF
frame 1 payload → 0x80000400 ... 0x800007FF
...
```

最后不足1024字节的部分补零。软件默认最大程序大小为64 MiB，并检查补零后的地址不能越过32位地址空间。不要直接上传 `.elf`，因为 ELF 文件头和节表不是处理器要执行的原始加载镜像。

## 7. 发送帧格式

### 7.1 程序帧

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC `02:12:34:56:78:FF` |
| 6 | 6 | 固定主机源 MAC `02:32:05:25:00:FE` |
| 12 | 2 | EtherType `0x88B6` |
| 14 | 4 | 32-bit 大端序帧编号，从 0 严格连续递增 |
| 18 | 1024 | 原始程序数据；只有此字段写入 DDR |

帧总长1042字节，不含网卡生成的 preamble、SFD 和 FCS。

### 7.2 结束帧

| 偏移 | 长度 | 内容 |
| ---: | ---: | --- |
| 0 | 6 | 目的 MAC `02:32:05:25:00:FF` |
| 6 | 6 | 固定主机源 MAC `02:32:05:25:00:FE` |
| 12 | 2 | EtherType `0x88B5` |
| 14 | 4 | `FF FF FF FF` |
| 18 | 4 | 本次发送的程序帧总数，32-bit 大端序 |
| 22 | 38 | 全零 |

结束帧与程序帧目的 MAC 不同，不会进入 FPGA 程序 DMA。程序发送线程在同一个二层句柄中发送最后一个程序帧后立即提交结束帧。

## 8. 接收和解码

### 8.1 系统信息帧

系统帧源 MAC 为 `02:32:05:25:00:FF`，目的地址为广播，EtherType 为 `0x88B5`，payload 固定46字节。WebUI 同时检查固定字段 `03 20` 和后40字节全零。

| Code | WebUI显示 | 含义 |
| --- | --- | --- |
| `11111111` | PREINIT_DONE | MAC、PHY、两套MIG初始化完成 |
| `22222222` | SYSTEM_FUNCTION_CHECK_PASS | PRECONFIG双DDR检查通过 |
| `22220011/22220022` | DATA/INSTR FAIL | 数据/指令DDR检查失败 |
| `33333333` | READY | 可以发送程序 |
| `44004444` | PROGRAM_WRITE_START | PRECONFIG或正式程序的第一帧已开始写DDR |
| `44114444` | RECEIVE_DONE | 已收到结束帧，FPGA仍可能等待最后一帧DMA完成 |
| `44124445` | HOST_SEND_STOPPED | 上位机收到错误后已停止发送；该帧是上位机发给 FPGA 的确认 |
| `44444444` | PROGRAM_WRITE_DONE | 结束帧前全部程序DMA完成 |
| `44440011` | PROGRAM_WRITE_OVERTIME | 程序写入超过20秒 |
| `44440022/33/44` | PROGRAM/FIFO/DMA ERROR | 程序接收路径错误 |
| `44440055/66` | SEQUENCE/COUNT ERROR | 帧序号不连续，或结束帧总数与实际接收数不一致 |
| `55000000/55010000` | HART0/HART1 EXEC START | 对应 hart 已实际提交第一条指令 |
| `550000FF/550100FF` | HART0/HART1 EXEC DONE | 对应 hart 已进入停止状态 |
| `55555555` | EH2_DONE | 双hart执行和日志完成 |
| `66660011/12` | NONBLOCK OVERFLOW | hart0/hart1 nonblock overflow |
| `66660021/22` | TOHASH OVERFLOW | hart0/hart1 to-hash FIFO overflow |
| `66660033/44` | TX ERROR | TX MAC FIFO/日志流错误 |
| `66660051/52` | WAW OVERFLOW | hart0/hart1 WAW超过483项 |
| `66660061/62` | PACKAGE BANK CONFLICT | hart0/hart1 package bank冲突 |
| `66660071/72` | INFO FIFO OVERFLOW | 系统信息RX/TX FIFO overflow |
| `66660073/74` | RX BUFFER/LENGTH ERROR | RX缓冲或帧长错误 |
| `66660075` | MAC RX FCS ERROR | TEMAC 已检测并丢弃 FCS 错误帧 |
| `66660081/82/83` | MAC/PHY ERROR | MAC配置、PHY初始化或链路错误 |
| `66660091/92` | MIG TIMEOUT | MIG0/MIG1初始化超时 |
| `666600A1/A2` | DDR ERROR | DDR清零/检查错误 |
| `666600B1/B2/B3` | EH2/AXI ERROR | EH2初始化、IFU AXI、LSU AXI错误 |
| `666600F1` | ILLEGAL_STATE | 控制器非法状态 |
| `77777777` | EXE_END | 本轮结束；该帧物理发送完成后 FPGA 执行全局复位并从 PRECONFIG 重启 |

### 8.2 日志归约帧

日志帧源 MAC 为 `02:12:34:56:78:FF`，目的地址为广播，EtherType 为 `0x88B5`，payload 固定1024字节。WebUI 解析：

- package number；
- hart id；
- package有效指令数；
- `xor0`、`xor1`；
- `sum0`、`sum1`、`sum2`、`sum3`；
- WAW取消数量和每个16-bit序号；
- WAW之后的保留区域是否全零；
- 与内置20万条程序黄金结果的逐字段比较。

WAW最多483项。第484项会使 FPGA 进入 ERROR，不会拆分到第二个日志帧。

## 9. 会话文件

每次点击“开始监听”都会建立：

```text
webui/runtime/sessions/session_YYYYMMDD_HHMMSS_xxxxxx/
├── session.json
├── events.jsonl
├── raw_packets.pcap
├── system_events.csv
└── reduction_results.csv
```

PCAP 同时保存 WebUI 捕获的板卡返回帧和本工具提交给网卡的发送帧。CSV 使用 UTF-8 BOM，可直接用中文版 Excel 打开。

页面中每条系统信息和归约记录都带主机接收时间戳。“最后归约”窗口单独显示最后收到的 hart/package、count、WAW 数和黄金比较结果；“清理当前残留日志”不会删除上述 session 目录。“保存当前日志快照”会在当前 session 中另存可下载快照，适合在出现偶发超时、无响应或比较失败时立即保留现场。

## 10. 最终20万条程序位置

本系统闭环前仿使用的是直线展开双 hart 程序，不是来源工程早期的小循环动态压力程序。

| 文件 | 工程内位置 | 用途 |
| --- | --- | --- |
| 汇编源文件 | `programs/stress_200k_dualhart_system/stress_200k_dualhart_system.S` | 两个hart各100,000条直线指令，hart0含CSR 0x7FC启动hart1 |
| 链接脚本 | `programs/stress_200k_dualhart_system/link.ld` | 复位/加载地址0x80000000 |
| 最终ELF | `programs/stress_200k_dualhart_system/build/stress_200k_dualhart_system.elf` | 反汇编和调试，不可直接上传 |
| **上板应上传的BIN** | **`programs/stress_200k_dualhart_system/build/stress_200k_dualhart_system.bin`** | WebUI程序输入 |
| **交付目录BIN副本** | **`output/board/stress_200k_dualhart_system.bin`** | 与上项 SHA-256 完全相同，便于随 bitstream 一起取用 |
| 反汇编 | `programs/stress_200k_dualhart_system/build/stress_200k_dualhart_system.dis` | 检查指令和地址 |
| 前仿程序帧镜像 | `programs/stress_200k_dualhart_system/build/stress_200k_program_frames.bin` | 782帧逐字节参考 |
| 帧清单 | `programs/stress_200k_dualhart_system/build/image_manifest.json` | 字节数、帧数、MAC和地址 |

绝对路径：

```text
D:\eh2_fpga\eh2fpga_veri_system\programs\stress_200k_dualhart_system\build\stress_200k_dualhart_system.bin
```

程序信息：

```text
原始程序字节       800640
补零后payload      800768
程序帧数           782
末帧补零           128 byte
写入起始地址       0x80000000
补零后末地址       0x800C37FF
BIN SHA-256         5D073F32602F986E6AE253F425046271C4255402067632DA7C6FFD43E4A1CCFC
782帧镜像SHA-256   D5E6E51284CAF9AAC26EFE3A846F5694405F07144B4F9A4516874DDAEB7E73AE
```

选择该 `.bin` 后，页面会显示“SHA-256匹配”。

## 11. Spike运行结果和上板黄金值

本程序正确的 Spike 黄金文件是：

```text
artifacts/sim/spike_straight_200k_golden.json
```

逐条EH2/Spike比较结果是：

```text
artifacts/sim/eh2_spike_straight_200k_compare.json
status              PASS
EH2 count           200044
Spike count         200044
exact matches       200011
accepted WAW zero   33
mismatches          0
```

整机RGMII发送帧验证结果是：

```text
artifacts/sim/full_system_frame_verify.json
status              PASS
system frame count  15
log frame count     4
errors              0
```

Spike/整机日志黄金值：

| hart | package | count | WAW | xor0 | xor1 | sum0 | sum1 | sum2 | sum3 |
| ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- | --- |
| 0 | 0 | 65536 | 4 | `d31849f405d7893f` | `f362cffb3bd01126` | `40883202d86e0925` | `c155b99763889958` | `f97364871915ade9` | `7ec3152548d669c5` |
| 0 | 1 | 34487 | 0 | `ca29af3d5afed2de` | `dab2dbaec7cf9013` | `304dcd82a6df56f4` | `594544d87138de09` | `c90918dde2a98436` | `86df023d8dec6168` |
| 1 | 0 | 65536 | 128 | `bb84a72d88908184` | `77ae970cea8f03ee` | `f0ba1c03f647a3d4` | `07d2e3a5867b2f14` | `fec9fec6bbd4da0b` | `f9fc10899b8299e5` |
| 1 | 1 | 34485 | 0 | `b2c8ba18b57bb719` | `1d356092b1daae53` | `2f710fa64e36788d` | `ee452c2062e1d3ad` | `d772ad1beae8bdf4` | `cfaf9594c587af03` |

hart0提交数为100023，hart1提交数为100021，总数200044。hart0/package0 的 WAW 序号为 `[18,20,26,28]`；hart1/package0 为 128 条，完整列表保存在 `webui/golden/stress_200k_system_golden.json`；两个 package1 均为0。逐条 ISS 比较里的 `accepted WAW zero=33` 只是“EH2 将结果清零而 Spike 保留原结果”的对比例外数，不能用作日志 WAW 总数。WebUI 同时比较 WAW 数量和完整序号列表。

`artifacts/sim/spike_stress_200k_csr_golden.json` 属于更早的小循环压力程序，其提交数和归约值不同，**不能用于当前上板直线型20万条程序比较**。WebUI 内置的是上述 `spike_straight_200k_golden.json` 对应结果。

## 12. 已完成的软件验证

当前版本完成了以下检查：

- Python源码编译检查通过；
- 9项协议/镜像单元测试通过；
- 当前800640-byte `.bin` 生成782帧；
- 生成帧与前仿 `stress_200k_program_frames.bin` 逐字节完全一致；
- 程序帧、末帧补零和结束帧字段通过；
- 系统信息码和日志字段解码通过；
- WAW序号解码及黄金值PASS/FAIL检查通过；
- HTTP首页、状态、网卡、黄金结果和 `.bin` 上传接口通过；
- 当前 Windows 主机成功枚举6个网卡，pcap provider可用；
- Realtek物理有线网卡的监听启动/停止测试通过。

尚未执行的是使用真实 FPGA 对该WebUI进行最终双向上板回归。上板时应保存完整会话，并将四个日志帧与第11节逐字段比较。

## 13. 限制和注意事项

- 当前 FPGA 程序协议有32-bit连续帧序号和结束帧总包数，但没有逐帧ACK或整镜像CRC。主机完成发送不等于板卡完成写入，必须等待 `PROGRAM_WRITE_DONE`。
- FPGA 从首次程序 AXI 写入开始计算20秒超时。不要设置导致总发送时间接近20秒的帧间隔。
- 正常流程不要点击“只发送结束帧”，也不要勾选“忽略状态限制”。
- 标准网卡会自行添加FCS，WebUI不应在发送数据中添加FCS。
- 网卡或驱动通常会从接收数据中剥离FCS；解码器同时兼容捕获中保留4字节FCS的情况。
- Npcap/网卡驱动可能存在内核捕获丢包；当前界面统计应用实际收到的帧，不能证明内核从未丢包。上板关键运行应同时保存PCAP，必要时用Wireshark复核。
- 建议关闭所用有线网卡的节能以太网（EEE）和“允许计算机关闭此设备以节约电源”。不要在程序发送期间切换网卡、休眠或拔线。
- WebUI 使用固定主机源 MAC `02:32:05:25:00:FE`。某些企业交换机具有端口安全策略，可能丢弃非网卡固有源MAC，因此推荐直连 FPGA。
- 监听过滤 EtherType `0x88B5`；发送的程序帧由应用主动记录到PCAP，不依赖抓回自身的 `0x88B6` 帧。
