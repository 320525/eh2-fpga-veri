# EH2LOGCOMP 双 hart 一键自动化验证环境

## 1. 目标与运行位置

本环境在保留原 WebUI 手工烧写、状态监视、日志保存和错误应答功能的基础上，增加“一键自动化”循环：

1. 等待 FPGA 状态机到达相应阶段；
2. 通过 SSH 在虚拟机中用 riscv-dv 生成一份新的 RV32IMAC 双 hart 程序；
3. 生成硬件执行镜像与 Spike 参考镜像；
4. Windows WebUI 通过物理以太网口把硬件镜像烧写到 FPGA；
5. 虚拟机同时运行 Spike 并生成提交日志；
6. Windows 将 FPGA 返回的所有 Info 数据帧和完成帧保存到一个文件；
7. Windows 流式比较 FPGA Info 与 Spike 日志；
8. PASS 时保留 Spike 原始 TXT 与比较/耗时报告并清理程序和 FPGA 二进制大文件；FAIL 时保留全部现场并停止。最新细节见 `automation_timing_reset_recovery_readme.md`。

组件位置如下：

| 组件 | 位置 |
| --- | --- |
| WebUI、Npcap 收发、比较器 | Windows：`D:\eh2_fpga\eh2logcomp\webui` |
| riscv-dv | VM：`/home/mtw/riscv-dv` |
| Spike | VM：`/usr/bin/spike` |
| VCS 生成器缓存 | VM：`/home/mtw/.cache/eh2logcomp_automation` |
| VM 与 Windows 共享文件 | Windows：`D:\share\comp_log_dvspike`；VM：`/mnt/hgfs/share/comp_log_dvspike` |

WebUI 仍在 Windows 运行。虚拟机不直接操作 FPGA 网卡；只有程序生成、编译和 Spike 参考运行在虚拟机中。比较发生在 Windows。

## 2. 当前默认测试规模与加速方法

默认参数为：

- 每 hart 随机指令主体：`10,000` 条；
- 每块指令数：`10,000`；
- 块数：1；
- 生成 worker：1（只有一个块，增加 worker 不会更快）；
- ISA：RV32IMAC；
- hart 数：2；
- 每轮使用新的 31-bit 随机 seed。

“每 hart 10,000 条”指 riscv-dv 随机主体。双 hart 启动、栈/原子操作预置、WAW 压力指令以及结束标记属于系统包络，因此实际可比较提交会多约 28～29 条。一次真实验证中 hart0 为 10,029 条、hart1 为 10,028 条。

为了缩短时间且让静态生成的约 10,000 条指令都能执行，随机主体使用：

- `+no_branch_jump=1`：不在随机主体中插入随机条件分支、`jal/jalr` 或压缩跳转；
- `+num_of_sub_program=0`：不生成额外随机子程序；
- `+no_csr_instr=1`、`+no_fence=1`：去掉当前比较不需要的随机 CSR/fence；
- 保留 I/M/A/C 的整数、乘除、访存、原子和压缩指令；
- 启动、hart 分派、跳入主体和结束路径中的确定性跳转仍然保留。

VCS riscv-dv 生成器只在首次使用或缓存丢失时编译，后续轮次直接复用 `vcs_simv`。程序镜像一生成完就允许 WebUI 烧写，同时 Spike 并行执行，不等待 Spike 日志结束才发送程序。自动化发送的帧间隔固定为 0；发送时不再同步复制每个程序帧到 PCAP，避免主机磁盘 I/O 拉长烧写时间。

## 3. 一键自动化状态流程

启动 WebUI 后先选择与 FPGA 直连的物理有线网卡并启动监听，然后点击“一键自动化”。密码只保留在当前 Python 进程内存中，不写入配置、状态 JSON 或浏览器返回数据。

### 3.1 从 PRECONFIG 开始

1. FPGA 发送 `0x11111111 PREINIT_DONE`。
2. WebUI 自动发送一帧 sequence=0、1024 Byte 全 `FF` 的程序帧，并紧接发送声明总包数为 1 的结束帧。
3. FPGA 使用正式程序烧写的“帧号—最后一帧 DMA 完成—结束帧”路径检查指令 DDR，并由原有 ATG 检查数据 DDR。
4. FPGA 发送 `0x22222222 SYSTEM_FUNCTION_CHECK_PASS`。WebUI 此时通过 SSH 启动本轮 riscv-dv 生成；FPGA 继续执行 READY 内部流程。
5. FPGA 完成 READY 中的全部工作并发送 `0x33333333 READY` 后，硬件已经进入 PROGRAM_WRITE。WebUI 将该一次性烧写许可锁存。
6. 只有“已收到 33333333”与“VM 已产生 program.bin”同时成立时，WebUI 才发送程序。

