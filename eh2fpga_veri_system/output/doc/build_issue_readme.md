# EH2 整机集成、前仿与实现问题记录

## 1. 文档目的

本文独立记录本次整机组合过程中实际遇到的错误、可观察现象、根因、修改方法、验证证据和以后防止复发的检查项。它不把正常的 Vivado 建议类 Warning 当成功能故障，也不隐去曾失败但后来已修复的过程。最终功能、前仿和上板接口分别见同目录 `README.md`、`veri_readme.md` 和 `system_board_readme.md`。

最终交付基线为：最新 RTL 完整综合，`post_opt/post_route` 未解析黑盒 0，471183 条可路由网络全部完成，setup/hold/pulse-width 为 `+0.082/+0.010/+0.046 ns`，严重 DRC 0，bitstream SHA-256 为 `1A201E64A760228E298B285A723EBD2D911B7F275CF80E9733EE6826BBF2D2FC`。

## 2. 功能与前仿问题

### 2.1 双 hart 中 hart1 永久无提交

**现象**：hart0 已提交 `csrw 0x7FC,2`，内部 `mhartstart[1]` 已置位，但 hart1 commit 始终为 0；hart0 最终能停止，hart1 不执行。

**根因**：wrapper 原来把 `mpc_reset_run_req` 接成 `2'b00`。初始化结束后的 `mpc_debug_run_req` 只启动 hart0；hart1 较晚被 MHARTSTART 释放后进入 MPC debug-halt 路径，却没有 hart1 的 debug-run 请求。

**修复**：保持 hart0 的原初始化/debug-run 流程，把 `mpc_reset_run_req` 改为 `2'b10`。hart1 仍受 MHARTSTART 门控，只有 hart0 写 CSR 0x7FC[1] 后才从复位向量 `0x80000000` 走 reset-run；EH2 网表内部没有修改。

**验证**：测试平台同时断言 hart0 在 PC `0x8000000c` 提交 CSR 值 2、hart1 第一条 commit 的 PC 为 `0x80000000`。最终提交数 hart0=100023、hart1=100021；200044 条 EH2/Spike 结构无缺失、额外或未解释 mismatch。

### 2.2 WAW 日志漏掉 direct-commit victim

**现象**：归约结构已按 `rv_commit_waw_victim` 清零，但日志 WAW list 只来自 `rv_nb_waw_valid`，导致 WAW 列表不完整。早期文档错误地把 ISS 比较器的 33 条 `accepted_waw_zero` 当成最终 WAW 总数。

**根因**：direct commit victim 和 pending-nonblocking victim 是 EH2 的两类不同信号。旧 sideband 只导出了后一类；“hash 输入正确”并不能证明“取消序号列表完整”。

**修复**：`instr_crc_hash_dual` 输出四槽：0/1 为两个 commit lane 的 direct victim，2/3 为两路 pending nonblock victim。四槽各用一个 33-bit×16 异步 FIFO 从 50 MHz 跨到 100 MHz；store 用同拍前缀计数连续写入。保留每 hart/package 483 条容量，第 484 条仍进入 ERROR，不改变日志帧协议。

**验证**：早期 WAW 定向仿真得到 hart0=4、hart1=128、总计132；完整系统发出的四帧分别为 `4/0/128/0`，全部序号与黄金 JSON 逐项一致；483 条可发送、第484条 overflow 的边界测试通过。

### 2.3 PRECONFIG 发送状态码后过早切换 DDR owner

**现象**：PRECONFIG 在发送 `PROGRAM_WRITE_START` 后 phase 从 2 跳到 6，程序 DMA 尚未完成却可能失去 DDR0，表现为 DMA 不结束或后续 checker 异常。

**根因**：增加 START/RECEIVE_DONE 两帧后使用了 phase 6..9；旧组合逻辑以 `phase < 3` 粗略判断写入窗口，把“发送状态帧的 phase 编号”误当成“DDR 操作阶段已经结束”。

