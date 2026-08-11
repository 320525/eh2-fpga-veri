# EH2 新增内部逻辑与接口信号说明

## 1. 文档目的与结论

本文说明本系统相对原始 Cores-VeeR-EH2 在处理器内部增加或修改的内容，逐项追踪新增接口的来源、生成条件、运算原因及其在日志/归约系统中的用途。

本工程给 EH2 增加的是一套“体系结构提交监视接口”，其作用是在不改变指令执行结果的前提下，从 EH2 的 WB（write-back）体系结构提交点输出：

- 每周期最多两条提交指令的指令字、PC、hart、GPR/CSR 写回和非阻塞属性；
- 同周期 WAW 取消事件；
- 已提交但尚未返回的非阻塞 load/div 被年轻指令 WAW 取消的事件及被取消指令信息；
- 未被取消的非阻塞 load/div 最终写回信息。

最终 EH2 网表接口共新增 **31 组输出端口，展开后共 536 bit**。日志功能没有给 EH2 增加输入端口。新增接口只观察并导出 EH2 已有的体系结构行为；真正的哈希、归约、package/sequence 分配、WAW 序号存储、跨时钟传输和以太网组帧都在 EH2 外部完成。

## 2. 实际采用的实现源

行为级修改源位于：

```text
D:/eh2_fpga/Cores-VeeR-EH2-main/Cores-VeeR-EH2-main/design
```

板级综合使用由该修改版 RTL 生成的网表：

```text
netlist/eh2_veer_wrapper.edf
```

工程中的网表端口声明桩为：

```text
rtl/eh2/eh2_veer_wrapper_mt_stub.v
```

EH2 与系统日志/归约逻辑的连接位于：

```text
rtl/eh2/eh2_core_crc_subsystem.sv
```

因此，本文件对“EH2 内部信号怎样产生”的说明以修改版行为级 RTL 为依据，并用当前网表桩确认最终硬件确实保留了这些端口。

## 3. 必须先明确的信号语义

### 3.1 i0/i1 不是 hart0/hart1

`rv_commit_*[0]` 对应 EH2 当周期的 i0 提交槽，`rv_commit_*[1]` 对应 i1 提交槽。i0 是同周期较老的指令，i1 是同周期较年轻的指令。

任何一个槽都可能属于 hart0 或 hart1，必须使用同槽的 `rv_commit_hart_id[lane]` 判断所属 hart。例如：

```text
rv_commit_valid[1] = 1 且 rv_commit_hart_id[1] = 0
```

表示 i1 槽当周期提交的是 hart0 指令，并不表示 hart1 提交。

`rv_nb_waw_*[0/1]` 的下标同样表示“触发取消的年轻提交指令位于 i0/i1 槽”，不是 hart 编号。

### 3.2 普通提交与非阻塞结果返回是两个时刻

普通指令在 WB 提交时，其 GPR 写回数据已确定。非阻塞 load/div 则可能先在 WB 被识别为一条已提交的指令，结果在若干周期以后才返回。因此接口分成两类：

1. `rv_commit_*`：记录指令在 WB 的提交结构并为它分配日志序号；
2. `rv_nb_load_gpr_*`、`rv_nb_div_gpr_*`：结果真正写入 GPR 时，补齐先前保存的指令结构。

在等待结果期间，若更年轻的同 hart 指令先写相同 `rd`，旧的非阻塞结果在体系结构上必须被取消。`rv_nb_waw_*` 专门报告这种跨周期 WAW 取消。

## 4. EH2 内部增加或修改的部分

### 4.1 从 TLU 导出未被 trace 开关门控的 WB 提交有效信号

修改文件：

```text
dec/eh2_dec_tlu_ctl.sv
dec/eh2_dec_tlu_top.sv
```

每个 hart 的 TLU 已有 `i0_valid_wb`、`i1_valid_wb`，表示该 hart 在相应槽中确实有指令到达体系结构 WB 提交点。新增逻辑只是直接导出：

```systemverilog
tlu_i0_commit_wb = i0_valid_wb;
tlu_i1_commit_wb = i1_valid_wb;
```

`eh2_dec_tlu_top` 再将每个 hart 的值组成 `dec_tlu_i0_commit_wb[NUM_THREADS-1:0]` 和 `dec_tlu_i1_commit_wb[NUM_THREADS-1:0]`。

