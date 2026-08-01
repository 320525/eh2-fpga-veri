# 双 hart EH2 指令 CRC/归约与 FPGA 集成说明

## 1. 实现范围

本目录包含以下内容：

- 带双 hart 提交监控接口的 EH2 Synplify EDIF；
- 每 hart 独立的指令序号、非阻塞缓冲区、CRC 缓冲区；
- 每 hart 两个按 package 奇偶交替使用的 FIFO；
- 每条 instruction struct 的两路 CRC-64；
- FIFO 读侧的 G0～G3、XOR0～XOR1、SUM0～SUM3 归约；
- 1000 条单 hart FPGA 程序、约 20 万条双 hart 前仿程序；
- Spike 软件金标生成、RTL 结构/归约结果复核脚本；
- VU19P FPGA 顶层、约束、Vivado 批处理构建与 LED 判定。

FPGA 内仍保留完整双 hart EH2 和双 hart CRC 硬件，但上板程序只启动 hart0。约 20 万条前仿会启动两个 hart。

## 2. instruction struct

每条结构固定为 160 bit，由五个 32-bit 字组成，拼接顺序如下：

| 位段 | 宽度 | 含义 |
|---|---:|---|
| `[159:144]` | 16 | Package Number |
| `[143:128]` | 16 | Sequence Number |
| `[127:96]` | 32 | PC |
| `[95:64]` | 32 | 指令编码 |
| `[63:49]` | 15 | 保留，恒为 0 |
| `[48]` | 1 | hart_id |
| `[47:46]` | 2 | priv_mode；EH2 本配置只执行 M-mode，值为 `2'b11` |
| `[45:44]` | 2 | event_type：0=无架构写，1=GPR，2=CSR |
| `[43:32]` | 12 | GPR/CSR 编号；GPR 使用低 5 bit |
| `[31:0]` | 32 | 架构写入数据 |

序号在每个 hart 内独立维护。每个 package 的 Sequence Number 从 0 到 65535；提交第 65536 条指令后，下条指令的 Sequence Number 回到 0，Package Number 加 1。i0、i1 同周期同 hart 提交时按 i0 后 i1 的年龄顺序分配序号。

普通不写寄存器的指令仍生成结构，但 `event_type/reg_num/data` 为 0。被 WAW 取消的指令保留 package、sequence、PC、指令、hart、特权模式、event type 和目的寄存器号，仅把 `data` 清零。

## 3. CRC-64 算法

实现采用非反射的 CRC-64/ECMA-182：

- 多项式：`0x42F0E1EBA9EA3693`；
- refin=false，refout=false；
- xorout=`0x0000000000000000`；
- 160-bit 数据从 bit159 到 bit0 输入，即 Word4 到 Word0、每字 MSB first；
- C0 的初值为 `0x0000000000000000`；
- C1 的初值为 `0xFFFFFFFFFFFFFFFF`。

单 bit 更新为：

```text
feedback = crc[63] XOR input_bit
crc      = crc << 1
if feedback: crc = crc XOR 0x42F0E1EBA9EA3693
```

对固定 160-bit 消息长度，两个初值的 CRC 之差是常量，因此硬件只实现一套数据相关的 160 级组合 CRC 网络：

```text
C0 = CRC(data, 0x0000000000000000)
C1 = C0 XOR 0xC2D822EDD2DBFBB1
```

该常量等价于 `CRC(data, 0xFFFFFFFFFFFFFFFF)` 与 C0 的异或差，软件模型和 RTL 已逐项验证。这样每条结构仍得到两条独立定义的 CRC 值，但不重复第二套完整组合网络。

双 hart 实现包含 2 个直接提交 CRC 对以及 `2 hart × 31 rd` 个非阻塞 CRC 对，共 64 个 `crc64_ecma_pair_160` 实例。每个实例内部只有一套完整数据相关 CRC 网络。该并行结构资源较大，但非阻塞表项一旦数据确定即可独立计算并释放 instruction struct buffer，避免集中式 CRC 端口形成回压。最终资源和时序以 `vivado_build/reports` 中报告为准。

## 4. WAW 和非阻塞处理

监控逻辑覆盖三类会使旧指令不更新架构 GPR 的 WAW：

1. 同周期、同 hart 的 i0/i1 写同一非零 GPR，较老的 i0 被较新的 i1 覆盖；
2. 旧 load/div 数据返回前，较新指令写同一 hart、同一 GPR，旧非阻塞写被取消；
3. load/div 数据返回的同周期，较新指令写同一 GPR，EH2 最终写使能取消旧写。

