# EH2LOGCOMP 双 hart 一键自动化验证环境

## 1. 目标与运行位置

本环境在保留原 WebUI 手工烧写、状态监视、日志保存和错误应答功能的基础上，增加“一键自动化”循环：

1. 等待 FPGA 状态机到达相应阶段；
2. 通过 SSH 在虚拟机本地磁盘用 riscv-dv 生成一份新的 RV32IMAC 双 hart 程序；
3. 在虚拟机本地生成硬件执行镜像与 Spike 参考镜像，再向share发布最终文件；
4. Windows WebUI 通过物理以太网口把硬件镜像烧写到 FPGA；
5. 虚拟机同时运行 Spike 并生成提交日志；
6. Windows 将 FPGA 返回的所有 Info 数据帧和完成帧保存到一个文件；
7. Windows 流式比较 FPGA Info 与 Spike 日志；
8. PASS 时先记录轻量统计摘要，随后删除整个本地及共享的本轮目录；FAIL、Info回传缺失或VM失败时才保留全部错误现场。

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

每个硬件停止 store 后紧跟 `fence rw,rw`，再跳入 `wfi` 停驻循环。结束检测位于 LSU AXI AW/W 握手侧，普通 store 提交后仍可能有一条年轻指令先退休；fence 强制停止 store 排出 LSU，使日志模块先锁存该 hart 的 `stopped`，随后才允许停驻 jump 推进。因此停止 store 是该 hart 最后一条 Info 记录，且不会再出现只有某个 hart 多出一条尾部 jump 的总数差异。Spike 镜像在对应 PC 用 NOP 代替私有停止 store，但保留同位置 fence，比较器仍严格在停止PC截断参考流。

Spike 在跳到 `0x80000000` 前的 Boot ROM 提交不参与比较，但 Boot ROM 留下的 GPR 值仍会影响后续程序，例如 Spike 会把 `x11/a1` 留为 DTB 地址 `0x1020`，而 EH2 直接从复位向量启动时该值不同。当前公共启动包络在两个 hart 进入随机主体前，将除 `sp` 外的全部可写 GPR 确定性清零，再设置各 hart 私有 `sp`；硬件镜像和 Spike 镜像执行完全相同的初始化。这样既不比较复位向量之前的日志，也不会让启动前遗留状态污染正式比较。

### 3.3 Info 回传、比较与下一轮屏障

FPGA 在 END 阶段依次回传 hart0、hart1 的 Info 数据流和两个完成帧。自动化接收热路径只把 `0x88B7` Info DATA 和 `0x88B8` Info DONE 顺序写入本轮紧凑二进制临时文件：

```text
webui/runlog/automation/<session_id>/<run_id>/fpga_info.eh2log
```

比较直接读取这个临时文件，不再把 TXT 重新解析成帧。PASS 时整个轮次目录被删除，因此不会保留 TXT；只有比较 FAIL、FPGA 报错或失败轮次被用户重新启动前，才把二进制帧一次性解码为无时间戳 `fpga_info.txt` 供定位问题。

比较必须同时满足：

- 已收到 H0DN；
- 已收到 H1DN；
- 已收到 `0x77777777 EXE_END`；
- VM `status.json` 已标记 `spike_done=true`。

随后 Windows 才关闭二进制临时日志并启动比较。比较和 PASS 清理全部完成之前，后续收到的 `0x11111111` 只被记为 pending；额外的 `0x22222222` 被屏障拒绝，不会创建第二个并发轮次。PASS 清理完成后才释放下一轮；如果 pending 的 PREINIT 已经到达，就立即发送下一轮 PRECONFIG 检查帧。

## 4. 单文件 FPGA 日志格式

失败时生成的 `fpga_info.txt` 为 UTF-8、逐行可读的无时间戳日志。每行直接以 `INFO_DATA` 或 `INFO_DONE` 开始，后续为制表符分隔的 `key=value` 字段。Info 数据帧的 60 个槽均保留，padding 明确标为 `padding=1`；“已执行指令数”只统计非 padding 记录。比较器同时兼容早期带时间戳的 v1 TXT，以便历史 FAIL 现场在升级后仍能重新比较。

二进制写入器使用 8 MiB 用户缓冲，Npcap 回调只复制帧并入队；协议检查、紧凑帧写入和界面事件在后台接收线程完成。自动化 Info 快速路径不为每个数据帧创建 60 个 Python 字典，也不在正常轮次逐条格式化 TXT，因此不会因字符串和磁盘放大阻塞抓包。当前实测同一份日志的紧凑文件约为逐条 TXT 的九分之一，完整扫描约快 9 倍。

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