这样做的原因是旧 trace 接口可能被 trace-disable 配置关闭，也位于与本日志分配不完全相同的时序点。归约系统必须观察所有真实提交，不能因为 trace 被关闭而漏掉指令。

### 4.2 使指令字和 PC 元数据流水线不再依赖 legacy trace enable

修改文件：

```text
dec/eh2_dec_decode_ctl.sv
```

EH2 原有 i0/i1 指令字和 PC 流水寄存器主要服务 trace。修改后仍沿用原流水数据和各级流水使能，但去掉 legacy trace-enable 对这些寄存器的附加门控，使 `i0_inst_wb/i1_inst_wb`、`i0_pc_wb/i1_pc_wb` 在 trace 关闭时仍与 WB 提交保持对齐。

这是元数据可用性修改，不改变指令执行、寄存器写回或存储器访问。

### 4.3 在 WB 点构造 commit monitor packet

修改文件：

```text
dec/eh2_dec_decode_ctl.sv
```

新增组合结构 `eh2_commit_monitor_pkt_t commit_monitor_wb`。每周期先整体清零，再从当前 WB 的 `wbd`、TLU commit、GPR/CSR 写回和非阻塞控制信号中填入有效字段。整体清零保证无效槽、i1 不支持的 CSR/div 字段和未发生的事件不会保留上一周期数据。

该 packet 在 WB 当周期构造，而不是延迟到 WB+1。原因是外部归约模块必须在指令真正提交的同一时刻分配序号、保存结构，并把随后到来的非阻塞结果或 WAW 取消准确关联到该结构。

### 4.4 增加同周期 WAW 受害者判断

同一 hart 在同周期由 i0、i1 提交且写相同 `rd` 时，i0 较老，通常被年轻的 i1 覆盖。新增 `i0_same_cycle_waw_wb`：

```text
i0v AND i1v
AND (i0.rd == i1.rd)
AND (i0.hart == i1.hart)
AND i0未被kill AND i1未被kill
AND [i1不是延迟写回的非阻塞load
     OR i0本身是非阻塞load
     OR i0本身是仍有效的非阻塞div]
```

其中同 hart 比较用于防止把 hart0 和 hart1 对同号寄存器的写误判为 WAW；kill 判断用于排除已经被异常、flush 等取消的指令。

最后一项不能简单写成“i0/i1 同 rd 就一定取消 i0”。若 i1 是首次经过 WB、但数据尚未返回的非阻塞 load，它此刻没有真正覆盖一个正常 i0 写回，所以正常 i0 仍然具有体系结构效果；只有 i0 自身也是将来写回的非阻塞 load/div 时，才需要在该角落情形报告 i0 被取消。

同周期 WAW 的受害者就是当前 i0 提交结构本身，因此只需在 `rv_commit_waw_victim[0]` 标记，不需要另外复制一套受害者指令/PC 接口。

### 4.5 给非阻塞 load CAM 增加受害者元数据和跨周期 WAW 检测

EH2 原有 load CAM 已保存未完成非阻塞 load 的 valid、tag、rd、状态等信息。修改后每个 CAM entry 增加：

```systemverilog
typedef struct packed {
    logic [31:0] insn;
    logic [31:1] pc;
} eh2_load_cam_commit_pkt_t;
```

当一条非阻塞 load 首次到达 WB 并标记为已提交时，把该 load 的指令字和 PC 保存到对应 CAM entry。之后若年轻指令在 i0 或 i1 槽实际写 GPR，并同时满足：

```text
年轻指令写使能有效
AND 年轻指令hart == 当前CAM所属hart
AND CAM entry.valid
AND CAM entry.wb（旧load已经提交）
AND 年轻指令rd == CAM entry.rd
```

则生成非阻塞 load WAW 事件，并从该 entry 取回旧 load 的 `insn/pc/rd`。

检测特意读取寄存器当前值 `cam_raw`，而不是组合更新后的 `cam_in`。原因是 load 数据返回和年轻写同一周期发生时，`cam_in.valid` 可能已被清掉；使用 `cam_raw` 才不会在清 CAM 的同时丢失本周期应上报的 WAW 事件。

