# 后续 RTL 修改冻结需求：Info 全量重传与主机裁决复位

## 1. 适用范围与当前版本边界

本文记录下一次 RTL/WebUI 联合修改必须实现的最终行为，当前比特流尚不具备 Info 日志重传能力。

当前临时 WebUI 在确认 Info 回传帧缺失后，会保存错误、发送全局复位并跳到下一轮；待本文所述 RTL 完成后，必须将临时策略替换成“先全量重传、重新比较，只有比较 PASS 才由主机请求复位”。

## 2. 最终控制原则

1. EH2 执行结束并完成第一轮 Info 发送后，FPGA 停留在等待主机裁决的保持状态，不再自行请求全局复位。
2. 等待期间保留 DDR1 中两个 hart 的全部 256-bit Info 记录、两个 hart 的总记录数和结束帧所需统计，禁止 READY 清零或新程序覆盖这些数据。
3. MAC、PHY、系统信息 RX FIFO、系统命令解码器、DDR1 MIG 和 Info 读 DMA 必须继续工作，使主机仍可要求全量重传或全局复位。
4. 上位机确认两 hart 帧号连续、记录覆盖完整且与 Spike 比较 PASS 后，才发送已有的 `HOST_GLOBAL_RESET=0x44134445`。
5. 若上位机发现 Info 帧编号不连续、完成帧声明计数与实收不符或 sequence 覆盖缺口，不能复位，必须请求重新发送两个 hart 的全部 Info 帧，并对新一代回传从头比较。
6. 若帧完整但 PC、instruction、metadata、架构写回数据或 WAW 信息比较不通过，不发送复位，也不自动开始下一轮；保持 DDR 和板级现场，等待人工分析或人工命令。
7. VM 生成/Spike 失败时允许 WebUI主动发送全局复位以跳过该轮，因为复位动作仍由上位机发起，不属于 FPGA 自动恢复。

## 3. 新增主机命令

预留系统命令：

| 名称 | 32-bit code | 用途 |
|---|---:|---|
| `HOST_INFO_RETRANSMIT_ALL` | `0x44144445` | 丢弃当前回传代次，从 DDR1 重新发送 hart0、hart1 的全部 Info 帧 |
| `HOST_GLOBAL_RESET` | `0x44134445` | 仅在比较 PASS 或主机明确人工决定时执行全局复位 |

新命令沿用系统信息接收通路，不进入程序帧分类器：

- 目的 MAC：`02:32:05:25:00:ff`
- EtherType：`0x88B5`
- Payload：固定 46 Byte
- Payload Byte 0～3：`44 14 44 45`
- Payload Byte 4～45：全部为 `00`

`system_info_rx_decoder` 增加完整长度、保留字节全零校验和 `host_info_retransmit_all_pulse`。该命令只允许重新启动 Info DDR 读 DMA，绝不能启动程序写 DMA、修改 DDR0 或重新释放 EH2。

## 4. FPGA 执行结束后的保持状态

建议在现有 END 内增加明确的 `WAIT_HOST_VERDICT` 子阶段，或者新增同等含义的状态。第一轮 H0DN、H1DN 和 EXE_END 都物理发送完成后：

- EH2 保持停止/复位，不再产生新 Info；
- Info 写 DMA 必须已经完成，DDR1 写端冻结；
- DDR1 的 Info 数据、`hart0_total_records`、`hart1_total_records` 保留；
- Info 读 DMA、双帧 buffer 和系统命令 RX 保持可用；
- 不产生内部 `global_reset_request`；
- 只响应全量重传命令、主机全局复位命令以及必要的错误监测。

原先由“END发送完成”或“错误确认完成”自动触发的复位路径必须移除。全局复位请求的正常来源只保留同步后的 `host_global_reset_pulse`；真正的板级硬复位输入仍保留最高优先级。

## 5. 全量重传的 RTL 行为

主机可能在第一轮 Info 仍在发送时就发现帧号跳变。因此收到 `HOST_INFO_RETRANSMIT_ALL` 后不能立即把 DMA 地址清零，否则旧代次和新代次会在 MAC FIFO 中交错。必须按以下顺序处理：