首个不匹配会同时写入 `compare_report.json` 和无时间戳的 `comparison_result.txt`，包括首个失败 hart、sequence、原因、相关字段及发生失败前已比较的指令数。页面也锁存并显示 `hart + sequence`。PC/指令/架构数据/WAW内容不一致后停止；能够明确证明为Info帧缺失的FAIL则记录到 `runlog/automation/_wrong.txt`，全局复位并继续下一轮。

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

每次点击自动化按钮创建一个 `runlog/automation/session_*` 会话目录和不含密码的 `automation_session.json`；该次连续运行的每轮先在其下创建独立 `run_*` 子目录。riscv-dv/VCS产生的汇编、对象、ELF和编译日志均位于虚拟机本地临时目录，只有成功后的 `program.bin`、`manifest.json` 和Spike原始日志发布到share；Spike归一化二进制只位于比较临时目录，不生成持久化 `.expected` 文件。比较 PASS 后整个本地 `run_*` 及共享目录同名 `run_*` 都被删除；只有失败轮次才保留 `spike.log.txt`、`manifest.json`、`compare_report.json`、`comparison_result.txt`、`timing_report.txt`，并额外生成 `fpga_info.txt`；VM失败时本地构建文件会复制为 `vm_failure_artifacts`。

- PASS：先将小型摘要追加到 `runtime/automation/pass_history.jsonl`，再删除本地 `session_*/run_*` 的全部文件及当前 run_id 的共享程序/ELF/汇编/Spike/VM临时目录；清理成功后才允许下一轮。
- FAIL：生成并保留 `fpga_info.txt`，同时保留程序、源代码、ELF、Spike 日志、FPGA 紧凑原始帧、manifest、状态和比较报告，并停止自动化。
- 用户点击停止：向 VM 写 `cancel.request`，关闭当前 FPGA 日志，保留全部现场。

目录删除前会校验父目录，只允许删除精确的 `<runs>/<run_id>`，不会删除共享根、WebUI runtime 根或其他测试结果。

“清理历史运行缓存”按钮可显式删除旧 `session_*`、新旧 Windows `run_*`、共享 `run_*` 和上传缓存；正在监听的会话、正在执行的 run_id 和正在发送的程序缓存均受保护，不影响后续运行。

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

- 单文件 Info 写入/读取及无时间戳格式；
- 正常双 hart 比较；
- WAW victim 与后续同 GPR writer 的合法配对；
- 非法 WAW cancel number 定位到首个 hart/sequence；
- Info 帧号不连续立即 FAIL；
- 比较结束前重复 `0x22222222` 不会启动第二轮；
- 点击按钮时从 `0x22222222`/`0x33333333` 接管；
- Python 全模块编译；
- JavaScript 语法检查。

在实际 `D:\eh2_fpga\eh2logcomp\webui` 与其 `.venv` 中运行了最终完整测试集：当前共 36 项，覆盖协议/帧/20 万条基准、自动化屏障、首错 sequence、显示计数与累计比较指令归零、最近100条系统信息、独立错误码TXT、Spike原始TXT、PASS/FAIL文件策略、安全缓存清理、复位恢复看门狗、两个 hart 的停止 store→fence→停驻 jump 顺序、原子指令的 hart 私有 DCCM 地址审计，以及VM失败轮次保存 `vmwrong.txt` 后自动复位跳过，全部通过。

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

链接之后还有两层动态限制：Spike 的 `-m` 只映射真实 DCCM 的 64 KiB 窗口；Spike 结束后逐条扫描 opcode `0x2F` 的 AMO/LR/SC commit，要求 hart0 的每个有效地址位于 `0xF0040000–0xF004003F`，hart1 位于 `0xF0040040–0xF004007F`。任一地址越界、非 4-Byte 对齐或没有可审计的内存地址都会让该轮立即失败，不会进入 FPGA/Spike PASS。

2026-08-26 使用两个不同随机种子各生成并运行一轮 10,000 条/每 hart 的 RV32IMAC 程序，结果如下：

| seed | 原子指令 commit 数 | hart0 实际地址 | hart1 实际地址 | Spike 阶段 | 生成至 Spike 完成 |
| ---: | ---: | --- | --- | ---: | ---: |
| `32052626` | 300 | `0xF0040000–0xF004003C` | `0xF0040040–0xF004007C` | 0.448 s | 4.234 s |
| `32052627` | 266 | `0xF0040000–0xF004003C` | `0xF0040040–0xF004007C` | 0.407 s | 4.289 s |