多个 CAM entry 的候选字段采用“匹配条件掩码后按位 OR”汇总。EH2 原有 CAM one-hot 约束保证同一返回/匹配只选中合法 entry，因此这里的 OR 实质上是硬件多路选择器，不是把多条指令内容混合。

### 4.6 给非阻塞 divide 增加提交元数据和跨周期 WAW 检测

EH2 原有 divide 控制已经保存未完成 divide 的 `div_valid/div_rd/div_tid`。新增 63-bit 寄存器 `div_commit_meta_ff`，在 divide 到达 WB 且未被 kill 时保存：

```text
{i0_inst_wb[31:0], i0_pc_wb[31:1]}
```

EH2 的 divide 只从 i0 槽进入执行，但它等待结果期间，年轻覆盖写可能从 i0 或 i1 提交，因此分别检测：

```text
div_valid
AND 当前没有另一条divide仍在E1到WB之间
AND 年轻提交rd == div_rd
AND 年轻提交hart == div_tid
AND 年轻提交实际GPR写使能
```

满足时输出对应槽的 `rv_nb_waw_valid`，受害者指令/PC 来自 `div_commit_meta_ff`，受害者 rd 来自原有 `div_rd`。

保存元数据的原因是触发覆盖写时，旧 divide 已离开普通 WB 流水线，当前 `i0_inst_wb/i0_pc_wb` 已属于另一条年轻指令，不能再用当前流水信息代表受害者。

### 4.7 导出非阻塞 load/div 的最终 GPR 写回

修改文件：

```text
dec/eh2_dec.sv
```

非阻塞 load 的最终写使能不是原始 LSU data-valid，而是 EH2 原有逻辑完成 tag 匹配、hart 匹配并排除同周期年轻覆盖后的 `dec_nonblock_load_wen`。新增端口导出其归约写使能、返回 hart、选中的 rd 和 LSU 返回数据。

非阻塞 divide 端口直接导出 EH2 原有最终 divide 写回的 `exu_div_wren/div_tid_wb/div_waddr_wb/exu_div_result`。因此外部哈希系统只会收到真正进入体系结构 GPR 的结果，不会把已取消结果补入日志。

### 4.8 在层级中向外透传新端口

修改文件：

```text
dec/eh2_dec.sv
eh2_veer.sv
eh2_veer_wrapper.sv
```

`eh2_dec` 产生全部监视数据，`eh2_veer` 和 `eh2_veer_wrapper` 只增加端口并逐级透传，没有在 wrapper 中再次改变这些信号。最终网表桩中的扁平位宽，例如 `[1:0][31:0]` 被显示为 `[63:0]`，语义没有变化。

### 4.9 增加检查断言

在 `RV_ASSERT_ON` 下增加断言，保证同一个年轻提交槽不会同时被识别成“取消非阻塞 load”和“取消非阻塞 div”。因此受害者元数据可以安全地用按位 OR 汇总；若内部互斥假设被破坏，仿真立即暴露问题。

这些断言用于前仿检查，不形成板级功能数据通路。

### 4.10 参数配置变化

`eh2_param.vh` 相对参考版本还包含以下配置变化：

| 参数 | 参考值 | 当前值 | 含义 |
|---|---:|---:|---|
| `NUM_THREADS` | 1 | 2 | 启用两个硬件 hart。 |
| `DCCM_BITS` | `0x10` | `0x11` | DCCM 地址相关位宽增加 1 bit。 |
| `DCCM_INDEX_BITS` | `0x0B` | `0x0C` | DCCM 索引位宽增加 1 bit。 |
| `DCCM_SIZE` | `0x40` | `0x80` | DCCM 配置容量编码加倍。 |
| `LSU_SB_BITS` | `0x10` | `0x11` | LSU store-buffer 地址相关位宽随配置增加。 |
| `LOAD_TO_USE_BUS_PLUS1` | 0 | 1 | 采用增加一级的 load-return 使用时序配置；CAM 清除/返回路径按该配置工作。 |
| `ICACHE_WAYPACK` | 1 | 0 | I-cache way packing 配置调整。 |

这些参数决定当前双 hart 网表的结构和时序配置，但不属于新增的 31 组日志输出端口。

`exu/eh2_exu_div_ctl.sv` 中另有 generate block 命名变化，仅用于保持/识别综合层级，不改变 divide 算法和接口功能。

## 5. 信号来源分类

