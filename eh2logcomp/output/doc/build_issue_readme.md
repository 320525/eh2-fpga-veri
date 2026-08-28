# EH2LOGCOMP 构建、验证及板级问题归因与修复记录

## 1. 文档范围

本文记录两类问题：

1. 原 `eh2fpga_veri_system` 在双 hart、程序下载、RGMII 接收和 WAW 日志路径中暴露的问题，以及这些问题对新系统设计的影响。
2. `eh2logcomp` 在逐指令 Info Struct、DDR1 搬运、双整帧缓冲、综合实现和时序收敛过程中实际遇到的问题。

本工程不再输出 CRC/hash package，也不再维护独立的 WAW 序号帧。WAW 信息与被取消的 victim 指令记录原子地保存在同一条 Info Struct 中。旧问题的历史分析不能直接解释为新位流仍有同一缺陷。

## 2. 原系统双 hart 启动错误

### 2.1 现象

早期仿真中 hart0 正常执行，而 hart1 没有产生预期提交记录，最终结果与双 hart 参考值不符。

### 2.2 根因

EH2 的 hart1 不是仅靠“顶层释放处理器复位”就自动开始运行。硬件启动请求 `mpc_reset_run_req` 必须允许 hart1，启动软件还必须由 hart0 写入 CSR `0x7FC` 的 hart1 启动位。原连接把请求保持成仅 hart0 有效，导致软件写 CSR 后仍不能形成完整的 hart1 启动条件。

### 2.3 修复

- 硬件启动请求配置为双 hart 允许，其中 hart1 对应位为 1。
- 程序开头只让 hart0 执行一次 `csrw 0x7FC`，写入 hart1 启动位。
- 仿真同时检查两个 hart 的开始、结束和提交计数，避免只根据全局执行结束误判。

## 3. 原系统 WAW 序号跨 hart 污染

### 3.1 现象与证据

板级日志中 hart0 的四个真实 WAW 能全部识别，但有时还会多出若干序号。多出的 hart0 序号总位于 hart1 相邻 WAW 序号对之间，例如历史数据中 hart0 的期望为 `18,20,26,28`，而异常值会出现 `50`、`154`、`290`、`426` 等；这些值与 hart1 的独立序号模式高度相关。与此同时 CRC/hash 主结果仍可能正确。

这说明处理器提交内容本身没有多执行指令，错误发生在独立的 WAW 旁带事件路径，而不是归约算法主体。

### 3.2 原因

旧设计把 WAW 作为独立事件，从 EH2 50 MHz 域经过多槽 CDC FIFO，再在 100 MHz 域按 hart/package/bank 存储。该路径同时存在：

- hart、package、sequence 分开选择和存储，配对依赖额外控制状态；
- 多槽事件在同周期合并时需要再次分组、排序和累加地址；
- bank 复用及会话软复位使“旧事件、旧归属、当前写地址”可能不处于同一个原子事务；
- 错误值正好落在另一个 hart 的相邻事件中间，符合旁带归属或复位边界污染，而不符合 EH2 真正新增提交。

### 3.3 eh2logcomp 的结构性修复

新系统取消独立 WAW 序号表和 package/bank：

- hart0、hart1 各自维护独立的 32-bit sequence。
- WAW 发生时修改被取消的 victim 记录本身。
- `waw_cancel_kind`、`waw_cancel_number`、hart、victim sequence、PC、指令和数据在同一条 Info Struct 内一次写入同一 hart FIFO。
- 每个 hart 使用独立采集表、独立 FIFO、独立 DDR1 地址区和独立发送源 MAC。
- 全局复位同时清除两个 hart 的 sequence、非阻塞匹配表、FIFO 指针、DDR DMA 状态和发送会话。

因此不存在把某个 hart 的 WAW 序号再次装入另一个 hart 的独立 WAW 列表这一结构。单元仿真已覆盖同周期多条、奇数尾记录和非阻塞返回；最终仍应在板上执行多轮双 hart 程序，确认每条 WAW victim 的 hart、sequence 和 cancel number 均一致。