如果点击自动化按钮时最后状态已经是 `0x22222222`，WebUI 直接开始生成；如果已经是 `0x33333333`，则同时锁存烧写许可并开始生成，镜像就绪后立即发送。这样不会因错过前一条状态帧而无响应。

### 3.2 程序烧写与参考运行

`program.bin` 被按 1024 Byte 拆分。每个 `0x88B6` 数据帧 payload 为：

| 偏移 | 长度 | 含义 |
| ---: | ---: | --- |
| 0 | 4 | 大端连续帧号，从 0 开始 |
| 4 | 1024 | 程序数据；最后一帧末尾补 0 |

所有程序帧由同一个 Npcap L2 socket 连续发送，最后一帧提交后立即用同一发送序列提交 `0x88B5` 结束帧。结束帧中的 `FFFFFFFF` 后跟 32-bit 大端总程序包数。上位机不等待 FPGA DMA done 后才发结束帧；FPGA 负责等待结束帧到达前的最后一笔程序 DMA 真正完成。

VM 为同一份随机程序生成两个地址一致的 ELF：

- `program_hardware.elf`/`program.bin`：hart0 执行 `csrw 0x7FC,t6` 启动 hart1；两个 hart 最后向 `0xD0580000` 写 `0x00320525`；
- `program_spike.elf`：相同 PC 上用 NOP 替代 EH2 私有启动 CSR 和硬件停止 store；Spike 用 `-p2 --isa=RV32IMAC` 启动两个 hart，并在两者都到达停止点后写 tohost 退出。

`manifest.json` 保存三处补丁 PC 及硬件指令字。Windows 比较器读取 Spike 日志时把这些 PC 恢复为 FPGA 实际看到的指令和事件，因此无需让 Spike 理解 EH2 私有 CSR，也不会把硬件停止 store 之后的 Spike 尾部当成 FPGA 记录。

### 3.3 Info 回传、比较与下一轮屏障

FPGA 在 END 阶段依次回传 hart0、hart1 的 Info 数据流和两个完成帧。自动化模式把每一帧 `0x88B7` Info DATA 和 `0x88B8` Info DONE 的原始以太网字节写入本轮唯一文件：

```text
webui/runtime/automation/runs/<run_id>/fpga_info.eh2log
```

比较必须同时满足：

- 已收到 H0DN；
- 已收到 H1DN；
- 已收到 `0x77777777 EXE_END`；
- VM `status.json` 已标记 `spike_done=true`。

随后 Windows 才关闭日志文件并启动比较。比较和 PASS 清理全部完成之前，后续收到的 `0x11111111` 只被记为 pending；额外的 `0x22222222` 被屏障拒绝，不会创建第二个并发轮次。PASS 清理完成后才释放下一轮；如果 pending 的 PREINIT 已经到达，就立即发送下一轮 PRECONFIG 检查帧。

## 4. 单文件 FPGA 日志格式

`fpga_info.eh2log` 为二进制、可顺序读取的自描述容器：

1. 文件头：`<8sI` 小端结构，8 Byte magic=`EH2LGF1\0`，32-bit version=1；
2. 每帧头：`<QH`，64-bit Windows 接收时间戳（ns）和 16-bit 原始帧长度；
3. 紧跟原始以太网帧。若 Npcap 提供 FCS，FCS 原样保留；比较时按协议长度识别并剥离。

写入器使用 8 MiB 用户缓冲，Npcap 回调只复制帧并入队；协议检查、磁盘写入和界面事件在后台接收线程完成。自动化 Info 快速路径不为每个数据帧创建 60 个 Python 字典，也不同时写 CSV/PCAP，因此不会因 GUI 日志开销阻塞抓包。

## 5. 比较规则

Spike 原始提交日志先按 hart 分流为固定 16 Byte 的期望记录：PC、instruction、metadata、data。FPGA 每条线上记录为 24 Byte：

| 偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 4 | 本 hart 独立递增的 sequence |
| 4 | 4 | PC |
| 8 | 4 | instruction |
| 12 | 4 | metadata |
| 16 | 4 | data |
| 20 | 4 | waw_cancel_number |