**修复**：owner 改成显式集合。PRECONFIG 只有 phase 3/4/5 交给 checker，其他 phase 均保持 DDR0=PROGRAM、DDR1=ATG。状态帧只上报进度，不再隐式改变总线所有权。

**验证**：在 `结束帧总数=连续接收数=DMA done数` 且 DataMover idle、数据 ATG done 之前，checker start 必须保持 0；一帧全 FF 经正式序号/DMA/结束帧配对后，从指令 DDR `0x80000000` 回读 1024 byte 通过。

### 2.4 PROGRAM_WRITE_DONE 条件曾不足以代表最后一帧已落 DDR

**风险**：上位机在发送最后一帧后立刻发送不同 MAC 的结束帧，不等待 FPGA DMA done。如果 FPGA 只看结束帧，可能提前释放 EH2，最后一帧尚未完成写响应。

**处理**：结束帧到达时锁存其32-bit总包数和已连续接收帧数。只有声明总数、连续序号接收数、成功 DMA done 数相等且 `dma_busy=0` 才发送 `0x44444444`。`0x44114444` 只表示结束帧已收到，不代表 DDR 写完。

**验证**：控制器定向反例令目标为3、done仅2时保持 PROGRAM_WRITE；done=3但 busy=1仍保持；只有3且idle才通过。系统级使用782帧，不是用3帧代替大程序。

### 2.5 连续线速程序帧触发 MAC RX FIFO overflow

**现象**：连续程序帧约第13帧附近 RX FIFO overflow；单帧或有软件间隔时正常，所以板上表现为有时成功、有时超时/无响应。

**根因**：旧分类器执行“完整采集一帧，再停止读取 MAC FIFO 并重放”。16-bit@100 MHz 原始读带宽虽为200 MB/s，但每帧被处理两遍，有效能力约100 MB/s，低于千兆线速约122 MB/s；4 KiB FIFO 必然逐帧积压。不是简单的“读时钟是写时钟两倍就不会满”。

**修复**：分类器只暂存目的 MAC 的前三个16-bit word，判定后单遍流式转发；程序帧去 DMA，系统帧只提取46-byte payload，其他帧持续排空丢弃。目的 MAC、EtherType和精确长度仍在 TLAST 核对，系统帧不会污染程序路径。

**验证**：782个1042-byte程序帧以96 ns最小IFG从顶层RGMII连续输入，全部接收和DMA完成，DDR镜像800768 byte逐字节一致，MAC RX FIFO/classifier/length overflow均为0。

### 2.6 全速 RGMII 测试平台 nibble 相位错误

**现象**：某次全速重跑中原始 RX byte 几乎为0、bad frame增加，看起来像新 RX 时序仍失败。

**根因**：测试平台多个发送 task 之间多等待了一个同极性边沿，使低/高 nibble 相对 TEMAC behavioral model 错半周期；这是激励相位错误，不是 DUT 丢包。

**修复**：固定下降沿驱动低 nibble、上升沿驱动高 nibble；连续 burst 保持相位，不在帧间重新对齐到错误边沿。记录每两个帧首有效采样中心并要求间隔100 ns，对应 RX_CTL 低96 ns。

**验证**：783个相邻帧间隔（PRECONFIG一组及正式782帧一组）全部满足最小IFG，最终 `min_ifg=783`、overflow=0。

### 2.7 RX overflow 短脉冲直接跨时钟域可能漏报

**风险**：overflow 在 `rgmii_rxc` 域可能仅约8 ns，控制器在100 MHz域。直接两拍同步一个窄脉冲可能完全采不到；直接使用异步电平还可能亚稳或重复计数。

**修复**：源域检测上升沿并翻转 toggle，目的域用三级 `ASYNC_REG` 同步，再以相邻同步值异或恢复单周期事件。第一次 overflow 已是致命错误，所以不需要累计同步延迟内的多个事件。

**验证**：异步相位定向前仿覆盖无脉冲、8 ns单脉冲、持续高电平，目的域只收到一次；错误码为 `66660073`，ERROR和LED0行为正确。

### 2.8 旧版第二次 READY 的测试结束条件过早