1. 锁存 `retransmit_pending`，禁止规划新的旧代次 DDR1 读 burst。
2. 允许已经发出的 AXI burst、帧构造器中的脏帧和已提交 TEMAC 的完整帧在帧边界安全结束。
3. 等待双帧 buffer 空、Info AXI-Stream idle，并等待客户端提交帧计数与经过正确上升沿计数的 MAC 物理发送完成计数达到本代次目标。
4. 清除本次“读发送会话”的临时状态，但不清除 DDR1 内容和 EH2 执行统计：
   - hart 选择恢复为 hart0；
   - DDR1 读地址恢复到 hart0 记录起始地址；
   - hart0、hart1 数据帧编号都恢复为 0；
   - 已发送记录数、帧 payload 填充计数、done-frame 已发送标志清零；
   - DMA/buffer overflow 和协议错误仍按现有错误平台锁存，不能被重传命令掩盖。
5. 先通过系统信息 FIFO 发送“重传开始确认”。确认帧必须在物理发送侧完成后，才允许提交新代次的 hart0 第0帧，防止上位机把旧尾帧误当作新代次。
6. 按原顺序完整发送：hart0 frame 0…N、H0DN、hart1 frame 0…M、H1DN。Info数据帧、每帧60条记录、末帧补零和两个完成帧的现有格式均保持不变。
7. 重传结束后再次停留在 `WAIT_HOST_VERDICT`，仍不自动复位。若新代次再次缺帧，上位机可以再次发送同一命令；RTL本身不限制重传次数。

“重传开始确认”的具体状态码在实施时加入 `eh2_system_pkg.sv`，不得复用 H0DN/H1DN 或 EXE_END。WebUI 只有收到该确认后才清空旧代次接收缓存并接纳 frame 0；这是避免网络/驱动残留旧帧污染新比较的必要屏障。

## 6. 上位机最终流程

```text
收到第一轮 Info 数据/H0DN/H1DN
              |
              v
      检查帧号、计数、sequence
         /                 \
   发现缺失              数据完整
      |                     |
记录 automation/_wrong.txt  与 Spike 比较
      |                /             \
发 0x44144445       内容 FAIL        PASS
      |                |              |
等待重传开始确认      保持现场       发 0x44134445
      |                不复位          |
丢弃旧代次缓存                       等待新 PREINIT
      |
从 hart0 frame 0 重新接收并重新比较
```

帧缺失轮次仍追加到 `runlog/automation/_wrong.txt`，至少记录 session、run、seed、hart、期望帧号、实际帧号、首个缺失 sequence 和重传次数。重传成功并最终比较 PASS 后，允许清除大体积临时文件；内容比较 FAIL 时保留完整 FPGA TXT、Spike TXT、程序、ELF、manifest 和比较报告。

## 7. CDC、总线所有权和复位约束

- `host_info_retransmit_all_pulse` 起源于系统 RX/控制时钟域，进入 DDR1 UI/Info DMA 时钟域必须使用请求 toggle + 双触发同步，并用完成 toggle 返回；不能直接跨域使用单周期脉冲。
- “旧代次已物理排空”涉及 125 MHz TX 客户端域、TEMAC 统计域和100 MHz控制域，继续使用 Gray/toggle CDC；TEMAC `tx_statistics_valid` 必须先取上升沿后计数，禁止对持续高电平重复计数。
- 重传期间 DDR1 owner 始终只授予 `DDR1_OWNER_INFO_READ`，不得和清零、ATG或Info写 DMA并发。
- 重传命令只复位读会话局部计数，不得拉动全局复位、MIG复位、MAC复位、Info写FIFO复位或EH2复位序列。
- 主机全局复位到达后，仍按各时钟域异步置位、同步释放的本地复位方式执行至少原有64个100 MHz控制周期。

## 8. 必须补充的验证

