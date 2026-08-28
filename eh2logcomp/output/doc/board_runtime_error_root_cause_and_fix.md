# 板级运行错误归因、代码修复与验证记录

## 1. 结论

本轮日志中的 `C1/C2`、`C11/C12`、`C4` 和 WebUI 只能点击一次不是同一个故障，而是四条相互独立的代码路径：

1. `C1/C2`：DDR1 写 DMA 的 `active_hart` 原来只在首选 hart 为空时切换；持续有数据的一侧会长期占有 DMA，另一侧 FIFO 最终溢出。
2. `C11/C12`：每 hart、每目的寄存器只有一个 nonblock 等待槽，但旧交接条件没有覆盖“旧结果已经返回但尚未发射”和“结果返回与年轻指令同拍分配”等合法情况，因此把合法执行误报为 overflow。
3. `C4`：旧硬件把 AXI `RRESP`、AXI `RLAST`、整帧构造协议、帧槽释放计数四种错误合并为一个码，日志无法反推出是哪一位。代码审计确认双时钟帧槽还直接使用 100 MHz 控制域产生的 `hard_resetn`，在 266.5 MHz UI 域和 125 MHz TX 域异步释放；这与“同一复位周期内结果固定、重新全局复位后模式改变”的板级现象一致。定向长仿真和同程序顶层仿真排除了固定帧数、4 KiB 边界、最后一帧补零和持续 MAC 背压导致的确定性错误。
4. WebUI：后端为保留诊断信息而保留失败轮次的 `run_id`，前端却把“存在 run_id”直接解释为“仍在运行”，所以失败后按钮永久 disabled。

## 2. DDR1 写 DMA 的 hart 饥饿

### 2.1 原代码行为

`info_ddr_write_dma.sv` 使用 `active_hart` 选择本次 AXI burst 的来源。旧代码完成 burst 后没有旋转该优先令牌。只要当前 hart 的 elastic FIFO 一直非空，状态机每次回到 IDLE 都会再次选择同一 hart；另一 hart 只有在当前侧瞬间为空时才可能得到服务。

这不是 DDR1 总带宽不足。DDR1 UI 为 512 bit、约 266.5 MHz，每 beat 可写两条 256-bit 记录，64-beat burst 可写 128 条记录。问题是仲裁没有提供有限等待时间，总吞吐量足够也不能防止单侧饿死。

### 2.2 修复

每次收到 AXI B 响应、确认整个 burst 完成后执行：

```systemverilog
active_hart <= ~active_hart;
```

`active_hart` 现在是“下一笔优先令牌”，不是永久 owner。如果首选侧为空，原有 fallback 仍会立即服务另一侧；如果两侧都非空，则最多等待另一侧一个 64-beat burst。

### 2.3 验证

`tb_info_elastic_dma_integration.sv` 同时向两侧持续写入，并在 AXI AW/W 随机施加背压；检查前两笔 burst 来自不同 hart、所有记录顺序和最终计数正确。结果：hart0 259 条、hart1 150 条全部写入，无 overflow。

## 3. nonblock 同寄存器合法交接被误报

### 3.1 原代码行为

`instr_info_capture_dual.sv` 的每个 `hart × rd` 维护一个等待槽。旧代码只允许槽为空，或旧指令尚未 resolved 且同拍收到匹配 WAW cancel 时接收年轻指令。以下合法时序被错误拒绝：

- 旧 load/div 结果已经 resolved，但记录还在等待移入 emit 槽；
- 旧结果返回与年轻 nonblock 指令分配到同一 `rd` 发生在同一个周期；
- WAW cancel 在旧结果 resolved 后、记录真正 emit 前到达。

因此错误名虽然是 `NONBLOCK_OVERFLOW`，实际并非容量真的耗尽，而是缺少原子交接分支。

### 3.2 修复

增加 `nb_atomic_struct[hart][rd]` 组合快照。年轻指令接管槽之前，旧记录可在同一拍按以下优先级完整移入 emit：

1. 匹配的 WAW cancel；
2. 已 resolved 的旧记录；
3. 本拍刚返回的旧结果。

cancel 优先于返回值；晚到 cancel 会把已保存记录改为 cancelled、结果清零，并写入 `waw_cancel_kind/number`。只有 emit 槽确实无法接纳旧记录时才报告冲突。

### 3.3 验证

新增 `tb_instr_info_capture_handoff.sv`，覆盖 resolved 后交接、返回同拍交接、晚到 WAW cancel 和年轻指令继续执行；并复跑原有 capture 回归。两项均通过，两个 hart 的 error 保持为 0。

## 4. C4 回传错误与跨时钟复位

### 4.1 为什么旧日志不能直接给出 C4 的唯一子原因

旧 `info_log_dump_subsystem.sv` 对以下条件统一置位 `error_ui`：

- DDR1 读返回 `RRESP != OKAY`；
- `RLAST` 与计划 burst 长度不一致；
- DMA beat 序号、最后 beat 或帧槽占用协议错误；
- 帧槽 release 到达时 `frames_outstanding == 0`。

错误监测器只把这个汇总位编码成 `0x666600C4`。因此旧 JSON 只能证明错误来自回传子系统，不能证明具体是哪一个条件；任何声称仅靠旧 C4 就能区分四者的结论都不可靠。

### 4.2 确认存在的板级结构问题

