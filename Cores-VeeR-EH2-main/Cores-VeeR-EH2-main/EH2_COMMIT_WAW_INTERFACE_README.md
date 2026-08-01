# EH2 提交、WAW 与非阻塞 GPR 写回接口说明

本文说明服务器工程
`/proj/project2/workarea/user12/eh2/Cores-VeeR-EH2-main`
中新增的顶层监视接口、使用的 EH2 内部信号、增加的逻辑和验证结果。

实现日期：2026-07-28。

## 1. 同周期写 GPR 时 EH2 的处理

每个 hart 的 GPR 文件有四个物理写口：

1. 普通 i0 WB 写口；
2. 普通 i1 WB 写口；
3. 非阻塞 load 返回写口；
4. div 返回写口。

处理规则如下：

- 同一 hart、不同 rd：可以在同一周期并行写入；
- 不同 hart：各自的 GPR 文件独立写入；
- 同一 hart、同一 rd：冲突在进入 GPR 文件前取消，不能有两个有效写口；
- 非阻塞旧结果与后续普通指令冲突时，后续指令获胜，旧 load/div 的最终写使能为 0；
- 如果后续写者本身也是新的非阻塞指令，旧 pending 结果仍会被取消，但新指令在首次提交时也不会立即写 GPR，而是建立新的 pending 操作。

`eh2_dec_gpr_ctl.sv` 对四个写口的数据做按位 OR 合并，同时已有断言
`assert_multiple_wen_to_same_gpr` 保证同一寄存器不会有两个有效写口。因此不能把该 OR 理解为冲突优先级；真正的 WAW 仲裁位于上游。

## 2. 接口时序约定

- `rv_commit_*`、`rv_commit_waw_victim` 和 `rv_nb_waw_*` 位于 WB+1，i0/i1 的所有字段按 lane 同周期对齐；
- lane `[0]` 是 i0，lane `[1]` 是 i1；
- `rv_nb_load_gpr_*` 和 `rv_nb_div_gpr_*` 不再增加延迟，直接表示该周期真正送入 GPR 文件的非阻塞写口；
- 非阻塞指令的首次提交与其数据返回可能相隔很多周期，因此非阻塞实际写回接口不与原提交 lane 强行对齐；
- 除 valid/wen 外的字段只应在对应 valid/wen 为 1 时采样。

## 3. i0/i1 提交接口

| 信号 | 作用 |
|---|---|
| `rv_commit_valid[1:0]` | 该 lane 有一条通过 TLU 提交判定的指令，可用于指令序列计数。 |
| `rv_commit_insn[1:0][31:0]` | 提交指令；压缩指令位于低 16 位。 |
| `rv_commit_pc[1:0][31:0]` | 提交指令 PC。 |
| `rv_commit_hart_id[1:0]` | hart/thread ID。 |
| `rv_commit_priv_mode[1:0][1:0]` | 特权模式；当前 EH2 为 M-mode，值为 `2'b11`。 |
| `rv_commit_gpr_wen_intent[1:0]` | 通过 kill 检查后的 GPR 写意图，位于 WAW 和非阻塞首次写回抑制之前。 |
| `rv_commit_gpr_wen[1:0]` | 该提交 lane 在原 WB 周期真正执行的普通 GPR 写使能。 |
| `rv_commit_gpr_rd[1:0][4:0]` | 目的 GPR 编号。 |
| `rv_commit_gpr_wdata[1:0][31:0]` | 普通 WB 写数据，仅在 `rv_commit_gpr_wen=1` 时表示实际写入值。 |
| `rv_commit_csr_wen[1:0]` | CSR 实际写使能；EH2 的 CSR 写位于 i0。 |
| `rv_commit_csr_addr[1:0][11:0]` | CSR 地址。 |
| `rv_commit_csr_wdata[1:0][31:0]` | CSR 写数据。 |
| `rv_commit_is_nonblock[1:0]` | 该提交指令被转成非阻塞 load 或 div。 |
| `rv_commit_is_nonblock_load[1:0]` | 非阻塞 load。 |
| `rv_commit_is_nonblock_div[1:0]` | 非阻塞 div；EH2 的 div 从 i0 发射。 |
| `rv_commit_waw_victim[1:0]` | 当前 lane 因同周期、更年轻 lane 写同 hart、同 rd 而成为 victim；正常情况下只可能置位 i0。 |

识别同周期 i0/i1 WAW：

```systemverilog
if (rv_commit_valid[0] && rv_commit_waw_victim[0]) begin
    // victim = rv_commit_{insn,pc,hart_id,gpr_rd}[0]
    // writer = rv_commit_{insn,pc,hart_id,gpr_rd}[1]
end
```

## 4. 旧非阻塞指令被 WAW 取消