**现象**：END 已返回 READY，但离线帧检查缺少第二个 `33333333`。

**根因**：测试平台看到状态寄存器为 READY 后只等待20 µs就结束；第二轮前仿仍需清零1 MiB模型，实际约62.8 µs，然后才能完整发送 READY 帧。

**修复**：结束条件改为必须从实际 RGMII TX 捕获第二个 READY，且总系统信息帧达到15；不能只看内部 state。

**验证**：旧版离线得到19帧=15系统信息+4日志。最终协议已改为 END 后全局复位并从 PRECONFIG 重启，因此最新顶层长仿真正确结果是18帧=14系统信息+4日志；64-cycle 复位由定向平台验证。

### 2.9 512-bit DDR 前仿模型误报合法窄事务

**现象**：PRECONFIG 数据 ATG 的 `AWSIZE=2` 被测试模型报 AXI protocol error。

**根因**：旧模型错误地强制512-bit AXI所有事务必须 `AxSIZE=6` 且地址每beat加64。Xilinx宽度转换器可以在512-bit UI上保留合法窄事务，以地址低位和WSTRB选择byte lane。

**修复**：接受 `AxSIZE<=6` 的INCR burst；按 `1<<AxSIZE` 递增地址；按 `AxADDR[5:0]` 和 `WSTRB` 更新有效byte，同时继续检查WLAST和响应。

**验证**：DDR单元、PRECONFIG和完整长仿真均重跑通过，最终两个DDR模型无协议错误。该修改只修正前仿模型，没有放宽硬件AXI错误监测。

### 2.10 执行结束时 AXI 尚未排空

**风险**：两个hart软件停止并不等于IFU/LSU所有已接受事务都已收到B/RLAST；立即把DDR owner交给其他主机会截断事务。

**修复**：分别统计EH2读写 outstanding，进入END前要求两个hart stopped、日志全部完成、`eh2_axi_idle` 连续保持16个控制周期。

**验证**：完整前仿覆盖EXECUTE→END的owner保持，定向平台覆盖END→GLOBAL_RESET→PRECONFIG；两个DDR模型无交叉owner协议错误。

### 2.11 XSim脚本把一次仿真重复运行

**现象**：日志中可能先出现fatal，随后又混入第二轮输出，PASS/FAIL语义不唯一。

**根因**：fileset同时设置非零runtime并在启动后显式执行 `run all`。

**修复**：runtime设为0 ns，只保留一次明确的 `run all`。

**验证**：最终主日志只有一轮状态序列，stderr为空，离线JSON与该轮TX帧一致。

## 3. 综合与实现问题

### 3.1 Scoped XDC 不接受条件 Tcl

**现象**：合成/实现导入 `rgmii_phy_timing.xdc` 时，带条件判断的 scoped constraint 无法按预期执行。

**根因**：Vivado在已综合设计中导入IP/分层scoped XDC时，对普通流程可用的控制语句存在限制。

**修复**：异步时钟关系改为纯XDC命令 `set_clock_groups -asynchronous`；所需时钟由更早的板级/IP约束保证存在。false path只切同步器第一拍D端，不切RGMII引脚到IDDR/IODELAY的源同步路径。

**验证**：最新时序报告无clockless寄存器，所有用户时序约束满足；RGMII输入仍保留 `-0.250/-1.250 ns` delay。

### 3.2 直接综合成功后，报告目录不存在使脚本失败

**现象**：`synth_design` 实际0 Error并完成，但写 `eh2_veri_system_top_blackboxes.rpt` 时提示目录不存在，整个批处理退出失败。

**根因**：直接综合脚本假设project run目录已经由GUI/run infrastructure创建。

**修复**：脚本在写DCP和报告前显式创建输出目录，不改变综合选项或RTL。

**验证**：重跑综合完成；峰值约9.1 GB，系统未解析黑盒0，综合阶段只保留Vivado稍后展开的dbg_hub占位。

### 3.3 MIG PHY OOC 子进程临时目录清理竞争

**现象**：`opt_design` 报 `IP_Flow 19-3805`、`Mig 66-119`，表面像DDR4 PHY综合失败；有时单核仍失败或挂起。