1. 顶层仿真中故意丢弃 hart1 中间一个Info帧，确认WebUI检测跳号后发送 `0x44144445`，FPGA不复位且从hart0 frame 0全量重传。
2. 在第一轮尚有DMA burst、脏帧和TEMAC待发送帧时注入重传命令，证明旧、新代次不交错。
3. 对重传流再次丢帧并连续请求两次重传，证明地址、帧号、H0DN/H1DN和记录总数每次都从干净会话重新建立。
4. 对MAC施加持续 backpressure，证明双帧 buffer、DMA安全余量和重传排空屏障不溢出、不死锁。
5. 比较内容故意篡改但保持帧连续，证明WebUI不发送复位也不发送自动重传。
6. 完整比较PASS，证明只有此后收到的 `0x44134445` 才产生全局复位并重新进入PRECONFIG。
7. 添加断言：没有 `host_global_reset_pulse` 或板级硬复位时，END/ERROR/重传完成均不得产生 `global_reset_request`。

## 9. 此前已确认、必须一并纳入的 RTL 修改

以下项目来自此前板级问题分析，不能因为本次增加重传而遗漏。

### 9.1 取消 FPGA 的自动恢复复位

当前 `eh2_system_controller.sv` 中有两类自动复位来源：

- `ST_END` 在 EXE_END 发送后，等待 TX 物理完成计数达到目标或等待超时，然后直接拉高 `global_reset_request`；
- `ST_ERROR` 在接到 `HOST_SEND_STOPPED=0x44124445` 后，直接拉高 `global_reset_request`。

这两条路径都与新的主机裁决规则冲突，必须删除或改为“保持等待主机命令”。`HOST_SEND_STOPPED` 在后续版本只能表示主机已经停发，不能隐含批准丢弃 DDR1 现场或复位系统。

修改后 `global_reset_request` 只有两种合法来源：

1. 板级硬复位/外部复位链路；
2. 经 CDC 同步后的 `HOST_GLOBAL_RESET=0x44134445`。

此项也一并解决此前偶发停在 `RESETTING` 的根源：旧 END 流程同时依赖 TX 客户端提交计数和TEMAC统计完成计数。两个计数跨不同的时钟域，观察到达时间不同；即使数字最终正确，自动复位逻辑也不应再以它们作为“必须复位”的条件。

### 9.2 TX 完成计数的正确语义与分段可观测性

必须保留并扩展现有三类累计计数器；全部使用二进制本地计数、Gray 编码、至少三级同步、目的时钟域解码。计数器绝不能用单周期跨域脉冲实现。

| 计数器 | 产生位置 | 增加条件 | 作用 |
|---|---|---|---|
| `info_frame_published` | Info帧构造器/双帧槽写侧 | 一个完整帧写入槽并发布 | 证明DDR1读DMA已经形成了该帧 |
| `info_frame_client_accepted` | 125 MHz MAC客户端侧 | `valid && ready && last` | 证明完整帧已经被TEMAC客户端接口接收 |
| `tx_frame_physical_complete` | TEMAC TX统计时钟侧 | `tx_statistics_valid` 的**上升沿** | 证明MAC报告一帧已完成物理发送 |

以前 `tx_statistics_valid` 可能持续多个TX时钟为高；若按高电平的每拍计数，一帧会被多次计数，导致提交数与物理完成数永久失配。现有的上升沿检测必须保留，且补充断言：一次统计有效平台最多增加一次物理完成计数。

重传排空屏障使用上述计数器：本代次发布、客户端接收、物理完成三者都达到该代次目标后，才允许发送“重传开始确认”。这些计数器也应随每次重传代次分别锁存快照，不能仅观察跨代次的全局累计数。

### 9.3 Info 回传代次（epoch）与残留帧隔离

单纯将帧编号重新置零不够，因为PC/NIC、TEMAC FIFO 或旧DMA可能仍有上一代数据帧。新增：

- `info_tx_epoch`：至少16 bit、每接受一次重传命令加一；
- `MSG_INFO_RETRANSMIT_BEGIN`：payload带回传 epoch、hart0/hart1总记录数和总帧数；
- H0DN、H1DN 的保留字段中加入该 epoch，或升级版本字段并在两个完成帧中明确携带 epoch；
- 每个Info数据帧的现有4 Byte帧编号之前/之后增加epoch字段，或在保持当前数据帧格式的前提下，以“重传开始确认 + 完成帧epoch”作为严格会话边界。