普通记录严格比较 hart、sequence、PC、指令、privilege、事件类型、寄存器号和 data。帧号必须从 0 连续，记录 sequence 必须从 0 连续，padding 只能出现在最后一个数据帧末尾，H0DN/H1DN 声明的记录数、数据帧数和最后 sequence 必须与实际接收一致。

WAW victim 的规则为：

- `waw_cancel_kind` 为 1/2/3；
- FPGA victim 的 `data` 必须为 0；
- victim 的 Spike data 不比较；
- `waw_cancel_number` 必须大于 victim sequence，且小于同 hart 的最终记录数；
- 该 sequence 对应的 Spike 记录必须是后续同 hart、同一个 GPR 的写者；
- 禁止跨 hart 使用 cancel number。

首个不匹配会写入 `compare_report.json`，包括首个失败 hart、sequence、原因和相关字段。FAIL 后不继续发起下一轮。

## 6. 文件生命周期

VM/共享目录每轮为：

```text
D:\share\comp_log_dvspike\runs\<run_id>\
  riscvdv\rdv_0.S
  chunks\chunk_0000.S
  objects\chunk_0000.o
  hardware_harness.S
  spike_harness.S
  program_hardware.elf
  program_spike.elf
  program.bin
  spike.log
  manifest.json
  status.json
  各阶段日志
```

Windows 本地轮次目录保存 `fpga_info.eh2log`、归一化 Spike 文件和 `compare_report.json`。

- PASS：先将小型摘要追加到 `runtime/automation/pass_history.jsonl`，然后只删除当前 run_id 对应的 Windows 本地轮次目录和共享轮次目录；清理成功后才允许下一轮。
- FAIL：保留程序、源代码、ELF、Spike 日志、FPGA 单文件日志、manifest、状态和比较报告，并停止自动化。
- 用户点击停止：向 VM 写 `cancel.request`，关闭当前 FPGA 日志，保留全部现场。

目录删除前会校验父目录，只允许删除精确的 `<runs>/<run_id>`，不会删除共享根、WebUI runtime 根或其他测试结果。

## 7. FPGA 错误时的行为

收到 `0x222200xx`、`0x444400xx` 或 `0x666600xx` 后：

1. Windows 立即置程序发送 cancel；
2. 发送线程在当前帧边界停止，不再发送结束帧；
3. 同一序列化发送锁释放后，上位机发送 `0x44124445 HOST_SEND_STOPPED`；
4. FPGA 按已定义流程执行全局复位；
5. 自动化本轮标记 FAIL、取消 VM 任务并保留文件，不自动开始下一轮。

## 8. 安装与启动

Windows 需要 Python 3.12、Npcap、Scapy、FastAPI 和 Paramiko。首次或依赖变化后在管理员权限不敏感的普通 PowerShell 中运行：

```powershell
cd D:\eh2_fpga\eh2logcomp\webui
.\install.ps1
.\run.ps1
```

访问 `http://127.0.0.1:3205`。VM 必须已经启动、SSH 可达、VMware 共享目录已挂载，并能获得 VCS license。界面中的 SSH 密码不会写盘。

## 9. 已完成验证

### 9.1 早期真实 VM 基线（地址分离前）

以下 seed `320527` 结果用于确认原始自动化生成/比较链路；当时尚未实施第 9.5 节的数据 NOLOAD 地址分离，因此镜像大小不代表当前版本。每 hart 随机主体 10,000 条，缓存生成器命中：

| 项目 | 结果 |
| --- | ---: |
| 程序镜像 | 292,048 Byte |
| 程序帧数 | 286 |
| 程序 SHA-256 | `32130859c32a2519e712671796953b34632003663c0654fc0afc558532006ca2` |
| Spike 日志 | 974,588 Byte |
| hart0 比较记录 | 10,029 |
| hart1 比较记录 | 10,028 |
| VM 总时间 | 22.880 s |
| 最终状态 | `SPIKE_DONE` |

### 9.2 Windows 全规模比较

使用上述真实 Spike 日志构造等价的完整 FPGA 以太网帧流，实际走单文件日志、Spike 归一化和完整比较器：

- 原始 Info 帧：338；
- hart0：168 个数据帧、10,029 条记录；
- hart1：168 个数据帧、10,028 条记录；
- H0DN/H1DN：均通过；
- 结果：PASS。

### 9.3 故障与屏障单元测试

新增自动化测试覆盖：