**根因**：两个MIG PHY子综合本身可以完成，但Windows多进程共享父Vivado的临时目录，某个子任务清理 `realtime/tmp` 或父PID临时目录时与另一个任务竞争。后续debug hub子任务还可能继承已被删除的TEMP路径。

**修复**：为实现任务使用独立的可写TEMP/TMP；先分别生成并缓存两套MIG PHY，缓存ID为DDR1 `86f64baaf1164224`、DDR0 `b55b9fbef7f26b38`；正式实现只读取缓存，避免并行重建和清理竞争。MIG参数、引脚和校准配置未改变。

**验证**：最终 `opt_design` 两套MIG均cache hit并成功展开，post_opt黑盒0。

### 3.4 debug_hub OOC 子任务挂起及缺少 dont_touch.xdc

**现象**：MIG缓存后实现停在 `Generate And Synthesize Debug Cores`；手动执行生成Tcl又报 `Common 17-275 File does not exist .../dont_touch.xdc`。

**根因**：runserver启动的debug_hub子任务继承无效临时路径，且生成Tcl使用相对路径读取 `dont_touch.xdc`；从错误工作目录手动运行时找不到该文件。

**修复**：从生成脚本中移除仅适用于runserver的connection ID，在workspace可写目录运行，复制必需的 `dont_touch.xdc`，生成debug hub缓存 `c0e21c18b6a58549`。正式实现仍使用Vivado生成的debug hub，不修改系统业务逻辑。

**验证**：后续实现debug hub cache hit，opt/place/route后的黑盒均为0。

### 3.5 前台执行环境在route_design中止，不是Vivado路由失败

**现象**：完整实现运行约6小时后外层命令返回124，日志停在 `route_design` phase 5 Delay/Skew cleanup，没有Vivado route error，也没有新routed DCP。

**根因**：外层前台执行环境达到运行时限并终止进程；Vivado当时仍在合法路由收敛。最近有效保存点是 `latest_post_physopt.dcp`，不是旧的2026-08-01 routed DCP。

**修复**：新增 `resume_latest_board_route_and_bitstream.tcl`，从最新post-physopt checkpoint继续，先检查黑盒，再用最多8个router worker完成route，保存新routed DCP，并串行执行route status、timing、bus skew、DRC和bitgen门禁。

**验证**：恢复路由约46分30秒完成，overlap从176966逐轮收敛到0，route_design为18 Info、0 Warning、0 Critical Warning、0 Error；最新实例471183条可路由网络全部完成。

### 3.6 post-place/post-physopt hold为负

**现象**：post-place为 `WHS=-0.883 ns, THS=-83.862 ns, 1620` 个失败端点；不能因setup已正就生成bitstream。phys_opt后仍为 `WHS=-0.213 ns, THS=-44.374 ns`。

**根因**：大器件、跨区域时钟/总线和短数据路径在尚未最终布线时存在min-delay不足；这是实现阶段必须继续收敛的真实hold问题。

**修复**：phys_opt插入62个LUT1/ZHOLD buffer，最终route继续进行delay/skew cleanup；没有改RTL、MIG或EH2功能。

**验证**：fully-routed报告为setup `+0.082/0`、hold `+0.010/0`、pulse width `+0.046/0`，全部失败端点为0；113个bus-skew corner/constraint项全满足，最小slack `+2.508 ns`。

### 3.7 RGMII RX hold裕量过小

**现象**：旧板级配置下RGMII RX hold仅约0.047 ns，链路在不同板卡/温度/抖动条件下可能偶发丢帧，进而表现为程序写入超时或无响应。

**根因**：PHY RX内部delay约1.50 ns时，setup裕量富余而hold侧过紧；PHY配置与XDC必须成对调整，不能只改一侧。

**修复**：DP83867 RX delay调整为约1.25 ns；XDC输入delay从 `-0.500/-1.500 ns` 同步改为 `-0.250/-1.250 ns`，保留1100 ps FPGA RX IODELAY。TX仍约2.00 ns、edge-aligned及 `-1.000/-3.000 ns`输出约束。