## 4. 原系统程序下载偶发丢包、超时或无响应

### 4.1 现象

一次硬复位后，如果第一次大程序下载正常，同一次上电会话内后续多次通常都正常；如果第一次丢包或超时，后续轮次会持续表现相同，只有再次复位才改变结果。PRECONFIG 的单帧检查可能通过，而 782 帧连续发送仍可能失败。

### 4.2 RGMII 时序根因

DP83867 内部延迟、FPGA IDELAY 校准和 RGMII RXC 启动相位在每次复位后重新建立。旧配置的采样点接近数据眼边缘：

- 相位较好时，长帧序列可以持续正确接收；
- 边缘相位下，单帧可能通过，但 782 帧中至少一帧出现 FCS 错误或帧损坏；
- 更差时，程序帧和结束帧都不能进入 MAC 用户侧，表现为无响应或 20 秒 overtime。

这种“每次复位决定本轮长期好坏”的相关性，是固定相位裕量不足而不是随机软件停顿的典型特征。

### 4.3 修复

- DP83867 采用 RGMII_ID，TX 内部延迟配置为 2.00 ns，RX 内部延迟配置为 1.00 ns。
- FPGA RX IDELAY 配置为 1.10 ns，把采样点移动到具有更大裕量的位置。
- RGMII 输入约束与实际 PHY+FPGA 延迟组合一致：RX 最大 0 ns、最小 -1 ns；TX 最大 -1 ns、最小 -3 ns。
- 333.333 MHz 参考时钟用于 IDELAYCTRL 的稳定校准。
- 增加确定性的 RX 启动放行：等待 PHY 初始化、链路建立、IDELAY 校准完成及 RX 时钟连续稳定后，才允许程序分类器接收有效帧。
- TEMAC FCS 错误计数和错误码 `0x66660075` 纳入系统错误处理。

最终实现的保持裕量仍只有 `+0.009 ns`，任何 PHY delay、IDELAY、引脚、时钟或 RGMII RTL 修改都必须重新进行 setup/hold、clock interaction 和板上长包压力测试。

## 5. RX FIFO 溢出原因

旧分类器先把完整以太网帧写入内部缓冲，帧尾确认目的 MAC 后再逐字重放。接收一帧耗费一段“写入时间”和一段“重放时间”，有效处理吞吐约为线速的一半。连续最大速率帧到达时，即使后级 FIFO 的瞬时读时钟是写时钟两倍，分类器的整帧存储/重放阶段仍会形成净积压。

修复后的接收路径只缓存判断目的 MAC 所需的前三个 16-bit 字，然后以流方式把余下数据送往目标通路。程序帧和系统帧使用不同目的 MAC、不同 EtherType 和不同 FIFO，系统结束帧不会进入程序 payload DMA。帧号不连续时立即上报一次错误并停止会话；结束帧仍用于核对总包数。

## 6. PROGRAM_WRITE 完成条件和错误停止握手

PROGRAM_WRITE 不能只根据“收到结束帧”或某个瞬时 `dma_done` 判断完成。当前完成条件同时要求：

- 已收到结束帧；
- 结束帧中的总帧数与实际接受的连续程序帧数相同；
- 最后一帧对应的 S2MM DMA 已完成；
- DMA/AXI 写通道已回到 idle；
- 没有帧号、长度、FIFO、FCS、DMA 或 AXI 错误。

错误一旦出现，FPGA 只发送一次对应错误码。WebUI 收到错误码后立即取消尚未提交的程序帧，并发送 `0x44124445`，表示主机已经停止。FPGA 收到确认后启动持续 64 个 100 MHz 控制时钟周期的全局复位，重新进入 PRECONFIG。正常程序和日志发送结束后也经过同一全局复位流程，避免旧会话残留。

## 7. DDR1 写 DMA 初始时序问题

### 7.1 现象

早期实现功能仿真正确，但综合后 DDR1 写地址/数据路径出现负裕量，典型路径约为：