- 单文件 Info 写入/读取与时间戳；
- 正常双 hart 比较；
- WAW victim 与后续同 GPR writer 的合法配对；
- 非法 WAW cancel number 定位到首个 hart/sequence；
- Info 帧号不连续立即 FAIL；
- 比较结束前重复 `0x22222222` 不会启动第二轮；
- 点击按钮时从 `0x22222222`/`0x33333333` 接管；
- Python 全模块编译；
- JavaScript 语法检查。

在实际 `D:\eh2_fpga\eh2logcomp\webui` 与其 `.venv` 中运行了最终完整测试集。2026-08-26 最新运行共36项全部通过，新增覆盖原子DCCM地址审计、VM失败轮次保存 `vmwrong.txt`、取消发送、复位代次屏障及自动进入下一轮。

### 9.4 实际部署检查

- 短暂启动实际 Uvicorn 服务并通过真实 HTTP 请求访问 `/` 与 `/api/status`：PASS；
- 页面默认值为每 hart 10,000、单块 10,000、worker 1：PASS；
- 状态 API 的严格轮次屏障为开启，且返回文档不包含 SSH password 字段：PASS；
- Windows Scapy 2.7.0 检测 `pcap_provider=true`，实际使用 Npcap/pcap 后端：PASS；
- 实际 WebUI `.venv` 已安装 Paramiko 3.5.1，并通过 SSH 确认 VM 中 `/home/mtw/riscv-dv` 与 `/usr/bin/spike` 可用：PASS；
- 实际虚拟环境原先不完整的 pip 已重新安装为 24.0，后续 `install.ps1` 可以继续维护依赖。

板卡真实闭环仍需要 FPGA 上电、物理网线与正确 bitstream 才能执行。软件验证不能替代物理链路验证；首次使用建议观察一轮完整 PREINIT→PRECONFIG→READY→PROGRAM_WRITE→EXECUTE→END→COMPARE。

### 9.5 程序/LSU 地址分离验证

程序烧写协议、程序帧格式、DDR DMA 起始地址和 EH2 复位向量均未改变，仍为 `0x80000000`。所有随机 LSU 地址的总包络按要求限制为 `0xA0000000–0xFFFFFFFF`。其中普通访存和 EH2 原子访存使用不同的物理存储区：

| 用途 | 地址范围 | ELF 属性 |
| --- | --- | --- |
| EH2 指令和只读常量 | `0x80000000–0x9fffffff` | `PROGBITS`，写入 `program.bin` |
| 普通 load/store、双 hart 栈和 NOLOAD 数据 | `0xA0000000–0xCFFFFFFF` | 外部 DDR0，`NOLOAD/NOBITS` |
| AMO/LR/SC hart0 私有页 | `0xF0040000–0xF004003F` | EH2 DCCM，`NOLOAD/NOBITS` |
| AMO/LR/SC hart1 私有页 | `0xF0040040–0xF004007F` | EH2 DCCM，`NOLOAD/NOBITS` |
| 全部随机 LSU 的允许总包络 | `0xA0000000–0xFFFFFFFF` | worker 和 manifest 共同检查 |

普通数据基址改为 `0xA0000000`，与 `0x80000000` 程序窗口完全分离。AMO/LR/SC 不能像普通 load/store 一样放在外部 DDR：当前 EH2 配置只在内部 DCCM 接受这些事务，因此它们固定到真实 64 KiB DCCM `0xF0040000–0xF004FFFF` 内，并把 riscv-dv 原本共享的 `amo_0` 页拆为两 hart 私有页，消除双 hart 调度顺序引起的非确定结果。链接时强制检查：

- 程序入口必须等于 `0x80000000`，程序末地址不得超过 `0xa0000000`；
- 所有普通数据首地址不得低于 `0xA0000000`，末地址必须小于等于 `0xD0000000`；
- 原子页必须完全落在硬件真实 DCCM `[0xF0040000,0xF0050000)`，两个 hart 的页不得重叠；
- 普通和原子访问都必须位于总 LSU 包络 `0xA0000000–0xFFFFFFFF`；
- 程序区和数据区不得重叠；
- 硬件 ELF 和 Spike ELF 的公共入口、数据布局及三个替换点 PC 必须一致；
- `program.bin` 大小不得超过硬件程序的高地址代码区，防止 objcopy 意外生成从低数据地址到高程序地址的巨大空洞。