**验证**：PHY RTL和XDC数值一致；全速前仿无overflow。物理RGMII最终裕量仍应在上板后以ILA/计数器和温压实测回归，不能仅用behavioral simulation替代信号完整性验证。

### 3.8 位流与内存/核心数策略

**风险**：VU19P路由、timing update和bitgen峰值内存很高；盲目增加核心会提高并发数据库副本和系统提交内存，可能在最后阶段崩溃。

**处理**：最新路由使用最多8核，峰值约17.8 GB；bitgen使用2核、`BITSTREAM.GENERAL.COMPRESS=FALSE`，峰值约18.8 GB并成功。禁止与VMware、整机长仿真或另一个Vivado实现并行。若可用内存不足，优先降到4核/2核而不是追求速度。

**验证**：未压缩bitstream 199112135 byte，write_bitstream约8分17秒，14 Info、102 Warning、0 Critical Warning、0 Error。

### 3.9 方法学报告揭示的约束覆盖与异步复位风险

**现象**：最终 setup/hold/pulse-width、bus skew、route status 和 DRC 均通过，但从最新 routed DCP 生成的 `report_methodology` 仍有2893项提示。其中最容易误判的是 `TIMING-24=174`（宽范围异步时钟组覆盖 IP/XPM 的 `set_max_delay -datapath_only`）和 `LUTAR-1=13`（组合条件驱动异步 reset/preset）。原始 CDC 汇总保留 `CDC-1=160`、`CDC-7=339`、`CDC-10=33`、`CDC-11=6` 等 Critical 分类。

**根因**：整机组合了两套MIG、TEMAC、AXI CDC、EH2 EDIF和自建50/100/125 MHz逻辑；板级异步组可以正确声明“无固定相位”，但 XDC 的优先级会同时屏蔽 IP 对 Gray/握手路径设置的 datapath-only 限制。另一方面，原工程与当前控制器都存在异步复位结构，Vivado不能仅凭网表判断同步释放协议，组合译码复位还会触发毛刺风险提示。CDC Critical 是“工具无法自动证明”，不是自动等同于硬件已经失败，也不能因功能仿真通过而全部忽略。

**本次处理**：没有在 routed DCP 后临时改约束或改复位 RTL，因为这会改变已完成验证的约束/复位语义，并要求重新执行相关前仿、综合、布局布线和位流生成。已逐类核对：WAW 四槽均通过独立 XPM 异步 FIFO，RX overflow/FCS 使用源域事件加目的域同步器，结果总线使用保持数据加 request/ack，程序数据使用 AXI Clock Converter/异步 FIFO。`CDC-10=33` 中 31 位来自 TX 完成计数器的 Gray 编码组合网络，`CDC-1/7` 的大部分来自全局异步复位进入 XPM FIFO 内部复位机及 EH2/CRC 寄存器；它们不是数据 FIFO 溢出事件的裸脉冲跨域，但以后改复位时必须按域复查异步置位/同步释放。113个 bus-skew corner/constraint 全部满足，最小 slack `+2.508 ns`。`check_timing` 的 `no_clock`、未约束内部端点和 partial I/O delay 均为0；剩余无 I/O delay 仅为开关、LED、复位、MDIO/MDC和转发时钟 TXC，RGMII TXD/TX_CTL 不在该列表中。

**以后修复方法**：只要修改任何 CDC、时钟组或 reset，先将宽范围异步组收窄为端点级 false path，保留 XPM/IP 的 `set_max_delay -datapath_only` 与 bus-skew；再将业务模块的组合异步复位改为源域同步产生、目的域异步置位同步释放，并重跑受影响前仿、综合、route、CDC、methodology、bus-skew、完整时序和 bitstream。新的报告必须与当前实例基线做差异比较，不能只比较总数或通过降级告警放行。

## 4. 最终仍保留但已分类的告警

最终DRC共108项：102 Warning、6 Advisory、0 Error、0 Critical Warning。