- 从 XPM 异步 FIFO 的同步写计数、capture count 和当前 DDR 地址直接组合计算下一笔 AXI AW，逻辑层数约 19 层，曾出现约 `-0.206 ns`。
- 多个 AXI 写数据源在 MIG 前进行宽组合选择，曾出现约 `-0.745 ns`。

### 7.2 修复

- 把 burst 规划拆为 PLAN、LIMIT、CHECK 等寄存阶段。
- 规划开始时快照 FIFO 占用、capture done 和当前地址，不让跨域同步计数直接进入 AW 输出。
- burst 同时限制为剩余数据、最大 64 beat 和 4 KiB 边界三者的最小值。
- 在 MIG 前增加 AXI W 通道弹性寄存切片，打断宽数据和 ready 组合链。
- FIFO 读 lane 改为 one-hot 选择，缩短多路大位宽选择路径。

## 8. DDR1 读 DMA 与发送 FIFO 溢出

### 8.1 旧流式设计的真实缺陷

旧读 DMA 根据异步 FIFO 同步回来的“剩余空间”决定是否发出最多 64-beat AXI burst。AXI 的 AR 握手一旦完成，DDR 已承诺返回整笔 burst。由于空间计数跨时钟同步有延迟，FIFO 接近满时仍可能错误地规划一笔完整 burst。MAC 随后产生背压时，这些已经在途的数据无法撤回，最终触发 `data_overflow`。

这不是 Info Struct 内容错误，也不是 MAC 丢帧；根因是用滞后的瞬时空间控制不可撤销的 AXI burst。

### 8.2 最终两整帧槽修复

最终设计不再用“剩余字节 FIFO”承接任意长度 burst：

- 每个数据帧固定含 60 条记录槽；DDR1 只真实读取 `ceil(valid_records/2)` 个 512-bit beat，DMA 本地补零到固定 30 beat 后交给帧构造器。
- UI 域在启动 DMA 前原子占用一个完整帧槽并置 dirty。
- 30 个 beat 全部到达后，帧槽才翻转 publish；TX 域看不到半帧。
- TX 域送完最后一个字节并完成握手后翻转 release，UI 域同步看到 release 后才复用该槽。
- 两个槽都被占用时，读 DMA 不会发出下一帧 AR，因此所有已发出的真实 DDR beat 以及随后的本地补零 beat 都有确定存放位置。
- 最后一帧不足 60 条时，DDR 只读取有效 ECC 行；DMA 本地补零到 30 beat，构帧时只保留实际记录，其余 24-byte 位置补零。
- 有效 DDR 读拍遇到 4 KiB 边界时会拆为多笔合法 AXI burst，但真实拍和本地补零拍仍写入同一帧槽的连续索引。

这种帧粒度预留彻底去除了“同步后空闲计数可能过时”的决策条件。压力仿真覆盖两个槽均满、MAC 长时间背压、恢复发送、帧顺序和数据完整性。

## 9. 实现阶段的拥塞与时序收敛

实现过程先保留所有功能并让每个阶段完整运行，以收集全部错误，再统一修改：

- 综合阶段使用 4 个线程。
- `opt_design` 使用 1 个线程，降低内存峰值。
- `place_design` 使用 2 个线程，峰值约 13.93 GB。
- `route_design` 脚本设置 2 线程，但 Vivado 路由器内部报告最多使用 8 个 CPU；本轮峰值约 19.10 GB。
- bitstream 使用 1 个线程。

物理优化曾报告最差 setup 约 `-0.198 ns`；最终 route/物理修复后：

| 指标 | 最终值 |
| --- | ---: |
| WNS | +0.045 ns（2026-08-25 完整重建） |
| TNS | 0 ns |
| WHS | +0.009 ns |
| THS | 0 ns |
| WPWS | +0.046 ns |
| 完成布线网络 | 376352 / 376352 |
| Routing Errors | 0 |
| DRC Errors | 0 |

bitstream 生成结果为 0 Error、0 Critical Warning。普通 Warning/Advisory 仍包括部分未使用 URAM 端口、MIG 未连接可选状态负载、DSP 属性建议、帧槽 set/reset 风格提示，以及 DDR 记录低 64-bit 保留位未使用等。它们不等同于错误，但后续更改必须逐条复核，不能只看“能生成 bit”。