双帧槽 UI 侧工作在 DDR1 `c1_ui_clk`（约 266.5 MHz），TX 侧工作在 `clk125`。旧模块却让两侧状态机、`publish_toggle` 和 `release_toggle` 直接使用控制域生成的同一个 `hard_resetn`。低电平异步复位可以同时清零，但高电平释放发生在 100 MHz 控制时钟边沿，与另外两个时钟都没有确定相位关系，存在 reset-removal 风险。

这类问题的行为特征正是：一次全局复位后建立一种固定初始相位，该轮可能一直正常或一直失败；重新复位后相位重建，行为可能改变。纯 RTL 仿真没有模拟触发器 reset-removal 亚稳态，因此同一程序在理想仿真通过并不能消除该板级风险。

### 4.3 修复

- UI 域：复位可由 `hard_resetn` 或 MIG `c1_ui_resetn` 异步拉低；通过 3 级 `ASYNC_REG` 管线在 `c1_ui_clk` 上同步释放。
- TX 域：由 `hard_resetn` 异步拉低；通过独立 3 级 `ASYNC_REG` 管线在 125 MHz 上同步释放。
- `info_tx_frame_fifo_2slot` 和 `info_log_dump_subsystem` 分别接收 `ui_resetn`、`tx_resetn`；普通 UI/TX 状态寄存器不再跨域直接释放复位。
- toggle event CDC 保留公共异步复位输入，其内部本来就会在源、目的时钟域分别同步释放。

### 4.4 错误码拆分

| 代码 | 含义 |
| --- | --- |
| `0x666600C4` | DDR1 读 DMA 收到非 OKAY `RRESP` |
| `0x666600C7` | AXI `RLAST`/burst 长度协议错误 |
| `0x666600C8` | DMA beat 序号、last 或整帧槽构造/占用协议错误 |
| `0x666600C9` | 帧槽释放计数下溢 |

以后板上若仍有回传异常，上位机日志可直接指出一级原因，不需要再次从一个聚合 C4 猜测。

### 4.5 验证

- 双帧槽定向测试：两个完整帧槽占满、长时间 TX 背压、释放、复用和逐字节顺序均通过。
- 长寿命回传：hart0 12,360 条（正好 206 帧）、hart1 12,601 条（211 帧且最后一帧补零），共 417 个数据帧和 2 个完成帧通过；12,510 个 DDR beat 全部读取。
- 板级失败程序顶层闭环：结果见第 7 节。

## 5. WebUI 失败后不能再次点击

后端失败时保留 `Round` 和 `run_id` 是为了保存第一处失败序号、日志和生成物；这不等于后台线程仍在运行。后端现在显式返回 `can_start`：仅在自动化未 enabled 且没有轮次，或保留轮次状态为 FAILED/STOPPED 时为真。前端按钮只根据 `can_start` 禁用，并在失败/停止状态显示“重新启动一键自动化”。

新增回归先构造失败轮次，确认诊断对象和 `run_id` 仍保留，再次点击能够创建新轮次。WebUI 共 23 项测试全部通过。

## 6. 修改文件

- `rtl/ddr/info_ddr_write_dma.sv`
- `rtl/info/instr_info_capture_dual.sv`
- `rtl/eth/info_log_dump_subsystem.sv`
- `rtl/eth/info_tx_frame_fifo_2slot.sv`
- `rtl/eh2logcomp_system_top.sv`
- `rtl/control/system_error_monitor.sv`
- `rtl/common/eh2_system_pkg.sv`
- `webui/eh2web/automation.py`
- `webui/eh2web/protocol.py`
- `webui/static/app.js`
- 对应定向测试与顶层程序镜像文件

## 7. 最终闭环、综合和 bitstream

后续进一步确认 `0x666600C4` 的实际触发点是尾帧读取未写 ECC 行：旧读 DMA 无论有效记录数多少都发出 30 个真实 DDR beat。最终修复改为只读取 `ceil(valid_records/2)` 个真实 beat，并在 DMA 内本地补零到构帧侧固定 30 beat；奇数尾写同时改为完整 512-bit 行写入，使 MIG 生成确定 ECC。详细归因见 `latest_100k_end_and_host_capture_fix_readme.md` 和 `final_20260825_ecc_capture_bitstream_readme.md`。

最终一次 10k 双 hart 顶层 RGMII 闭环通过：79 个程序帧从实际 MAC RX/DMA 写入 DDR0，记录数 10001/10000，发送 334 个数据帧、2 个完成帧和 `77777777`，RX/FIFO overflow 为 0。生产格式输出保存在 `output/verification/current_fix_full_top/fpga_info.txt`。

综合、实现与 bitstream 均完成：post-route blackbox 0、376352/376352 个可路由网络 fully routed、routing errors 0、WNS `+0.045 ns`、WHS `+0.009 ns`、74 组 bus-skew 全部通过且最差 `+2.218 ns`、严重 DRC 0。

最终文件：

- `output/board/eh2logcomp_2slot.bit`：SHA-256 `EF901C78E23654CBC8741E3DDA76C6D967BC92631A15A882FCA45CF745A150BB`；
- `output/board/eh2logcomp_2slot_routed.dcp`：SHA-256 `A17FA0DA86643C92840675E234045E0F15D2B7179BEA1E009F9AD15B77D0621E`；
- `output/board/implementation_20260825_164411_214114.log`：本轮完整实现日志；
- `output/board/reports_latest/`：正式 timing、bus-skew、route 和 DRC 报告。