### 5.1 EH2 已有内部信号直接连接或仅做格式拼接

这类信号的功能在原 EH2 中已经存在，新增工作只是把 WB/最终写回信号引出，包括：

- 提交指令字、hart ID、最终普通 GPR 写使能/地址/数据；
- i0 的最终 CSR 写使能/地址/数据；
- 非阻塞 load 返回 hart 和数据；
- 非阻塞 divide 的最终写使能、hart、rd 和数据。

PC 内部只保存 `[31:1]`，接口末位补 `0` 恢复 32-bit 对齐地址；二维数组在网表桩中只是扁平拼接。这些都不改变信号含义。

### 5.2 EH2 已有内部信号经过简单逻辑运算后输出

这类信号包括：

- 对每个 hart 的 TLU commit 有效位做 OR，形成每个提交槽的 `rv_commit_valid`；
- 对 kill、延迟写回和最终写回条件进行门控，区分 `gpr_wen_intent` 与 `gpr_wen`；
- 从 load CAM/div 状态判断非阻塞类型；
- 把 load/div 类型 OR 成总的 `is_nonblock`；
- 对多个 hart 的非阻塞 load 写使能 OR，并选择唯一有效的 rd；
- 所有事件 valid 与 `rv_commit_valid` 相与，防止无效流水槽产生伪事件。

这些运算的共同目的，是把微体系结构中的分散控制转换成“只描述真实体系结构提交效果”的稳定接口。

### 5.3 新增状态保存与比较逻辑后产生

以下信号不能直接从一个原有节点引出，需要新增逻辑：

- `rv_commit_waw_victim`：比较同周期 i0/i1 的 valid、hart、rd、kill 和非阻塞状态；
- 全部 `rv_nb_waw_*`：保存 pending load/div 的原指令元数据，并在以后比较年轻提交的 hart/rd；
- 非阻塞 load 的受害者元数据选择：对 CAM 匹配项做条件掩码和 OR 汇总。

这些逻辑是必要的，因为 WAW 的“受害者”可能与“触发覆盖的年轻指令”不在同一周期，旧指令离开流水线后只能依靠新增保存状态恢复其身份。

### 5.4 常量输出

`rv_commit_priv_mode[0/1]` 当前固定为 `2'b11`，即 RISC-V Machine mode。它不是从 EH2 权限 CSR 动态读取的直接连接。

这样实现是因为当前 FPGA 验证程序按 M-mode 运行，归约参考也基于该假设。若以后允许 S-mode/U-mode 指令提交，必须把此端口改接真实提交时权限状态、重新生成 EH2 网表并重新建立参考结果；否则该字段会错误地继续报告 M-mode。

## 6. 三类 WAW 事件的关系

| 情形 | 受害者何时被观察 | 事件接口 | 为什么接口不同 |
|---|---|---|---|
| i0/i1 同周期写同一 hart、同一 rd | 受害者 i0 仍在当前 commit packet | `rv_commit_waw_victim[0]` | 受害者就是当前 i0 指令，不必另存指令/PC。 |
| pending 非阻塞 load 被以后提交的年轻写覆盖 | 旧 load 已离开普通流水线，仍在 load CAM | `rv_nb_waw_*` | 必须由 CAM 保存并恢复旧 load 的 insn/PC/rd。 |
| pending 非阻塞 div 被以后提交的年轻写覆盖 | 旧 div 已离开普通流水线，仍由 div 状态跟踪 | `rv_nb_waw_*` | 必须由新增 div metadata 寄存器恢复旧 div 的 insn/PC。 |

WAW 比较总是包含 hart 相等条件。两个 hart 各自有独立的体系结构 GPR，即使同时写同号 `rd` 也不存在跨 hart WAW。

## 7. EH2 外部生成、不得误认为新增 EH2 接口的信号

下列信号或功能虽然与 EH2 日志有关，但不在 EH2 内部产生：