## 10. Vivado 高内存崩溃和缓存问题

双 DDR MIG、超大器件、EH2 网表和宽 AXI 路径会使 place/route 占用大量内存。过多并行线程可能导致操作系统交换或进程被终止；MIG OOC 产物和临时缓存被多个流程同时生成时，也可能造成锁、缓存不完整或重复占用。

最终采用“综合 4、优化 1、布局 2、布线 8、位流 1”的组合，并避免并行启动多个 Vivado 实例。修改 MIG/XCI、器件、约束或顶层后必须重新生成相关 OOC、重新综合和完整实现，不能复用不匹配的 DCP。

## 11. 前仿验证边界

已完成：

- 顶层从 RGMII/MAC RX 注入 PRECONFIG 帧和 782 个连续程序帧，经正式程序 DMA 写入 DDR0；
- DDR0 镜像与 800640-byte 程序逐字节一致；
- 双 hart 启动、执行和逐指令 Info 捕获；
- 每 hart 4-write 异步 FIFO、奇数尾记录、写 DMA；
- 有效 DDR 行真实读取、本地补零到固定 30 beat、4 KiB 分割；
- 双完整帧槽的 full、dirty、publish、release、背压恢复与数据顺序；
- WebUI 对最终 60-record/帧协议的 20 万级记录接收与完成帧核对。

最终两帧槽版本没有再次运行耗时很长的“20 万条记录全部穿过物理 TEMAC TX 后逐帧回读”闭环。用户要求的最终验证边界是：处理器执行 20 万级指令并把记录正确写入发送帧槽，同时对帧槽单独做压力测试。板级首次使用仍必须执行多轮满速回传，并保存 PCAP/CSV/JSON 会话证据。

## 12. 后续最容易忽略的事项

1. `+0.045 ns` setup 和 `+0.009 ns` hold 都很窄，任何 RTL/XDC/IP 改动都要从综合重新跑到 bitstream。
2. 不要把 24-byte 网络记录误写成 32-byte DDR 记录；网络丢弃低 64-bit 保留区。
3. 数据帧是 4-byte frame number 加 60 条记录，payload 固定 1444 Byte；最后一帧只能尾部补零。
4. hart1 位于 DDR1 低 4 GiB，hart0 位于高 4 GiB；顺序是 H0 数据、H0 done、H1 数据、H1 done。
5. 系统信息帧仍为 EtherType `0x88B5`、46-byte payload，不经过 Info 双帧槽。
6. 不得在两个完整帧槽均占用时发出新的 DDR1 AR。
7. AXI burst 不得跨 4 KiB；AR 接受后必须保证整笔 R 数据有落点。
8. 程序结束帧到达不等于 PROGRAM_WRITE 完成，必须等待最后一帧 DMA 和 AXI idle。
9. WebUI 必须先监听再发送；收到 FPGA error 后必须停止批量发送并回送停止确认。
10. PHY 延迟、FPGA IDELAY 和 XDC 输入/输出延迟必须作为一个整体修改，不能只调整其中一项。

## 13. riscv-dv 10k 程序无法稳定执行结束

### 13.1 “硬件包络”的含义

riscv-dv 生成的是随机指令主体，不负责本板卡专有的启动和结束协议。这里的“硬件包络”是包在随机主体外面的确定性汇编：复位入口、每 hart 栈、DCCM 原子页清零、仅 hart0 执行的 `csrw 0x7FC`、hart1 启动等待、两个 hart 的结束 MMIO，以及为硬件 ELF/Spike ELF 保持相同 PC 而使用的等长替换指令。没有这层包络，即使随机主体本身合法，控制器也可能永远等不到 hart1 start 或某个 hart 的 stop。

### 13.2 实际不结束条件