下列数组的下标表示当前 writer lane，不是旧 victim 的 lane：

| 信号 | 作用 |
|---|---|
| `rv_nb_waw_valid[1:0]` | 当前 lane 的写意图取消了一条更早提交、尚未完成写回的非阻塞指令。 |
| `rv_nb_waw_victim_insn[1:0][31:0]` | 被取消的旧指令。 |
| `rv_nb_waw_victim_pc[1:0][31:0]` | 被取消旧指令的 PC。 |
| `rv_nb_waw_victim_hart_id[1:0]` | victim 的 hart ID。 |
| `rv_nb_waw_victim_gpr_rd[1:0][4:0]` | victim 的目的 GPR。 |
| `rv_nb_waw_victim_is_load[1:0]` | victim 是非阻塞 load。 |
| `rv_nb_waw_victim_is_div[1:0]` | victim 是非阻塞 div。 |

`is_load` 与 `is_div` 在 valid 时互斥。使用方式：

```systemverilog
for (int lane = 0; lane < 2; lane++) begin
    if (rv_commit_valid[lane] && rv_nb_waw_valid[lane]) begin
        // writer = rv_commit_*[lane]
        // victim = rv_nb_waw_victim_*[lane]
    end
end
```

这里应使用 `rv_commit_gpr_wen_intent` 判断 writer 的写意图，不能要求
`rv_commit_gpr_wen=1`，因为更年轻的 writer 也可能是本周期尚不实际写 GPR 的非阻塞指令。

## 5. 非阻塞数据返回后的实际 GPR 写回接口

load 与 div 使用两套独立接口，避免它们同周期返回时丢失其中一个事件。

| 信号 | 作用 | EH2 内部来源 |
|---|---|---|
| `rv_nb_load_gpr_wen` | 非阻塞 load 本周期真正写入 GPR。它已包含 CAM 命中和 WAW 取消结果。 | `|dec_nonblock_load_wen` |
| `rv_nb_load_gpr_hart_id` | load 写入的 hart。 | `lsu_nonblock_load_data_tid` |
| `rv_nb_load_gpr_rd[4:0]` | load 写入的 GPR 编号。 | 有效 `dec_nonblock_load_waddr[hart]` |
| `rv_nb_load_gpr_wdata[31:0]` | load 实际写入数据。 | `lsu_nonblock_load_data` |
| `rv_nb_div_gpr_wen` | div 本周期真正写入 GPR，已包含 `dec_div_cancel`。 | `exu_div_wren` |
| `rv_nb_div_gpr_hart_id` | div 写入的 hart。 | `div_tid_wb` |
| `rv_nb_div_gpr_rd[4:0]` | div 写入的 GPR 编号。 | `div_waddr_wb` |
| `rv_nb_div_gpr_wdata[31:0]` | div 实际写入数据。 | `exu_div_result` |

采样示例：

```systemverilog
if (rv_nb_load_gpr_wen) begin
    // 本周期 GPR[rv_nb_load_gpr_hart_id][rv_nb_load_gpr_rd]
    // 写入 rv_nb_load_gpr_wdata
end

if (rv_nb_div_gpr_wen) begin
    // 本周期 GPR[rv_nb_div_gpr_hart_id][rv_nb_div_gpr_rd]
    // 写入 rv_nb_div_gpr_wdata
end
```

不能用以下原始信号替代最终写使能：

- `lsu_nonblock_load_data_valid` 只表示 LSU 数据返回；CAM entry 已因 WAW 失效时不会写 GPR；
- divider 的 raw `finish_ff` 只表示计算完成；返回周期 `dec_div_cancel=1` 时 `exu_div_wren=0`。

## 6. 同周期非阻塞返回与普通写回的仲裁逻辑

### 非阻塞 load

`eh2_dec_cam` 生成：

```systemverilog
nonblock_load_cancel =
    i0_wen_wb && same(i0.rd, load.rd, i0.tid, load.tid) ||
    i1_wen_wb && same(i1.rd, load.rd, i1.tid, load.tid);

nonblock_load_wen =
    lsu_nonblock_load_data_valid && live_cam_match &&
    !nonblock_load_cancel;
```

因此同 hart、同 rd 时旧 load 不写；不同 rd 时 load 写口可与 i0/i1 写口并行。

### 非阻塞 div

`eh2_dec_decode_ctl` 的 `nonblock_div_cancel` 比较 active div 的 `div_rd/div_tid`
与当周期 i0/i1 的 `i0_wen_wb/i1_wen_wb`。它输出 `dec_div_cancel`，divider 最终：

```systemverilog
exu_div_wren = finish_ff && !dec_div_cancel;
```

因此返回周期同 hart、同 rd 时旧 div 不写；不同 rd 时 div 写口与普通写口并行。