| 外部信号/功能 | 实际产生位置与说明 |
|---|---|
| `package`、`sequence` | `instr_crc_system_dual/instr_crc_hash_dual` 根据每个 hart 的提交次序分配；EH2 不知道以太网 package number。 |
| `waw_cancel_valid/hart/package/sequence` | 外部归约模块把 EH2 的当前提交槽或 pending WAW 事件转换成被取消日志项的 package/sequence。 |
| `waw_event_cdc` | 位于 EH2 外，将 50 MHz EH2 域的 WAW 事件送到 100 MHz 控制/日志域。 |
| `waw_sequence_store` | 位于 EH2 外，按 hart、package 保存被取消的 sequence。 |
| 哈希和最终归约值 | 位于 EH2 外，由日志结构、非阻塞结果补齐和归约模块计算。 |
| `hart started` | `eh2_core_crc_subsystem` 观察每个 hart 的第一次 `rv_commit_valid` 后锁存，不是 EH2 新端口。 |
| `hart stopped` | 系统观察现有 LSU AXI 完成地址写事务产生，不是 EH2 新端口。 |
| 状态机、系统信息 FIFO、MAC 帧 | 全部位于系统控制和以太网数据通路，不在 EH2 网表内。 |

此外，`mpc_reset_run_req`、`mpc_debug_run_req`、`rst_vec` 是原 EH2 已有输入，并非本次新增接口。当前系统把 `rst_vec` 配成 `0x80000000`，并使用原有 hart 启动机制运行两个 hart；这些属于既有接口的系统级连接方式变化。

## 8. EH2 全部新增接口信号表

表中 `[1:0]` 均为 i0/i1 提交槽，除非信号名称明确表示单一非阻塞返回通道。所有端口方向均为 EH2 输出。