直接提交指令由 `rv_commit_waw_victim` 指示，结构立即生成且 data=0。旧非阻塞受害者由 `rv_nb_waw_valid`、victim hart/rd/PC/insn/type 定位；相应 buffer 的 data 被写 0 并进入 resolved 状态。取消判定优先于 load/div 返回数据，所以“返回周期同时 WAW”也一定保留 data=0。

每个 hart 对 x1～x31 各设一个 160-bit instruction struct buffer，索引就是目的 GPR；另设 31 个 128-bit CRC buffer 保存 `{C1,C0}`。提交监控直接取 EH2 的原始 WB 提交拍，不再经过 WB+1 延迟。流程为：

1. 任意指令在 EH2 提交拍立即分配 package/sequence 并累计提交数；
2. 非阻塞 load/div 若在提交拍已经返回数据，直接形成完整结构并走普通指令 CRC 路径，不占用 instruction struct buffer；
3. 提交拍尚未返回数据的 load/div 才把未决结构写入 `nb_struct[hart][rd]`；以后正常返回时填入 data，WAW 取消时填 0；
4. buffer 中的结构只有在 data 确定后才计算 CRC；
5. CRC 写入独立 CRC buffer 的同一拍，instruction struct buffer 即可释放；
6. CRC buffer 被送入目标 package FIFO 后才释放。

EH2 的 div（以及允许出现的 load 边界情况）可能在提交拍给出最终写回。该情况不会先分配 buffer 再释放，而是按 type、hart 和 rd 严格匹配返回值，把完整 instruction struct 直接送入普通 CRC 路径。定向测试 `tb_nonblock_same_cycle_return.sv` 同时验证“div 提交拍返回直接 CRC、不占 buffer”和“load 提交后延迟返回、先进入 buffer 再 CRC”。

若提交时相同 hart/rd 的 instruction struct buffer 仍忙，`buffer_conflict` 输出一个 core-clock 周期的脉冲。FIFO 空间不足产生 `fifo_overflow`；package 奇偶复用的 bank 尚未释放则产生 `bank_conflict`。SoC 把三类错误锁存，FPGA 金标比较不会在有错误时点亮 LED0。

每个 hart 的 31 个非阻塞 CRC buffer 可能同时有多个结果等待送入 FIFO。调度器每拍最多选择 4 个，直接提交的 i0/i1 优先，其余按 GPR 编号由小到大选择。实现中用 `mask & (~mask + 1)` 隔离最低有效位，重复四次得到四个固定候选，再映射到四个固定输出槽。这样既保持原有选择顺序和每拍四项吞吐率，也避免把 31 次循环中的通用整数计数综合成串行进位链。旧写法在综合后形成 57 个 CARRY8、共 180 级的最差路径；当前固定宽度写法专门用于消除该路径。

EH2 每拍可同时给出一个最终有效的非阻塞 load 写回和一个 div 写回。两者若是不同的 hart/rd，`nb_struct[hart][rd]` 的两个独立表项在同一个时钟沿并行写入各自 data 并置 resolved，不需要排队。EH2 GPR 本身也为普通 i0、普通 i1、非阻塞 load 和 div 设置四个写端口，并带有“同一 hart/rd 不允许两个写端口同时有效”的断言；因此 load 与 div 同拍指向完全相同表项不是合法的最终写回组合，必须先由 EH2 WAW/CAM 取消旧写。定向测试 `tb_nonblock_same_cycle_return.sv` 已覆盖同拍返回 hart0/x11 load=`a1b2c3d4` 与 hart0/x12 div=`5a6b7c8d`，两个表项均并行 resolved 并生成 CRC。

## 5. EH2 顶层新增监控接口

以下 lane 数组均为 `[1:0]`，lane0=i0、lane1=i1，同一 lane 的所有字段属于同一拍的同一条提交指令：

