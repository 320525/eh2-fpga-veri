# EH2LOGCOMP WebUI 交付说明

完整使用说明位于同目录 `webui_full_readme.md`，一键自动化、riscv-dv/Spike 和累计比较说明位于 `webui_automation_readme.md`；两者分别与工程内 `webui/README.md`、`webui/AUTOMATION_README.md` 同步。本文给出板级交付时必须遵守的操作和协议摘要。

## 安装与启动

在 Windows 安装 Python 3.11/3.12 x64 和 Npcap，在 `webui` 目录依次执行：

```powershell
.\install.ps1
.\run.ps1
```

浏览器访问 `http://127.0.0.1:3205`。选择连接 FPGA 的物理有线网卡，不要选择 Wi-Fi 或 VMware/虚拟网卡。必须先启动监听再发送。

## 操作顺序

1. 收到 `11111111` 后发送 PRECONFIG 的一帧全 FF 加结束帧。
2. 收到 `22222222` 后等待 READY 完成；`33333333` 表示 FPGA 已进入 PROGRAM_WRITE。
3. 载入 `.bin`，核对大小、帧数、DDR 地址和 SHA-256。
4. 帧间隔设为 0，发送连续程序帧；最后一帧后 WebUI 立即发送结束帧。
5. `44444444` 表示帧数、连续性、最后 DMA 和 idle 均通过。
6. END 接收顺序为 `55555555`、hart0 数据、H0DN、hart1 数据、H1DN、`77777777`。
7. 两 hart 的帧号、sequence、padding、总数和最后 sequence 均匹配时显示 PASS。

一键自动化模式必须等上一轮 FPGA/Spike 全部日志归一化和比较完成后才允许下一轮。每轮使用新 seed，在 VM 中生成每 hart 10,000 条 RV32IMAC 随机主体、编译硬件/Spike ELF并运行 Spike；Windows 负责程序帧发送、FPGA 原始 Info 单文件保存和比较。PASS 删除该轮临时程序/日志，FAIL 保留全部文件并停机。累计比较次数保存在 `runtime/automation/comparison_stats.json`，清理页面日志不会清零。

FPGA 发送错误码时，WebUI 立即取消未提交的程序帧，不再发送普通结束帧，并向系统 MAC 发送 `44124445 + 42 Byte 0`。FPGA 收到停止确认后进行全局复位。页面另有“复位板卡”按钮：它先停止当前发送，再发送 `44134445 + 42 Byte 0`；FPGA 无论处于正常态还是错误态都会执行持续 64 个 100 MHz 周期的全局复位。

## 帧摘要

- 程序：目的 MAC `02:12:34:56:78:FF`，源 MAC `02:32:05:25:00:FE`，类型 `0x88B6`，payload 为 4-Byte 大端帧号加 1024 Byte 数据。
- 结束：目的 MAC `02:32:05:25:00:FF`，类型 `0x88B5`，payload 为 `FFFFFFFF + 总帧数 + 38 Byte 0`。
- 系统返回：广播，源 MAC `02:32:05:25:00:FF`，类型 `0x88B5`，payload 为 `代码 + 0320 + 40 Byte 0`。
- Info 数据：广播，hart0/hart1 源 MAC 为 `02:32:05:25:10:00/01`，类型 `0x88B7`，payload 固定 1444 Byte，即帧号加 60 条 24-Byte 记录。
- Info 完成：相同 hart 源 MAC，类型 `0x88B8`，46-Byte payload，包含 H0DN/H1DN、记录总数、帧总数和最后 sequence。

旧 CRC/hash package 归约结果不属于当前系统。WebUI 的比较结论仅依据最终逐指令 Info 数据和完成帧完整性。

自动化程序地址规则：程序/烧写保持 `[0x80000000,0xA0000000)`；所有随机 LSU 地址总包络是 `0xA0000000–0xFFFFFFFF`；普通 DDR 数据位于 `[0xA0000000,0xD0000000)`；AMO/LR/SC 位于 EH2 真实 64 KiB DCCM `[0xF0040000,0xF0050000)`，两 hart 使用私有原子页。数据段为 NOLOAD，不改变现有以太网烧写格式。

## 会话文件

每次开始监听都会在 `webui/runlog/session_*` 下生成独立会话。根据实际接收内容保存 `session.json`、`events.txt`、`raw_packets.pcap`、完整逐条 `decoded_info_frames.txt` 和手工 `saved_log_*.txt`。每次点击启动自动化另建 `webui/runlog/automation/session_*`，该次连续运行的各轮保存在其下 `run_*` 子目录；错误轮的FPGA解码日志为 `fpga_info.txt`，VM错误为 `vmwrong.txt`。页面不展开海量记录，点击链接即可直接打开相应 TXT。

Windows 捕获热路径直接调用 Npcap/libpcap，激活前申请 64 MiB 内核缓冲，并用 BPF 只保留系统、Info 数据和 Info 完成三类 EtherType。抓包线程仅把原始字节放入内存队列，TXT 解码和 PCAP 异步写盘由后台线程完成；页面显示 Npcap 接收数和内核/接口丢包计数。任何丢包计数非零都表示本轮主机证据不完整。

“清理当前残留日志”不会删除磁盘历史。问题复现后应先保存日志快照，并保留整个会话目录。

详细字段、WAW metadata、完成帧判定、故障定位和完整操作说明见同目录 `webui_full_readme.md` 与 `webui_automation_readme.md`。