1. 随机 branch/jump 会使静态生成的 10k 指令并不等于一定执行 10k 条；随机回跳、跳过结束入口或随机子程序路径可能使本轮很久不到达统一尾部。当前自动化目标是快速、确定地执行全部随机主体，因此使用 `+no_branch_jump=1` 和 `+num_of_sub_program=0`；这不是 EH2 不支持分支，而是当前比较模式主动去掉不可预测控制流。
2. EH2 当前配置只允许 AMO/LR/SC 访问内部 DCCM。把整个数据段放在外部 DDR 会使普通 load/store 正常而原子事务异常，表现为某个 hart 不再到达结束。
3. riscv-dv 原始 `amo_0` 页由两个 hart 共享。即使地址合法，双 hart 对同一原子页的竞争顺序在 EH2 与 Spike 中也可能不同，导致后续寄存器/控制流不一致。
4. 数据段若与 `0x80000000` 程序镜像重叠，会在执行期间破坏指令；若把稀疏高地址数据作为普通 PROGBITS 合入单一 LOAD，objcopy 还会产生巨大空洞 BIN，破坏原有连续程序烧写协议。

### 13.3 最终修复

- IFU/烧写区保持 `[0x80000000,0xA0000000)`，程序 DMA 和复位向量完全不变。
- 所有随机 LSU 访问的总包络限制为 `0xA0000000–0xFFFFFFFF`。
- 普通 load/store、栈和 NOLOAD 数据使用外部 DDR0 `[0xA0000000,0xD0000000)`。
- AMO/LR/SC 固定到真实 64 KiB DCCM `[0xF0040000,0xF0050000)`，把共享 `amo_0` 拆成 hart0/hart1 两个私有 64-Byte 页；hart0 在启动 hart1 前显式清零两页。
- linker 使用 program/data/amo 三个 PT_LOAD，data/amo `FileSiz=0`，BIN 仍只包含连续程序字节。
- worker 对入口、区间、重叠、ELF 段、镜像大小和两 ELF 补丁 PC 做硬检查，失败立即停止该轮。

最终 seed `32052517` 的 88,040-Byte BIN、86 个程序帧在顶层闭环中执行结束，hart0/hart1 产生 `12116/12601` 条记录。

## 14. DDR1 写 DMA 的 AW/W 永久等待

Info FIFO 的读侧前面增加了两级 elastic queue，用于切断 266.525 MHz 下 XPM 指针、MIG `WREADY` 和 burst 规划之间的组合路径。早期顶层把 XPM 的 `rd_occupancy` 与 elastic 中的 `buffered_records` 相加后交给 DMA。但 XPM 读计数在刚弹出数据时可能仍包含已经进入 elastic 的同一批记录，因此发生重复计数。

例如实际只剩 1 个 512-bit beat，规划器却看到 2 个并发出 `AWLEN=1`。AXI AW 握手后从设备已接受“必须有 2 个 W beat”的承诺，DMA 不能在中途缩短；第一个 beat 发出后永远等不到并不存在的第二个 beat，所以 DDR1 写 DMA busy 不结束，系统最终报告 DDR1 DMA/双缓冲相关错误。

修复后 burst 规划只采用保守的 XPM `rd_occupancy`；`empty` 则仍要求 XPM 与 elastic 同时空。若 XPM 计数暂时低估，规划器用单 beat fallback 排出 elastic 尾部。这样会偶尔少合并一个 burst，但绝不会声明超过真实数据量的 AW。定向结果为 hart0 259、hart1 150 条记录全部写完，随后 10k 顶层闭环通过。

## 15. END 回传同一帧被重复启动

`read_start` 和 `build_start` 是控制器寄存后发给读 DMA/帧槽的单周期请求。旧调度条件只检查 `read_busy=0` 和帧槽可用；在发出请求后的下一拍，下游尚未来得及把 `busy` 拉高，调度器会再次认为可以启动，从而对同一 `frame_number` 发出第二次请求。短的一帧测试不容易暴露，多帧回传会表现为记录重复、帧号异常或双槽 protocol error。

最终启动条件同时要求：

```text
!read_done && !read_busy && !read_start && !build_start
&& build_ready && !frame_fifo_full_ui && records_remaining != 0
```