| 信号 | 含义 |
|---|---|
| `rv_commit_valid` | 提交有效，每个有效 lane 对应一条动态提交指令 |
| `rv_commit_insn` / `rv_commit_pc` | 32-bit 指令和 PC |
| `rv_commit_hart_id` | 提交指令所属 hart |
| `rv_commit_priv_mode` | 提交时特权模式；当前 EH2 配置为 M-mode |
| `rv_commit_gpr_wen_intent` | 指令语义上准备写 GPR，包括被非阻塞化的写 |
| `rv_commit_gpr_wen` | 该提交拍真正使用普通 GPR 写口写入 |
| `rv_commit_gpr_rd` / `rv_commit_gpr_wdata` | 普通写口目的 GPR 和数据 |
| `rv_commit_csr_wen` | CSR 写有效 |
| `rv_commit_csr_addr` / `rv_commit_csr_wdata` | CSR 编号和写数据 |
| `rv_commit_is_nonblock` | load 或 div 非阻塞提交 |
| `rv_commit_is_nonblock_load` | 非阻塞 load |
| `rv_commit_is_nonblock_div` | 非阻塞 div |
| `rv_commit_waw_victim` | 本 lane 的提交指令本身被同拍 WAW 取消 GPR 写 |

旧非阻塞 WAW 受害者接口：

| 信号 | 含义 |
|---|---|
| `rv_nb_waw_valid[1:0]` | 当前 lane 的较新指令取消了一条旧非阻塞写 |
| `rv_nb_waw_victim_insn/pc` | 被取消旧指令的指令编码和 PC |
| `rv_nb_waw_victim_hart_id` | 被取消旧指令的 hart |
| `rv_nb_waw_victim_gpr_rd` | 被取消旧指令的目的 GPR |
| `rv_nb_waw_victim_is_load/div` | 旧指令类型 |

最终非阻塞写回接口：

| 信号 | 含义 |
|---|---|
| `rv_nb_load_gpr_wen` | WAW 过滤后的 load 最终写 GPR 有效 |
| `rv_nb_load_gpr_hart_id/rd/wdata` | load 写回 hart、目的 GPR、数据 |
| `rv_nb_div_gpr_wen` | WAW 过滤后的 div 最终写 GPR 有效 |
| `rv_nb_div_gpr_hart_id/rd/wdata` | div 写回 hart、目的 GPR、数据 |

这些信号来自 EH2 WB/非阻塞 CAM/除法写回的最终控制点，不根据反汇编静态猜测 WAW。

## 6. FIFO、last 和 package 轮转

每个 hart 有两个逻辑 FIFO，bank=`Package Number[0]`，所以 package0/2/4 使用 bank0，package1/3/5 使用 bank1。一个 bank 只有在读侧收到 last、输出六个归约结果并把 release toggle 同步回 core 时钟域后才可被下下个 package 复用。

每个逻辑 FIFO 深度 128、单项宽 129 bit：

```text
bit128     last
bit127:64  C1
bit63:0    C0
```

逻辑 FIFO 由四个 32×129 的 Xilinx XPM 异步 FIFO lane 组成。50 MHz 写侧最多同拍接受 4 个 CRC 对，按 round-robin 条带化；125 MHz 读侧每拍读 1 个。读侧不依赖 instruction sequence 顺序。为保证最后一个归约项确实最后读出，带 last 的物理 lane 项会一直保留到该逻辑 FIFO 总占用只剩 1。

last 不按非阻塞返回顺序生成，而按该 hart/package 的“提交结构数”和“已生成 CRC 数”比较。第 65536 条结构对应 package 满包 last；程序结束标记触发后，尾部不足 65536 条的 package 也生成 last。

### 6.1 每拍最多四个 CRC 项写入 FIFO 的具体实现

该逻辑在 `instr_crc_hash_dual.sv` 中按 hart 独立执行，每拍的候选总数最多为 4，步骤如下：