数据段使用 `NOLOAD` 是有意设计：FPGA 在 READY 阶段已经清零 DDR0 低 4 GiB，所以外部 DDR 数据为零；hart0 在执行 `csrw 0x7FC` 启动 hart1 前，通过 EH2 调试初始化/启动包络清零两份 DCCM 原子页。Spike 的对应 RAM 同样从零开始。这样无需修改以太网烧写逻辑，也无需增加数据帧。硬件末尾写 `0xD0580000` 的停止标记是已有控制 MMIO；它也位于用户指定的 LSU 总包络内，但不属于随机普通数据页。

最终用于唯一完整顶层验证的真实 VM 程序使用 seed `32052517`、RV32IMAC、2 hart、每 hart 10,000 条随机主体指令：

| 项目 | 结果 |
| --- | ---: |
| 硬件程序入口 | `0x80000000` |
| 硬件程序末地址（exclusive） | `0x800157E8` |
| 普通数据实际区间 | `0xA0000000–0xA0035A7F` |
| hart0 原子页 | `0xF0040000–0xF004003F` |
| hart1 原子页 | `0xF0040040–0xF004007F` |
| `program.bin` | 88,040 Byte |
| 程序以太网帧 | 86 帧 |
| 随机普通 LSU / 原子指令 | 约 2,957 / 289 |
| `program.bin` SHA-256 | `065E5AF9C246A612F6504B1A77F2C7DF9FFFE4F19FA30C914C2FABA9C351C70F` |
| 最终状态 | `SPIKE_DONE` |

ELF 审计确认只有 program、data、amo 三个 PT_LOAD；data/amo 的 `FileSiz=0`，因此烧写镜像只含 `0x80000000` 起始的代码，不会生成从程序区跨到高地址数据区的巨大稀疏 BIN。manifest 和反汇编审计确认程序、普通数据、两份原子页均在各自边界内。

### 9.6 VM失败轮次的跳过与恢复

每次点击“启动一键自动化”创建一个 `runlog/automation/session_*` 会话目录和不含密码的 `automation_session.json`；同一次连续运行的每轮执行位于其下独立的 `run_*` 子目录。VM任务报告 `stage=FAILED` 后，该轮不进入FPGA执行和比较，也不计入PASS、FAIL及累计比较指令数。WebUI在 `<session_id>/<run_id>/vmwrong.txt` 中汇总保存run id、seed、失败阶段、完整状态与远端控制台错误，删除无FPGA数据的空捕获，保留共享目录原始错误文件，取消可能已开始的程序发送，并发送 `0x44134445` 全局复位。只有收到新复位代次的 `0x11111111` 才允许自动PRECONFIG和下一随机轮次；此前缓存的READY或错误状态均不能越过该屏障。PASS轮次立即删除共享目录中的程序、汇编、目标文件、ELF和原始VM临时日志，以及本地FPGA二进制捕获，只保留比较与复核所需文件。若错误文件无法保存或复位命令无法发送，流程才转为终止性FAILED。

## 10. 持久化系统比较次数

WebUI 在 `runtime/automation/comparison_stats.json` 中持久保存：

- `total_comparisons`：已经真正执行完比较器并得到 PASS/FAIL 的总轮数；
- `pass_comparisons`、`fail_comparisons`：对应结果的累计轮数；
- `last_run_id`、`last_status`、`updated_at`：最近一次比较信息。

程序生成失败、烧写失败或尚未进入比较器的轮次不计入总数。计数文件使用临时文件加原子替换写入，WebUI 重启后继续累计；清理页面日志和 PASS 轮次文件不会清除该计数。若计数文件损坏，自动化拒绝静默归零并报告文件路径，以免丢失累计结果。页面自动化状态区会同步显示总比较次数、PASS 和 FAIL 数。

## 11. 常见限制与排查

- 只有一个 10,000 条块时 worker 实际会限制为 1；把 worker 改为 4 不会缩短本配置时间。
- 首轮若 VCS 缓存不存在，需要先编译生成器，时间明显长于后续轮次。
- VCS license 不可用、VM 共享目录未挂载、SSH 不可达、Spike 未安装都会使本轮 FAIL，并在 `status.json`/`remote_runner_console.log` 留下原因。
- 自动化必须先启动 Npcap 监听；否则可能错过 FPGA 紧接返回的状态帧。
- FPGA Info 数据流按当前硬件协议先完整发送 hart0，再发送 hart1；比较器会拒绝在 hart1 已开始后再次出现 hart0 数据帧。
- 自动化程序发送为帧间隔 0。若主机网卡驱动或 FPGA RX 仍报告错误，应优先检查物理链路、Npcap 适配器选择、PHY/RGMII 时序以及 FPGA 错误码，不应通过静默忽略丢帧获得 PASS。