`read_done` 还具有优先级，确保本帧完成后的 frame number 和 remaining count 先更新，下一帧再规划。多帧单元测试覆盖 6 个数据帧、2 个完成帧和 TX 背压，最终顶层发出 413 个数据帧与 2 个完成帧且无重复。

## 16. WAW 记录到达顺序与比较器误判

普通/direct WAW 记录可在提交当拍直接输出；nonblock load/divide 的较老记录必须等结果返回或被 WAW 取消后才能补全。因此网络/DDR 中合法的物理到达顺序可能出现“较新的直接记录先于较老的延迟记录”。这不是 sequence 生成错误，也不能通过强制采集器阻塞所有后续提交来修正，否则会改变 EH2 原有行为并显著增加溢出风险。

顶层仿真和 WebUI 比较器改为逐 hart sequence coverage bitmap：允许合法乱序；每个 sequence 必须恰好出现一次，重复、越界、缺失仍失败。WAW victim 的 `waw_cancel_kind`、`waw_cancel_number` 和 data 清零仍在该 victim 自身记录中比较。WebUI 定向测试同时覆盖“乱序但完整应 PASS”和“重复 sequence 必须 FAIL”。

## 17. RGMII RX routed hold 违例和最终合法修复

### 17.1 原始结果

主实现完成后主体逻辑建立时序通过，但 5 条 `rgmii_rxd[3:0]/rgmii_rx_ctl` 到 IDDRE1 的外部输入保持路径最差为 `-0.074 ns`。原约束把合并后的 RXC BUFG 网固定到 `X3Y2`，在当前四 SLR 大设计中该根的捕获时钟延迟与数据路径不再平衡。仅凭 PRECONFIG 单帧能接收不能证明该裕量足够；它与板上“复位后本轮一直好/一直坏”的统计特征一致。

### 17.2 被拒绝的方案

- 把五个 IDELAYE3 从 1100 ps 改为 1250 ps，时序数字曾显示 setup `+0.007 ns`、hold `+0.010 ns`，但 DRC 对五个单元报 `AVAL-174`：在 333.333 MHz 参考时钟下合法范围上限是 1100 ps。因此该 DCP/报告只是负面试验，未生成最终位流。
- 把 RXC 根直接移到 `X0Y1`，保持改善但外部 setup 变为 `-0.181 ns`，不平衡。
- 对已路由 clock net 直接使用普通 `route_design -auto_delay -nets` 既不是 UltraScale+ clock gap tree 的正确重建方式，也曾把内存推到约 24 GiB；不采用。
- 只执行 `update_clock_routing` 而不补齐剩余 gap 会留下 `RTSTAT-2` partially routed；即使某个时序数字看似可用，也不能签核。

### 17.3 正确流程与最终结果

每个候选都从同一个未被试验修改的 routed DCP 开始，只处理合并后的 RXC 网：设置 `USER_CLOCK_ROOT`，`route_design -unroute -nets`，`update_clock_routing -net` 重建时钟树，再 `route_design -nets` 补齐 gap。扫描结果：

| root | 外部 setup | 外部 hold | route |
| --- | ---: | ---: | --- |
| X3Y1 | +0.411 ns | -0.003 ns | 完整，但 hold 失败 |
| X2Y2 | +0.254 ns | +0.306 ns | 完整，最终采用 |
| X2Y1 | +0.215 ns | +0.377 ns | 完整 |
| X1Y2 | +0.058 ns | +0.686 ns | 完整 |
| X1Y1 | +0.019 ns | +0.757 ns | 完整 |

以 setup/hold 两者最小值最大的原则选择 `X2Y2`。2026-08-25 完整重建的最终签核为全局 setup `+0.045 ns`、hold `+0.009 ns`，routing errors 0、74 组 bus-skew 最差 `+2.218 ns`、severe DRC 0、blackbox 0，Bitgen 成功。正式 XDC 和兼容脚本均固定为合法的 1100 ps 配置，旧 1250 ps 入口不得用于交付。