两轮均得到 `atomic_address_check=PASS`。首轮开发审计曾准确拦截 Spike 专用结束包络在外部 DDR `0xA0000000` 使用的一条 `amoadd.w`；该指令虽然位于硬件停止点之后、不进入 FPGA 镜像，仍违反“所有原子指令只访问 DCCM”的统一约束。现已用 hart0/hart1 两个普通完成标志和普通 load/store 完成 Spike 协调，Spike 专用尾部也不再包含 DCCM 以外的原子指令。

Spike 性能专项实测同一份约 10k/hart ELF：不生成 commit 日志为 0.04 s；日志写入 VM 本地 `/tmp` 为 0.42 s；旧实现把约 1.23 MiB、24,747 行逐条直接写到 VMware HGFS，自动化样本为 26.15 s。新实现先写 VM 本地临时文件，在进程结束后完成地址审计，再用一次顺序复制写入共享目录；Windows 仍会将原始内容保存为 `runlog/.../spike.log.txt`，但不再承受每条 commit 日志跨 HGFS 的延迟。两个新随机种子的 Spike 阶段分别为 0.448 s 和 0.407 s，说明日志格式化确实有开销，但旧实现约 26 s 的主要瓶颈是 HGFS 小写入而不是 Spike 执行速度。

### 9.6 VM失败轮次的跳过与恢复

VM任务的 `status.json` 一旦出现 `stage=FAILED`/`failed=true`，该轮被定义为“参考程序准备失败”，不是FPGA比较FAIL：

1. 停止该轮VM任务，并取消可能已经开始的程序帧发送；
2. 在 `webui/runlog/automation/<session_id>/<run_id>/vmwrong.txt` 保存run id、seed、失败阶段、错误消息、完整远端状态和 `remote_runner_console.log`，并把摘要追加到 `webui/runlog/automation/_wrong.txt`；没有FPGA数据的空捕获容器立即删除；
3. 保留VM共享目录中的程序、ELF、Spike日志和编译日志，不执行PASS清理；
4. 不增加系统比较总数、PASS、FAIL或累计比较指令数；
5. 发送 `0x44134445 HOST_GLOBAL_RESET`，保持自动化为启用状态；
6. 在新复位代次的 `0x11111111 PREINIT_DONE` 到达前，忽略旧轮次缓存中的READY及错误状态；
7. 收到新PREINIT后自动完成PRECONFIG，待 `0x22222222/0x33333333` 后使用新seed启动下一轮。

若错误文件无法写入，或者复位命令无法发送，WebUI才转为终止性FAILED，避免在没有保存错误现场或没有建立新复位代次时继续运行。Info回传出现帧号断裂、完成帧计数与实收不符或sequence覆盖缺口时采用相同跳轮流程；其他比较FAIL仍停止。

## 10. 持久化系统比较次数

WebUI 在 `runtime/automation/comparison_stats.json` 中持久保存：

- `total_comparisons`：已经真正执行完比较器并得到 PASS/FAIL 的总轮数；
- `pass_comparisons`、`fail_comparisons`：对应结果的累计轮数；
- `last_run_id`、`last_status`、`updated_at`：最近一次比较信息。

程序生成失败、烧写失败或尚未进入比较器的轮次不计入总数。计数文件使用临时文件加原子替换写入，WebUI 重启后继续累计；清理页面日志和 PASS 轮次文件不会清除该历史值。若计数文件损坏，自动化拒绝静默归零并报告文件路径，以免丢失累计结果。页面只显示本次点击“启动一键自动化”后的会话计数：每次启动时总计、PASS、FAIL均归零，同一次自动循环内逐轮累计；历史累计仍保留在后台文件中。

## 11. 常见限制与排查

- 只有一个 10,000 条块时 worker 实际会限制为 1；把 worker 改为 4 不会缩短本配置时间。
- 首轮若 VCS 缓存不存在，需要先编译生成器，时间明显长于后续轮次。
- VCS license 不可用、VM 共享目录未挂载、SSH 不可达、Spike 未安装都会使本轮 FAIL，并在 `status.json`/`remote_runner_console.log` 留下原因。
- 自动化必须先启动 Npcap 监听；否则可能错过 FPGA 紧接返回的状态帧。
- FPGA Info 数据流按当前硬件协议先完整发送 hart0，再发送 hart1；比较器会拒绝在 hart1 已开始后再次出现 hart0 数据帧。
- 自动化程序发送为帧间隔 0。若主机网卡驱动或 FPGA RX 仍报告错误，应优先检查物理链路、Npcap 适配器选择、PHY/RGMII 时序以及 FPGA 错误码，不应通过静默忽略丢帧获得 PASS。