1. 先形成直接候选。i0/i1 若不需要等待非阻塞数据，其 160-bit struct 当拍得到 `{C1,C0}`，并按 lane 年龄顺序成为该 hart 的最高优先级候选。
2. 再形成非阻塞 ready mask。每个 hart 的 `nb_crc_valid[31:1]` 组成 31-bit 有效图；对它使用 `mask & (~mask + 1)` 隔离最低编号的有效 GPR，清除此位后重复四次，得到按 rd 从小到大的最多四个 CRC-buffer 候选。
3. 填充四个固定候选槽。如果本拍有两个直接候选，它们占 slot0/1，非阻塞候选只填 slot2/3；有一个直接候选时占 slot0，非阻塞候选填 slot1～3；没有直接候选时，四个 slot 都可由非阻塞 CRC buffer 使用。因此硬件保证“每 hart、每拍总共不超过四项”，而不是“直接项之外再额外写四项”。
4. 每个候选用其 `Package Number[0]` 选择 bank0 或 bank1。只有目标 bank 空闲/刚释放/已属于同一 package、bank 尚未关闭，并且 `fifo_free_count >= 4` 时才整体接受。固定要求至少四个空位是保守的原子接收策略：无论本拍实际为 1～4 项，都保证最大批量不会出现只写入一部分的情况。
5. 被接受的非阻塞候选产生相应 `nb_selected[hart][rd]`，时钟沿清除该 `nb_crc_valid`，CRC buffer 即可重新使用。未被接受的 CRC buffer 保持 valid 和原数据，等待后续周期，不会丢失。
6. 每个 hart/bank 保留一个 `tail_pair`。新候选到来时，若已有 tail，则把旧 tail 作为普通项 `{last=0,C1,C0}` 写出，再用新候选替换 tail；若原来没有 tail，则第一个候选只进入 tail。这样已有 tail 时一拍最多向四个写槽发出四项，没有 tail 时最多发出三项。
7. 当该 package 已生成 65536 个 CRC，或停止标记后“已生成数=已提交数”，并且当前拍没有新候选时，才把保留的 tail 作为 `{last=1,C1,C0}` 写入。由此保证带 last 的 CRC 确实是该 package 在 FIFO 中最后读出的物理项。
8. `crc_pair_fifo_async_4w1r.sv` 把四个写槽按轮转位置分配给四条 32 深度 XPM FIFO lane，合起来构成 128 深度逻辑 FIFO；读侧每拍从当前非空 lane 取一项，因此能保持 50 MHz 写侧最多四项/拍和 125 MHz 读侧一项/拍。

若 bank 正被另一个同奇偶 package 占用，候选保持在 CRC buffer 并产生 `bank_conflict`；若 bank/package 合法但不足四个空位，候选同样保持并产生 `fifo_overflow`。两者都不会清除尚未真正接收的 CRC buffer。

## 7. G 函数和六路归约

常量由本实现固定为：

```text
K0 = 0x9E3779B97F4A7C15
K1 = 0xD1B54A32D192ED03
```

每个 CRC 对计算：

```text
G0 = C0 + rotl(C1, 17) + K0
G1 = C1 + rotl(C0, 31) + K1
G2 = (C0 XOR rotl(C1, 43)) + rotl(C0, 11)
G3 = (C1 XOR rotl(C0, 29)) + rotl(C1, 7)

XOR0 = XOR0 XOR G0
XOR1 = XOR1 XOR G1
SUM0 = SUM0 + G0
SUM1 = SUM1 + G1
SUM2 = SUM2 + G2
SUM3 = SUM3 + G3
```

所有加法按 64 bit 模 `2^64` 回绕。`crc_mix_accumulator` 使用两级流水：第一级并行计算 G0～G3，第二级归约并处理 last；可每个 125 MHz 周期接收一个 FIFO 项。last 对应项计入结果后，`result_valid` 拉高一个周期并输出 package number、item count 和六个值。

## 8. 结束标记

模块监控 LSU AXI 写地址/写数据握手。写地址 `0xD0580000` 且低 32-bit 写数据为 `0x00320525`、低四字节 strobe 全有效时，设置对应 hart 的 stopped 位。AXI AW/W 可不同拍到达，模块分别暂存后配对；hart 从 AWID 的线程位取得。

结束标记指令本身仍属于 CRC 序列；从它之后提交的指令不再生成 CRC。SoC 同时向对应 hart 发 halt request，两个 hart 独立停止。

## 9. 主要模块

| 文件/模块 | 作用 |
|---|---|
| `design/dec/eh2_dec_decode_ctl.sv` | 在 EH2 最终提交/WAW 控制点构造监控包 |
| `design/dec/eh2_dec.sv`、`design/eh2_veer.sv`、`design/eh2_veer_wrapper.sv` | 把监控信号逐级引到 EH2 顶层 |
| `rtl/instr_crc_hash_dual.sv` | 结构生成、双 hart 序号、非阻塞/CRC buffer、WAW 清零、package bank 写入 |
| `rtl/crc64_ecma_pair_160.sv` | C0/C1 CRC-64/ECMA-182 |
| `rtl/crc_pair_fifo_async_4w1r.sv` | 四写一读、129-bit、128 深度的异步逻辑 FIFO |
| `rtl/crc_mix_accumulator.sv` | G0～G3 两级流水和六路归约 |
| `rtl/instr_crc_system_dual.sv` | 每 hart 两 FIFO、CDC、bank release 与结果汇总 |
| `rtl/eh2_unified_axi_bram.sv` | EH2 IFU/LSU AXI 存储接口 |
| `rtl/eh2_crc_soc.sv` | EH2、存储、CRC 系统、停止和金标检查集成 |
| `fpga/eh2_crc_fpga_top.sv` | 时钟、复位、1000 条程序和 LED 顶层 |