## 7. WAW 情况是否覆盖完整

在当前 EH2 的架构 GPR 更新路径中，因 WAW 而取消写入只包括：

1. 同周期、同 hart 的 i0/i1 写同一 rd，i0 被 i1 覆盖；
2. pending 非阻塞 load/div 在数据返回前被后续同 hart、同 rd 写意图取消；
3. 非阻塞 load/div 数据返回当周期，被后续同 hart、同 rd 写意图取消。

新增接口覆盖这三类，并处理以下边界：

- i0 和 i1 都可成为旧非阻塞 victim 的 writer；
- writer 自身可以是非阻塞指令；
- load 和 div victim 统一由 `rv_nb_waw_*` 描述；
- 返回前与返回当周期都不会因 CAM 清除或 divider finish 清除而漏报；
- 相同 rd、不同 hart 不属于 WAW；
- x0 不产生架构 GPR 更新；
- flush、异常、debug kill 等非 WAW 取消不置 WAW 标志；
- 数据已经完成写回后再写相同 rd 是正常的顺序写入，不是“旧写回被取消”；
- CSR 字段用于提交记录，本接口未定义 CSR WAW victim。

基于当前 EH2 源码的 GPR 写路径，未发现第四类会因 WAW 而不更新架构 GPR 的路径。

## 8. 修改的 RTL 文件

服务器 `design` 下共修改 7 个文件：

- `design/eh2_veer_wrapper.sv`
- `design/eh2_veer.sv`
- `design/dec/eh2_dec.sv`
- `design/dec/eh2_dec_decode_ctl.sv`
- `design/dec/eh2_dec_tlu_ctl.sv`
- `design/dec/eh2_dec_tlu_top.sv`
- `design/exu/eh2_exu_div_ctl.sv`

完整差分：

`/proj/project2/workarea/user12/eh2/Cores-VeeR-EH2-main/agent/eh2_commit_waw.patch`

修改后 RTL 镜像：

`/proj/project2/workarea/user12/eh2/Cores-VeeR-EH2-main/agent/rtl/design`

本次新增的 8 个非阻塞实际写回端口只需要修改前三个文件；后四个文件是此前提交/WAW victim 元数据逻辑的一部分。

## 9. 验证方法和结果

验证文件全部位于服务器 `agent`：

- `agent/verification/waw_directed.s`：定向程序；
- `agent/verification/eh2_waw_monitor.sv`：提交、WAW 和实际非阻塞写口监视器；
- `agent/verification/tb_top_waw.sv`：测试顶层；
- `agent/verification/ahb_sif_waw.sv`：支持可编程 load 返回延迟的存储器模型；
- `agent/verification/run_waw_return_sweep.sh`：13 组延迟扫测和自动判定；
- `agent/waw_runs/return_sweep_summary.log`：逐组结果；
- `agent/waw_runs/return_coverage_result.log`：最终覆盖结果。

单 hart 使用 Cadence Incisive 15.20 对 `lmem_delay=0..12` 共 13 组运行：

- 13/13 `TEST_PASSED`；
- 每组提交 `i0=178`、`i1=166`，总计 344，与 `minstret=344` 一致；
- 每组同周期 i0/i1 WAW 2 次；
- 每组非阻塞 load WAW 2 次、div WAW 3 次；
- 扫测覆盖 load/div 的返回前与返回当周期 WAW；
- 每组实际 load 写回 1 次：`hart=0, rd=23, data=0x13579bdf`；
- 每组实际 div 写回 9 次：`hart=0, rd=21, data=0x7fffffff`；
- `lmem_delay=10` 覆盖了非阻塞写口与普通写口同周期写不同 rd；
- 所有监视器检查 `errors=0`。

自动覆盖结果：

```text
COVERAGE_PASS runs=13 same_cycle=1 div_before=1 div_return=1 load_before=1 load_return=1 nb_load_gpr_write=1 nb_div_gpr_write=1 nb_parallel_normal_write=1 errors=0
VALUE_PASS load_rd23=13579bdf div_rd21=7fffffff
LANE_PASS nonblock_waw_writer_i0=1 nonblock_waw_writer_i1=1
```

另外用 VCS S-2021.09-SP1 对 `default_mt` 双 hart 配置完成编译、展开和运行：

- `TEST_PASSED`；
- `NUM_THREADS=2` 的 hart/rd 选择逻辑成功展开；
- 运行汇总同样为 `errors=0`；
- 测试平台只启动 hart0，因此该次动态事件的 hart 值为 0，hart1 为 idle。

对应目录：

- 单 hart snapshot：`agent/snapshots/waw_return`；
- 双 hart VCS snapshot：`agent/snapshots/waw_mt_return`；
- 双 hart VCS 运行：`agent/waw_runs/build_mt_return_vcs`。