建议采用第一种：每帧显式携带 epoch，WebUI只接受当前epoch的帧。这样旧尾帧即使在重传开始确认之后才到达，也会被无歧义丢弃；这比仅依赖时间和帧号零点更安全。修改帧格式后，必须同步更新 FPGA、WebUI、比较器和README，且不能与1024/1444字节固定payload长度约束冲突。

### 9.4 DDR1 所有权、数据保护与DMA边界

- 从 `MSG_EH2_DONE` 到主机全局复位期间，禁止任何DDR1清零、ATG、Info写DMA或新程序会话取得DDR1所有权；只允许 `DDR1_OWNER_INFO_READ`。
- Info读DMA重传前重置地址、burst剩余量、帧内记录计数、末帧padding和双帧槽发布状态；不得复位记录总数、DDR1内容、EH2 sequence或WAW信息。
- 保持此前已修复的CDC安全余量：AR发起前应为完整AXI读burst预留回传FIFO空间，避免异步写计数同步滞后导致DMA返回数据挤满FIFO。
- 重传请求到达时若DDR1读DMA正在接收R通道数据，必须先接完已接受的burst；不得中途撤销AR或丢弃R数据。

### 9.5 接收可靠性和错误计数的保留

既有RX时序放行、IDELAY/PHY初始化、MAC FCS错误检测和程序帧序号检查不能因新控制状态被绕过。

- MAC在用户侧丢弃FCS错误帧时，继续锁存 `ERR_MAC_RX_FCS` 和累计计数；
- 程序写入阶段的编号不连续、结束帧总数不符、DMA未完成等仍是程序会话错误，不能被Info重传命令清除；
- `eth_rx_frame_classifier` 必须继续把系统命令MAC与程序MAC隔离，`0x44144445` 和 `0x44134445` 绝不能进入程序RX FIFO或改变程序DMA地址；
- WebUI保存的 `_wrong.txt` 应同时记录PC侧缺帧诊断、FPGA侧FCS错误计数和RX分类器丢弃计数，便于区分“FPGA没有发送”与“线路/PC没有收到”。

### 9.6 复位跨时钟域的最终约束

主机全局复位命令本身在系统MAC RX/控制时钟域产生；全局复位监督器再对各本地时钟域实施异步置位、同步释放。复位不是通过AXI总线传递，也不能用边沿脉冲直接驱动异步复位端口。

保留每个IP/时钟域独立的复位输入：MIG、AXI时钟/位宽转换IP、TEMAC、RX/TX FIFO、EH2和DDR DMA均在各自时钟域完成同步释放。重传属于一次读会话重置，必须只使用局部同步复位或清除脉冲，禁止误触发这些全局IP复位。

## 10. 预计涉及文件

- `rtl/common/eh2_system_pkg.sv`：新增重传命令和重传开始确认码。
- `rtl/eth/system_info_rx_decoder.sv`：解码 `0x44144445` 并产生重传请求。
- `rtl/control/system_controller.sv` 或实际系统控制器：移除END/ERROR自动复位，增加主机裁决保持和重传控制。
- `rtl/eth/info_log_dump_subsystem.sv`：增加排空、读会话重置和从hart0起始地址全量重发。
- `rtl/eth/info_tx_frame_fifo_2slot.sv`、TX物理完成计数路径：提供可靠的代次排空条件。
- `webui/eh2web/protocol.py`、`service.py`、`automation.py`：发送重传命令，按确认码切换接收代次，PASS后发送全局复位，内容FAIL保持现场。
- 顶层测试平台和WebUI单元测试：覆盖第8节所有正反例。

## 11. 实施顺序与验收门槛