## 10. FPGA 存储和 LED

1000 条 ELF 的 `.text` 位于 `0x80000000`，大小 `0x5a0`；仅有一个 64-bit 数据对象位于 `0x80010000`。为避免实现中间未使用的 64 KiB 地址洞，上板硬件使用：

- `0x80000000` 起的 8 KiB 主存储；
- `0x80010000` 的一个 64-bit 稀疏数据字，初值 `0x2468ace013579bdf`。

约 20 万条前仿仍使用 testbench 中 128 KiB 的大存储模型，不把该容量带到 FPGA。

FPGA 输入为 50 MHz 差分时钟。EH2/core 写侧为 50 MHz；MMCM 生成 125 MHz CRC FIFO 读/归约时钟。复位等待 MMCM lock、全部异步 FIFO reset 完成后再释放 EH2。

本工程与参考工程 `eh2_veri_iss_proj/constraints/eh2_dual_ddr_v19p.xdc` 的板级约束核对如下：

| 端口 | 当前工程 | 参考工程 | 结论 |
|---|---|---|---|
| `core_clk_p/core_clk_n` | BY44/CA44，LVDS，20.000 ns | BY44/CA44，LVDS，20.000 ns | 一致 |
| `sw3_1/sw4_1` | BU21/BU28，LVCMOS12 | BU21/BU28，LVCMOS12 | 一致 |
| `led[0:7]` | BE22、BG23、BJ20、BN19、U34、T37、K37、M39，LVCMOS12，DRIVE 8 | 相同 | 一致 |
| LED 有效电平 | 高电平点亮 | 高电平点亮 | 一致 |

当前工程没有使用参考工程的 ATG 和 DDR4 外部接口，因此没有复制这些无关引脚约束。当前工程额外为两个板级复位开关增加下拉属性，并只把外部复位输入路径设为 false path；50 MHz core 时钟和 MMCM 生成的 125 MHz CRC 时钟仍按相关时钟进行完整时序分析。

LED 与参考工程使用完全相同的有效电平和引脚。所有 LED 在上电、复位以及程序运行期间均保持低电平；只有最终结果完成比较后，才会二选一点亮 LED0 或 LED1。若通过和失败状态意外同时锁存，失败具有显示优先级，因此不会出现两个 LED 同时点亮。

| LED | 含义 |
|---|---|
| LED0 | 运行结束后，hart0 package0 的 count+六值与 1000 条金标完全一致且无错误 |
| LED1 | 运行结束后，金标不匹配、出现额外 package/hart1 结果或内部冲突 |
| LED2–LED7 | 始终保持低电平 |

## 11. 验证方法与已知金标

1000 条单 hart用例通过完整 EH2 RTL、AXI 存储、CRC/FIFO/归约集成前仿；从首条程序指令到包含结束 store 共 899 个 instruction struct。EH2 与 Ubuntu Spike 的 899 个 160-bit 结构逐项一致，最终六值为：

```text
XOR0 = 0f679f9999355134
XOR1 = 9909e9725ab66071
SUM0 = cbf08f5dd8aeb6b6
SUM1 = 44ab72f45137c99f
SUM2 = 4763eb0bc0cdf491
SUM3 = cf8ccff5b2143cd9
```

约 20 万条双 hart 程序包含整数相关性、load/store、mul、div/rem 和分支。Ubuntu Spike 与完整 EH2 RTL 对同一 ELF 均得到每 hart 99,960 条、总计 199,920 条，两个 hart 各为 package0=65,536、package1=34,424。199,920 个 160-bit instruction struct 按 hart/package/sequence 逐条比较，exact=199,920、missing=0、mismatch=0。四组最终归约值为：