| 序号 | 新增信号 | 位宽 | 产生类别 | 产生方式 | 含义与作用 |
|---:|---|---:|---|---|---|
| 1 | `rv_commit_valid` | 2 | 简单运算 | `[0]=OR(dec_tlu_i0_commit_wb[各hart])`；`[1]=OR(dec_tlu_i1_commit_wb[各hart])`。 | 表示 i0/i1 槽当周期存在真实体系结构提交；作为同槽全部字段和日志序号分配的主有效信号。 |
| 2 | `rv_commit_insn` | 2×32 | 已有信号直连 | 分别连接 `i0_inst_wb`、`i1_inst_wb`；其流水元数据已解除 legacy trace-enable 门控。 | 提交指令的完整 32-bit 指令字，供哈希结构构造和调试。压缩指令按 EH2 已有流水表示输出。 |
| 3 | `rv_commit_pc` | 2×32 | 已有信号格式化 | `{i0_pc_wb[31:1],1'b0}`、`{i1_pc_wb[31:1],1'b0}`。 | 提交指令 PC；EH2 内部省略恒为零的最低位，接口补零恢复 32 bit。 |
| 4 | `rv_commit_hart_id` | 2 | 已有信号直连/拼接 | `{wbd.i1tid,wbd.i0tid}`。 | 指示每个提交槽属于 hart0 还是 hart1；所有按 hart 归约和 WAW 比较均依赖它。 |
| 5 | `rv_commit_priv_mode` | 2×2 | 常量 | 两槽均固定 `2'b11`。 | 报告当前验证程序的 M-mode 权限字段；当前不是动态权限状态，使用 S/U mode 时必须修改。 |
| 6 | `rv_commit_gpr_wen_intent` | 2 | 简单运算 | `wbd.i?v AND NOT dec_tlu_i?_kill_writeb_wb`。 | 表示指令具有未被 kill 的 GPR 目的写意图，发生非阻塞延迟或 WAW 抑制时仍可用于建立待补齐结构。 |
| 7 | `rv_commit_gpr_wen` | 2 | 已有最终控制直连 | `{dec_i1_wen_wb,dec_i0_wen_wb}`；该信号已排除 kill、普通同周期 WAW、非阻塞首次经过 WB 和 div 延迟写回。 | 表示当周期真正执行的普通 GPR 写回；哈希只在它有效时采用当前 `gpr_wdata` 作为最终结果。 |
| 8 | `rv_commit_gpr_rd` | 2×5 | 已有信号直连/拼接 | `{wbd.i1rd,wbd.i0rd}`。 | 每槽的目标通用寄存器号；用于写回描述、非阻塞结构索引和 WAW 比较。 |
| 9 | `rv_commit_gpr_wdata` | 2×32 | 已有信号直连/拼接 | `{dec_i1_wdata_wb,dec_i0_wdata_wb}`，来自原有 WB 结果。 | 普通提交的 GPR 写数据；只有相应 `rv_commit_gpr_wen` 有效时表示真实写回值。 |
| 10 | `rv_commit_csr_wen` | 2 | 已有控制直连 | `[0]=dec_i0_csr_wen_wb`；`[1]=0`。 | CSR 实际写使能。EH2 的 CSR 提交位于 i0，i1 字段由 packet 默认清零。 |
| 11 | `rv_commit_csr_addr` | 2×12 | 已有信号直连 | `[0]=dec_i0_csr_wraddr_wb`；`[1]=0`。 | 被写 CSR 的 12-bit 地址；只在同槽 `csr_wen` 有效时有体系结构意义。 |
| 12 | `rv_commit_csr_wdata` | 2×32 | 已有信号直连 | `[0]=dec_i0_csr_wrdata_wb`；`[1]=0`。 | CSR 最终写入数据，供提交结构与哈希使用。 |
| 13 | `rv_commit_is_nonblock` | 2 | 简单运算 | `rv_commit_is_nonblock_load OR rv_commit_is_nonblock_div`。 | 总的非阻塞标志；通知外部先保存结构、等待将来的最终 GPR 结果。 |
| 14 | `rv_commit_is_nonblock_load` | 2 | 条件判断 | 每槽由对应 hart 的 `cam_i?_load_kill_wen AND wbd.i?load` 产生，再与 `rv_commit_valid` 相与。 | 表示该提交是首次经过 WB、结果尚未返回的非阻塞 load。 |
| 15 | `rv_commit_is_nonblock_div` | 2 | 条件判断 | `[0]=wbd.i0div`、`[1]=0`，再与 `rv_commit_valid` 相与。 | 表示该提交是非阻塞 divide；EH2 divide 只使用 i0 槽。 |
| 16 | `rv_commit_waw_victim` | 2 | 新增同周期 WAW 逻辑 | `[0]=i0_same_cycle_waw_wb AND valid[0]`；`[1]=0`。比较两槽 valid、同 hart、同 rd、kill 及非阻塞角落条件。 | 标记同周期被年轻 i1 覆盖的老 i0 日志结构；外部记录该指令的 sequence，不把其写回计入最终状态。 |
| 17 | `rv_nb_waw_valid` | 2 | 新增跨周期 WAW 逻辑 | 每槽为“匹配任一已提交 load CAM entry”或“匹配 pending div”，再与该年轻槽 `rv_commit_valid` 相与。 | 表示当前年轻提交取消了一条更早的非阻塞 load/div；下标是年轻提交槽，不是 hart。 |
| 18 | `rv_nb_waw_victim_insn` | 2×32 | 新增状态保存/选择 | load 从匹配 CAM entry 的 `cam_commit_raw.insn` 取值；div 从 `div_commit_meta_ff` 取值；互斥后按位 OR 汇总。 | 被取消的旧非阻塞指令字，用于完整调试/验证其身份。当前系统归约连接未使用此字段，但网表已导出。 |
| 19 | `rv_nb_waw_victim_pc` | 2×32 | 新增状态保存/选择 | load/div 保存的 PC `[31:1]` 经匹配选择，输出最低位补零。 | 被取消的旧非阻塞指令 PC。当前系统归约连接未使用此字段，但可供波形和后续扩展。 |
| 20 | `rv_nb_waw_victim_hart_id` | 2 | 新增比较结果 | 取触发覆盖的 `wbd.i0tid/i1tid`；匹配条件已保证它与旧受害者 hart 相同。 | 被取消指令所属 hart；外部据此选择 hart0/hart1 的待补齐日志表。 |
| 21 | `rv_nb_waw_victim_gpr_rd` | 2×5 | 新增状态保存/选择 | load 从匹配 CAM entry.rd 取值；div 取 `div_rd`。 | 被取消非阻塞指令的目标寄存器；外部用 hart+rd 找到原先保存的待完成结构。 |
| 22 | `rv_nb_waw_victim_is_load` | 2 | 新增类型判断 | 对每槽的各 hart load-CAM WAW 匹配做 OR。 | 指示本次 pending WAW 受害者是非阻塞 load。当前系统归约连接未使用，但用于类型调试和互斥检查。 |
| 23 | `rv_nb_waw_victim_is_div` | 2 | 新增类型判断 | `{i1_nbdiv_waw_wb,i0_nbdiv_waw_wb}`。 | 指示本次 pending WAW 受害者是非阻塞 divide。当前系统归约连接未使用，但用于类型调试和互斥检查。 |
| 24 | `rv_nb_load_gpr_wen` | 1 | 已有最终控制的归约 | `OR(dec_nonblock_load_wen[各hart])`；每 hart 写使能已包含 data-valid、tag/hart 匹配且未被年轻写取消。 | 表示一条非阻塞 load 结果现在真正写入体系结构 GPR；触发外部补齐先前结构。 |
| 25 | `rv_nb_load_gpr_hart_id` | 1 | 已有信号直连 | `lsu_nonblock_load_data_tid`。 | 本次最终非阻塞 load 结果属于哪个 hart。 |
| 26 | `rv_nb_load_gpr_rd` | 5 | 已有状态条件选择 | 遍历各 hart 的 `dec_nonblock_load_wen`，选择唯一有效的 `dec_nonblock_load_waddr`。 | 本次最终非阻塞 load 写入的目标 GPR；和 hart 一起定位待补齐结构。 |
| 27 | `rv_nb_load_gpr_wdata` | 32 | 已有信号直连 | `lsu_nonblock_load_data`。 | 未被取消并最终写入 GPR 的 load 数据。 |
| 28 | `rv_nb_div_gpr_wen` | 1 | 已有最终控制直连 | `exu_div_wren`。 | 表示非阻塞 divide 结果现在真正写入体系结构 GPR；已取消 divide 不应产生该最终写回。 |
| 29 | `rv_nb_div_gpr_hart_id` | 1 | 已有信号直连 | `div_tid_wb`。 | 本次最终 divide 结果所属 hart。 |
| 30 | `rv_nb_div_gpr_rd` | 5 | 已有信号直连 | `div_waddr_wb`。 | 本次最终 divide 写入的目标 GPR。 |
| 31 | `rv_nb_div_gpr_wdata` | 32 | 已有信号直连 | `exu_div_result`。 | 未被取消并最终写入 GPR 的 divide 结果。 |