| ID | 数量 | 结论 |
| --- | ---: | --- |
| `DPIP-2` | 7 | EH2 DSP输入流水建议；时序已通过，不改已验证网表 |
| `DPOP-3` / `DPOP-4` | 3 / 3 | EH2 DSP PREG/MREG建议 |
| `DPOR-2` | 64 | EH2乘法路径异步复位妨碍DSP寄存器合并 |
| `IOBUSSLRC-1` | 1 | 固定LED引脚跨SLR，不是高速并行总线 |
| `PDCN-1569` | 3 | Vivado生成的dbg_hub LUT未使用物理输入 |
| `REQP-1859` | 20 | EH2 DCCM/ICCM/I-cache URAM parity-interleaved BWE8提示；保留原网表 |
| `RTSTAT-10` | 1 | 417条MIG校准/XSDB等无可路由负载分支；可路由网络错误仍为0 |
| `AVAL-155` | 4 | DSP未使用D端口的功耗建议 |
| `SECHK-3` / `SECHK-4` | 1 / 1 | GT line-rate与I/O数量均在器件限制内 |

Vivado启动时的 `Common 17-741` 表示本机 `C` 位置的可选Tcl Store不可写，工具回退到安装目录；它不属于设计DRC，未影响IP、route或bitstream。打开post-physopt DCP时6条MIG内部DRIVE/SLEW/IBUF_LOW_PWR恢复提示也只涉及未直接连到顶层端口的MIG内部网络，最终两套MIG已实现且无黑盒。

这些告警只能按当前实例范围接受。以后任何新增DRC Error/Critical Warning、未解析黑盒、route error、新的高速跨SLR/CDC告警，或上述ID指向新的业务模块，都必须重新审查，不能用降级告警代替修复。

最终方法学报告的分类基线为：`DPIR-2=131`、`HPDR-2=2520`、`LUTAR-1=13`、`TIMING-9=1`、`TIMING-18=18`、`TIMING-24=174`、`TIMING-47=16`、`XDCC-1/4/7/8=6/3/5/3`、`CLKC-56=1 Advisory`、`RTGT-1=2 Advisory`。该基线不是“零方法学风险”声明；它用于以后按实例做diff。特别是 `TIMING-24`、`LUTAR-1`、新的裸业务总线 CDC 或任何高速端口缺少 I/O delay，都必须按上一节流程处理。

## 5. 防止复发的交付门禁

每次RTL、网表、IP参数或板级XDC改变后，至少执行以下检查：

1. 重跑受影响单元前仿；涉及程序路径、状态机、hash/WAW或EH2时重跑782帧闭环长仿真和离线帧比较。
2. 核对程序BIN SHA-256、782帧、DDR起始地址 `0x80000000` 和结束帧总数。
3. 综合后检查层次利用率和系统未解析黑盒0；不能只看Vivado“综合成功”。
4. post_opt和post_route再次检查黑盒0；route status必须unrouted/error=0。
5. 在最终routed DCP上同时要求WNS/TNS、WHS/THS、WPWS/TPWS、bus skew全通过，且0个无时钟寄存器。
6. DRC Error/Critical Warning必须为0；Warning按实例与本文件基线做diff。
7. PHY RGMII delay和XDC必须同步修改；不能用异步组误切外部源同步I/O路径。
8. 只从最新checkpoint生成bitstream；用 `output/board/SHA256SUMS.txt` 确认没有误用早期DCP或bit文件。
9. 资源策略先保证内存：实现最多8核、bitgen 2核且不并行运行VM/长仿真；内存不足立即降核。
10. 保存并比较 `cdc.rpt` 与 `methodology.rpt`；关注实例而不是只看总数，确保没有新增裸多位总线 CDC、组合逻辑后同步器、被异步组覆盖的新 datapath-only 约束或业务模块组合异步复位。
11. `check_timing` 必须保持 `no_clock=0`、`unconstrained_internal_endpoints=0`、`partial_input_delay=0`、`partial_output_delay=0`；RGMII TXD/TX_CTL 不能出现在无输出 delay 列表。