```text
hart0 package0 count=65536
XOR0=952f90111fe8e676 XOR1=2079c7915534fcdc
SUM0=6a66e9b19389a816 SUM1=26d63b414559ee90
SUM2=90a66d972cd8e868 SUM3=b60d6f785c062ffb

hart0 package1 count=34424
XOR0=f987b85c09b44590 XOR1=fa962278376ecf47
SUM0=4244c911c612c7a8 SUM1=37be8628ca2e4f4d
SUM2=48a53971404c7574 SUM3=bcbc5bfa41180f8f

hart1 package0 count=65536
XOR0=4da212594af33c0a XOR1=960fa63b45f600a1
SUM0=c9e1fc4ac2527930 SUM1=3bf4108e1ac967bd
SUM2=28760e7f0497e617 SUM3=5ad2a5aa6dbf6d9f

hart1 package1 count=34424
XOR0=4a517c251893a7ab XOR1=ad3f2f4b16f7072a
SUM0=cbd31e29bda1c2c1 SUM1=c840d6a81e8f02f2
SUM2=64c7096982b64dd0 SUM3=3decd6a252b267ca
```

此外，独立双 hart package 轮换测试让每个 hart 连续生成 10 个完整 package，共处理 `2 × 10 × 65536 = 1,310,720` 个 CRC 对；package0～9 的两个 FIFO 交替复用、每包最后一项的 last 以及 bank release 全部通过。

主要复核命令由以下脚本完成：

- `scripts/spike_commit_crc.py`：从 Spike commit log 生成结构和软件金标；
- `scripts/verify_struct_results.py`：用 RTL 导出的结构重新计算 CRC/归约并比较 RTL result；
- `scripts/compare_eh2_spike_structs.py`：按 hart/package/sequence 比较 EH2 与 Spike 结构，允许且单独统计 EH2 的 WAW data 清零。

最终前仿报告、Vivado 资源/时序和 bitstream 均保存在本目录的 `sim`、`golden` 和 `vivado_build` 子目录。

## 12. Synplify 网表与 FPGA 实现信息

### 12.1 双 hart EH2 EDIF

EH2 处理器本体使用 Synplify 重新综合，监控端口宽度与原双 hart 顶层保持一致，提交时序改为直接观察 EH2 原始 WB 提交拍。生成文件：

```text
synplify_mt/rev_mt/eh2_veer_wrapper.edf
大小：228650639 bytes
时间：2026-07-30 01:30:45
SHA-256：15FE91CBE8470DE083ECFFA0CFD0D5A00A274DACF6BE3A87FFCA294D7864D497
```

Synplify 报告 `eh2_veer_wrapper.srr` 为 `Mapper successful`，没有综合错误。

器件选择与参考工程 `D:/eh2_fpga/eh2_veri_iss_proj` 的实际实现流程一致：

- Synplify 映射目标：`XCVU19P-FSVA3824-1-e`；
- Vivado 综合、布局布线和 bitstream 目标：`xcvu19p_CIV-fsva3824-1-e`。

`CIV` 是 Vivado 中安装的受限 VU19P 器件名称；它与 Synplify 使用的普通 `XCVU19P/FSVA3824/-1-e` 是本流程中的对应器件。Vivado 构建脚本将全局并行上限设为 8；本次日志确认综合最多使用 4 个进程，时序、布局、物理优化、布线、DRC 和 bitstream 阶段最多使用 8 个 CPU/线程。

EH2 本体映射资源为：

| 资源 | 数量 |
|---|---:|
| LUT | 90,027 |
| 寄存器位 | 40,491 |
| URAM288 | 20 |
| RAMB36 等效量 | 2 |
| DSP48 | 4 |

### 12.2 CRC/SoC 综合资源与调度时序修正

Vivado 综合后整个 FPGA 顶层资源为 179,341 LUT、63,388 FF、32 RAMB36、4 RAMB18、20 URAM、4 DSP。其中：

| 层次 | LUT | FF | RAMB36 |
|---|---:|---:|---:|
| 双 hart EH2 EDIF | 90,001 | 40,491 | 0（另有 4 RAMB18、20 URAM） |
| 双 hart CRC/FIFO/归约系统 | 80,110 | 22,476 | 32 |
| `instr_crc_hash_dual` | 72,394 | 17,170 | 0 |
| 8 KiB 程序存储与 AXI 控制 | 9,212 | 390 | 0 |

64 个并行 CRC 对确实是 CRC 系统的主要 LUT 消耗，但在 VU19P 上总资源仍有很大余量。它们不是此前最差时序的根因；真正的瓶颈是旧候选循环把通用整数计数展开成超长串行选择链。修正前后的综合时序对比如下：