## 9. 当前系统对新增端口的实际使用

`eh2_core_crc_subsystem.sv` 将提交接口、`rv_nb_waw_valid/hart_id/rd` 以及最终 load/div 写回接口连接到 `instr_crc_system_dual`。外部模块据此：

1. 按 `rv_commit_valid + hart_id` 为每条提交指令分配 hart 内 sequence；
2. 把普通 GPR/CSR 写回值纳入指令结构；
3. 对非阻塞 load/div 建立等待项，结果返回后用 hart+rd 补齐；
4. 对 `rv_commit_waw_victim` 或 `rv_nb_waw_valid` 指定的旧结构记录 WAW 取消；
5. 在 EH2 外计算哈希、package 归约值和需要通过以太网发送的 WAW sequence。

当前集成中，`rv_nb_waw_victim_insn`、`rv_nb_waw_victim_pc`、`rv_nb_waw_victim_is_load`、`rv_nb_waw_victim_is_div` 在 `eh2_core_crc_subsystem` 实例处未连接，因为归约器已用 hart+rd 保存并定位原结构。这四组端口仍保留在 EH2 网表中，便于仿真定位受害者、验证事件类型和以后扩展，不应误判为被综合删除的全部 WAW 功能；真正参与归约关联的 `valid/hart_id/rd` 已连接。

## 10. 设计原因总结

新增接口没有直接复用原 trace 输出，核心原因有三点：

1. 日志必须工作在 trace 被关闭的配置下，并且必须与体系结构 WB 提交严格同周期；
2. 非阻塞 load/div 的“指令提交”和“结果写回”不在同一周期，必须拆成初始结构和最终结果两套接口；
3. WAW 受害者可能早已离开普通流水线，必须在 load CAM/div 跟踪状态旁保存原指令元数据，并使用同 hart、同 rd、真实写回和 kill/valid 条件进行判断。

因此，直接引出的信号负责描述 EH2 已有的提交事实，组合运算负责消除无效/被取消的微体系结构活动，新增状态保存和比较逻辑负责恢复跨周期非阻塞 WAW 的受害者身份。三者共同保证外部哈希系统看到的是完整、按 hart 隔离、与体系结构效果一致的指令事件流。