1. 先完成系统命令定义、RX解码和主机裁决保持状态，且先通过“END/ERROR不再自动复位”的顶层仿真。
2. 再完成Info DMA读会话重置、双帧槽排空和重传代次字段，验证旧/新代次绝不交错。
3. 接着更新WebUI：缺帧发重传命令、等待重传开始确认、按epoch重新收集、只在PASS后发全局复位。
4. 最后加入分段计数器、FCS/RX统计上报、断言和故障注入测试。

验收条件是：故意删掉任意hart的任意中间Info帧后，第一次比较必定拒绝；FPGA保持现场并完成全量重传；第二次完整数据能PASS时才复位。任何内容不一致、WAW不一致、DMA/DDR错误或重传期间溢出，都不得自动复位或自动掩盖。

## 12. 2026-08-29 板级新增确认项与临时 WebUI 策略

### 12.1 当前比特流的确定性 RTL 错误

板级日志已经证明，当前 `system_info_rx_decoder.sv` 在收到一次
`HOST_INFO_RETRANSMIT_ALL=0x44144445` 后，会把
`host_info_retransmit_all_pulse` 置为1，但正常工作分支没有像其他单周期命令一样在
每个控制时钟周期先将它恢复为0。因此该信号实际变成了持续高电平，而不是单周期脉冲。

`eh2_system_controller.sv` 在 END 状态把该电平解释成新请求。一次合法重传结束并回到
等待阶段后，控制器会再次锁存同一请求，导致 FPGA 连续发送
`MSG_INFO_RETRANSMIT_BEGIN=0x77770001` 并重复回放 DDR1 日志。板级现象为：

- 第一次缺帧后的一次全量重传可以完整通过 H0DN/H1DN 计数检查；
- 随后在上位机没有发送新请求时再次出现 `0x77770001`；
- 新旧接收代次被再次切换，最终比较器只能看到不含两个完成帧的局部日志。

下一次生成比特流前必须完成以下 RTL 修改：

1. 在 `system_info_rx_decoder.sv` 的非复位分支中，每周期默认执行
   `host_info_retransmit_all_pulse <= 1'b0`，仅在一帧合法命令结束时置1一个周期。
2. 在控制器入口增加第二层防护：只接受请求上升沿，或使用“请求/消费完成”握手；
   输入保持为1期间不得再次产生新的 `retransmit_pending`。
3. 增加断言：一帧 `0x44144445` 只能产生一次请求事件、一次
   `0x77770001` 和一次完整的 hart0/hart1 回放。
4. 分别验证输入脉冲为1周期、意外保持高电平多个周期、重传期间再次到达请求三种情况；
   后两种情况均不得形成无界重复回放。
5. 保留原有旧代次物理排空屏障；修复请求脉冲不能绕过 TX submitted/complete 计数及
   MAC FIFO 排空条件。

### 12.2 当前版本采用的临时 WebUI 行为

在上述 RTL 修复并重新生成比特流之前，WebUI 禁止自动发送 Info 全量重传命令：

1. 发现帧号跳变、sequence 覆盖缺口、完成帧计数不符，或 EXE_END 到达时缺少任一
   hart 完成帧，立即把本轮标记为 `INFO_STREAM_MISSING`。
2. 保存该轮无时间戳 FPGA TXT、二进制抓取、程序/Spike/manifest、
   `info_loss_report.json` 和 `automation/_wrong.txt` 诊断。
3. 不发送 `0x44144445`，不等待或采用 `0x77770001`，也不切换日志代次。
4. 由 WebUI 立即发送 `HOST_GLOBAL_RESET=0x44134445`，等待新的 PREINIT/READY，
   然后使用新 seed 开始下一轮。
5. 当前比特流若自行发出未请求的 `0x77770001`，WebUI把它视为本轮传输已污染，
   同样丢弃该轮并全局复位，不能在比较线程运行期间替换日志文件。

该临时策略优先保证自动化可以持续运行且不同执行轮次不会混合。它会牺牲发生丢帧的
整轮测试时间；待第12.1节的 RTL 修复通过专项仿真并生成新比特流后，再恢复本文第2～8节
定义的“保留 DDR1、全量重传、重新比较”最终流程。