| 项目 | 修正前 | 固定四槽选择后 |
|---|---:|---:|
| 总体 WNS | -29.406 ns | +3.014 ns |
| TNS | -200,653 ns 量级 | 0 ns |
| 原最差路径逻辑级数 | 180 | 34 |
| 原最差路径数据延迟 | 48.792 ns | 10.462 ns |
| 50 MHz core 域 WNS | 负裕量 | +8.924 ns |
| 125 MHz CRC 域 WNS | 负裕量 | +4.034 ns |

上述数值为综合后估算；最终布线结果见 12.4。

### 12.3 构建检查点

`fpga/build_bitstream.tcl` 在以下阶段分别保存检查点，避免长时间构建中断后完全重来：

```text
vivado_build/output/post_synth.dcp
vivado_build/output/pre_physopt_place.dcp
vivado_build/output/post_place.dcp
vivado_build/output/pre_physopt_route.dcp
vivado_build/output/post_route.dcp
```

最终 bitstream、调试探针、资源、时序、CDC 和 DRC 报告分别保存在 `vivado_build/output` 与 `vivado_build/reports`。

### 12.4 最终布线、DRC、CDC 与 bitstream

Vivado 2023.2 已完成布局、布线和 bitstream 生成。布线器报告所有网络均已完成连接：

```text
Failed Nets       = 0
Unrouted Nets     = 0
Partially Routed  = 0
Node Overlaps     = 0
```

最终 `post_route_timing_summary.rpt` 显示所有用户时序约束均满足：

| 项目 | WNS/WHS | TNS/THS |
|---|---:|---:|
| 全设计 setup | +1.348 ns | 0 ns |
| 全设计 hold | +0.010 ns | 0 ns |
| 50 MHz core setup | +2.630 ns | 0 ns |
| 50 MHz core hold | +0.010 ns | 0 ns |
| 125 MHz CRC setup | +1.906 ns | 0 ns |
| 125 MHz CRC hold | +0.032 ns | 0 ns |

布局布线后顶层资源为：

| 资源 | 数量 |
|---|---:|
| LUT | 171,343 |
| FF | 60,588 |
| RAMB36 | 32 |
| RAMB18 | 4 |
| URAM | 20 |
| DSP | 4 |

最终 DRC 为 `0 Errors, 99 Warnings, 6 Advisories`，bitstream 写出阶段为 `0 Critical Warnings`。警告由 EH2 DSP 未使用内部流水寄存器、EH2 URAM 的 BWE 建议、板级 I/O 总线跨 SLR，以及被综合优化后没有负载的 FIFO 输出位组成；其中新增的 2 条 Advisory 是 CIV 器件的 GT 总速率与 I/O 数量限制检查，当前设计为 0 Gbps、11 个 I/O，均在限制范围内。这些警告和提示未阻止布线、时序收敛或 bitstream 生成。

CDC 报告中的 16 个 `CDC-7 Critical` 全部来自板级复位开关 `sw4_1` 到 `infra_reset_pipe[15:0]` 的异步清零端。这里采用“异步拉低、同步释放”：任一板级复位开关拉低会立即清空 16 级复位管线；开关释放后仍等待 MMCM locked 和全部 XPM FIFO reset_done，然后每个 50 MHz 时钟移入一个 1，直至第 16 级才释放 EH2。Vivado `report_cdc` 没把这组普通移位寄存器识别为 XPM reset synchronizer，因此按未知异步复位电路报告；数据通路的 core/CRC 跨时钟传输使用 XPM 异步 FIFO。

最终压缩 bitstream：

```text
vivado_build/output/eh2_crc_fpga_top.bit
大小：60608639 bytes
时间：2026-07-30 19:21:52
SHA-256：C5848CD59B44873E7B85AC823B08AE210DA6503F96F72AA8507026CA7FE7B2AA
```

该 bitstream 内置 `trace_1000_jump` 的 FPGA 程序镜像。它是约 1000 条的静态测试程序，实际从首条程序指令到结束 store 共观察到 899 条动态提交 instruction struct。程序最终写 `0xD0580000 = 0x00320525`，CRC 系统据此封包并将 hart0/package0 的 count 和六个归约值与 Spike/软件金标比较：全部一致且无内部冲突时点亮 LED0；任一比较失败、出现额外结果或内部冲突时点亮 LED1。
