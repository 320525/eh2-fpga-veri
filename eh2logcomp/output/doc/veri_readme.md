# EH2LOGCOMP 全部前仿与验证记录

## 1. 验证结论

本工程完成了以下四层验证：

1. 20 万条双 hart 程序的顶层 RGMII/MAC RX → DDR0 → EH2 执行 → Info 捕获/DDR1 写入长仿真；
2. 最终 60×24-Byte、30-beat、双完整帧槽版本的定向单元/集成/背压压力验证；
3. WebUI 的 782 帧程序镜像、系统帧、Info 数据/完成帧和 20 万条接收计数验证。
4. 2026-08-25 两轮严格串行的完整顶层随机回归：每轮从 RGMII RX 烧写 79 个程序帧、双 hart 各约 1 万条记录、DDR1 保存、334 个 Info 数据帧和 2 个完成帧经 RGMII TX 回传，再由真实 WebUI 解析器重读并检查全部 sequence。

随后使用与前仿一致的 RTL 完成综合、布局布线、时序签核和 Bitgen。最终 routed 设计无黑盒、无未路由网络、无 setup/hold 违例。

需要准确说明验证边界：最终双槽版本没有再次把 20 万条记录逐字节穿过完整物理 RGMII TX 仿真；该轮按需求以双 hart 完成 20 万条执行、Info 正常进入发送路径和双槽定向压力测试为验收点。之后先完成一轮 VM riscv-dv 10k 顶层闭环，又完成两轮本地快速随机程序的完整顶层闭环。两轮新回归均包含 PRECONFIG、READY、PROGRAM_WRITE、EXECUTE、END、实际 DDR1 读回和物理 RGMII TX，不是只测处理器提交。没有使用未运行的 Spike 值冒充逐记录网络输出的黄金结果。

## 2. 20 万条测试程序

- 原始 BIN：800640 Byte；
- SHA-256：`5D073F32602F986E6AE253F425046271C4255402067632DA7C6FFD43E4A1CCFC`；
- 从 DDR0 `0x80000000` 开始写入；
- 1024 Byte/程序帧，最后补 128 Byte 0；
- 共 782 个程序帧；每帧前置 32-bit 大端连续序号；
- 帧镜像 SHA-256：`d5e6e51284caf9aac26efe3a846f5694405f07144b4f9a4516874ddaeb7e73ae`。

测试程序由 hart0 写启动寄存器启动 hart1。仿真观察到 hart0 在 PC `0x8000000c` 提交启动写入，写入数据 `0x00000002`；随后 hart1 首次提交，从而证明 hart1 不是由测试平台直接强拉启动，而是由 hart0 的实际软件操作启动。

## 3. 顶层闭环长仿真完成的内容

测试平台实例化 `eh2logcomp_system_top`，在硬件引脚一侧注入 RGMII 帧，而不是在 DDR 内部直接预装完整程序。为避免仿真缺少串行 PHY 模型，仅设置 `PHY_INIT_BYPASS=1`；程序仍经过 RGMII RX、TEMAC RX FIFO、分类器、序号检查、DataMover 和 DDR0。

### 3.1 PRECONFIG

- 等待 PREINIT 信息；
- 从顶层注入 sequence=0 的一帧 1024 Byte 全 FF；
- 紧随其后注入声明总数为 1 的结束帧，不等待 DMA done；
- 检查控制器在“接收帧数=1、成功 DMA 数=1、DMA idle、ATG 完成”前不会启动 DDR 回读；
- 从 DDR0 `0x80000000` 回读并比较 1024 Byte 全 FF；
- DDR1 数据通路同时由 ATG 执行原写读检查；
- 验证 `11111111 → 44004444 → 44114444 → 22222222` 顺序。

PRECONFIG 的一帧只是程序写入通路自检。进入 READY 后程序会话计数清零，因此不会污染正式 782 帧程序。

### 3.2 READY 与正式程序烧写

- 验证 READY 清零器完成后才发 `33333333`；
- `33333333` 整帧完成后状态才变为 PROGRAM_WRITE；
- 按协议允许的最小 IFG（96 ns）连续注入 782 帧，不由测试平台等待每帧 DMA done；
- 最后一帧之后立即注入结束帧；
- 连续检查原始 MAC good/bad frame、分类器 accepted、DMA done、RX FIFO overflow 和帧缓冲 overflow；
- 仿真结果：782 帧全部接受，DMA done=782，RX overflow=0，分类器 overflow=0；
- DDR0 映像逐字节通过：`PROGRAM_DDR_IMAGE_PASS frames=782 bytes=800768 final_addr=800c3800`；
- 验证结束帧先到也不能提前通过，只有帧总数=声明总数=DMA 完成数且 busy=0 才发送 `44444444`。

同时验证第一笔 AXI 写产生 `44004444`，结束帧产生 `44114444`，DMA 配对后产生 `44444444`；程序接收过程中序号错误会立即进入 ERROR，结束总量错误由结束帧比较发现。

### 3.3 双 hart 执行和逐指令信息

- 状态按 PROGRAM_WRITE → EXECUTE → END 运行；
- hart0/hart1 首条真实提交分别产生 `55000000/55010000`；
- 两 hart 实际停止分别产生 `550000FF/550100FF`；
- 执行结束计数为 hart0 100023 条、hart1 100021 条，总计 200044 条；
- Info 生成计数和 DDR1 写 DMA 成功计数逐 hart一致；
- 验证两个 hart 的 sequence 独立从 0 递增；
- 程序中保留 direct WAW 和 nonblock WAW 相关性，结构采集测试覆盖 kind、victim sequence、被取消数据清零和不同 hart 隔离；
- 只有双 hart stop、所有待决 nonblock 已解决、Info FIFO/DMA 排空、IFU/LSU AXI idle guard 完成后才进入 END。

长仿真在旧的流式发送缓冲处继续发送时暴露了真实的回传 overflow。这不是掩盖掉的失败：该问题直接促成最终“构帧侧固定 30-beat、DDR 侧按有效行读取并本地补零”+ 双完整帧槽结构；修复后的发送结构使用下面的定向压力测试验收。

## 4. 最终 Info 路径定向验证

### 4.1 Info 采集单元

`tb_instr_info_capture.sv`：

- 双 hart 同周期提交；
- 每 hart 独立 sequence；
- GPR、CSR、无写回事件；
- direct WAW；
- nonblock load/divide 正常返回和 WAW 取消；
- 同周期多事件并发与 ready 背压；
- stop marker 和 capture done。

结果：`PASS tb_instr_info_capture h0next=3 h1next=3`。

### 4.2 四写异步 FIFO 与奇数尾记录

`tb_info_fifo_async_tail.sv` 使用异步写/读时钟，写入 17 条记录，覆盖四 lane 同周期写入、读侧每拍最多两条、最后单条 flush、顺序和 occupancy。修复后的 one-hot lane 读选择验证结果：

`INFO_FIFO_ASYNC_ODD_TAIL_PASS records=17 cycles=182`

### 4.3 FIFO 弹性层 + DDR1 写 DMA

`tb_info_elastic_dma_integration.sv` 同时给 hart0/hart1 产生不规则数量和背压，检查 512-bit beat 拼接、1/2 条记录的 WSTRB、交替仲裁、64-beat 上限、4 KiB 边界、记录总数和内容顺序。

最终修复后结果：`INFO_ELASTIC_DMA_INTEGRATION_PASS h0_records=259 h1_records=150 cycles=305`。

### 4.4 构帧侧固定 30-beat 的 DDR1 读 DMA

`tb_info_ddr_read_dma_fixed30.sv` 覆盖帧构造器固定接收 30 个 512-bit beat、真实 DDR 只读 `ceil(valid_records/2)` 拍、剩余拍本地补零、frame_number×1920 地址、遇 4 KiB 边界拆分、数据索引 0..29、`RLAST/RRESP` 检查。

结果：`TB_PASS: fixed 30-beat DMA and 4-KiB split passed`。

### 4.5 双完整帧槽压力测试

`tb_info_tx_frame_fifo_2slot.sv` 覆盖：

- 第一个槽 dirty 时对 TX 不可见；
- 第一帧发布后 TX 读取，同时 UI 域构造第二帧；
- 两槽占用即 full，第三次构造被背压；
- 在帧头、帧号、记录区随机/长时间拉低 `m_axis_tready`；
- `tvalid`、数据、索引和 `tlast` 在背压期间保持；
- 第一帧最后一字节握手后才释放槽，full 才解除；
- 60 条记录次序、24-Byte 截取、最后帧无效记录补零；
- publish/release toggle 跨 UI/125 MHz 域；
- 连续两帧发送和恢复。

结果：`TB_PASS: two-slot full/backpressure/recovery/data-order test passed`。

该测试直接对应“DMA 明显快于 MAC 时是否会覆盖正在发送的帧”问题。DMA 只能写 dirty 槽，TX 只能读 valid 槽，两槽同时占用时 read DMA 停止，因此不会覆盖；MAC 一旦持续 ready，第二槽已准备好，可在切帧时继续全速发送。

## 5. 程序配对和错误反例

定向测试覆盖：

- PRECONFIG 结束帧声明不为 1，进入 `ERR_PROGRAM_COUNT`；
- 程序 sequence 跳号，立即 `ERR_PROGRAM_SEQUENCE`；
- 帧长度不是 `14+4+1024`，产生 length error；
- 结束帧总数与已接受帧数不一致；
- 结束帧已收到但最后一次 DMA 仍 busy，保持等待；
- DataMover 状态 EOP、BTT、OKAY、error flags 或 tag 任一错误；
- ERROR 只发送一次首个错误，收到 `44124445` 后才全局复位。

这里不存在“目标 3 帧”的硬编码；正式系统比较的是结束帧声明的动态总数。20 万条程序的系统级目标是 782 帧。

## 6. WebUI 验证

2026-08-25 最终运行 `python -m unittest discover -s webui/tests -v` 共 24 项全部通过，覆盖：

- 800640-Byte BIN 生成 782 帧，与前仿帧镜像逐字节一致；
- 程序帧、最后补零、结束帧和 HOST_SEND_STOPPED；
- 系统状态/错误码；
- 1444-Byte Info 数据帧、24-Byte 记录和 WAW 字段；
- H0DN/H1DN 完成帧；
- 帧号、sequence、metadata hart、尾部 padding 连续性；
- 模拟接收 hart0 100023 条和 hart1 100021 条：各 1668 帧（60 条/帧），两个完成帧比较 PASS；
- JavaScript 语法检查、Python AST、应用异步 API smoke test。

Windows 捕获热路径使用 64 MiB Npcap 内核缓冲和原始字节读取；抓包线程只入队，完整逐条 TXT、异步 PCAP 和页面事件在后台线程完成，避免 Python 解码或磁盘写入阻塞线速抓包。页面同时报告 Npcap 内核/接口丢包计数。

## 7. 综合、实现和签核

- 最终综合：0 Error、0 Critical Warning；
- 结构审计：顶层所需 RTL/IP 均存在，post-opt/post-route 黑盒为 0；
- opt/place/route 全部完成；
- 最终 routed DCP 可路由网络 376352，全部 fully routed，routing errors=0；
- WNS `+0.045 ns`，TNS `0`；
- WHS `+0.009 ns`，THS `0`；
- RGMII 外部输入 setup/hold `+0.254/+0.306 ns`；
- 74 组 bus-skew 全部通过，最差 slack `+2.218 ns`；
- severe DRC=0；Bitgen 成功；
- 实现峰值内存约 19104 MB；最终策略以防止内存崩溃为优先。

最终时序裕量很窄，因此“当前 bitstream 已签核”不等于后续修改可沿用该结论。任何 RTL、XDC、Vivado 版本、seed/directive、IP 参数或 PHY 延迟变化后都必须从综合开始重新运行。

## 8. 最终 riscv-dv 10k 顶层闭环

最终一次完整系统仿真使用 VM 生成的 seed `32052517`、RV32IMAC、2 hart、每 hart 10,000 条随机主体程序。IFU/程序镜像仍从 `0x80000000` 开始；普通随机 LSU 位于 `0xA0000000–0xA0035A7F`，hart0/hart1 原子页分别为 `0xF0040000–0xF004003F` 和 `0xF0040040–0xF004007F`。程序 BIN 为 88,040 Byte，SHA-256 为 `065E5AF9C246A612F6504B1A77F2C7DF9FFFE4F19FA30C914C2FABA9C351C70F`。

验证从顶层状态机开始，未直接预装 DDR：

1. PRECONFIG 从 RGMII/MAC RX 注入 1 个全 FF 程序帧和结束帧，正式 1024-Byte DMA 写入 `0x80000000` 后回读通过，DDR1 ATG 同时通过。
2. READY 完成后进入 PROGRAM_WRITE；86 个 payload=`frame_number+1024 Byte` 的程序帧按最小允许间隔连续注入，结束帧不等待最后一笔 DMA。系统只在帧数、结束声明、DMA done 和 idle 一致后发送 `44444444`。
3. DDR0 烧写镜像逐字节核对通过：`PROGRAM_DDR_IMAGE_PASS frames=86 bytes=88064 final_addr=80015800`。
4. hart0 在 PC `0x8000002C` 实际提交 `csrw 0x7FC`，数据为 2；随后 hart1 从 `0x80000000` 首次提交，证明启动来自真实程序而不是测试平台强制。
5. 捕获并写入 DDR1 的记录数为 hart0 `12116`、hart1 `12601`。执行结束后分别生成 202、211 个数据帧，尾帧补零规则正确。
6. RGMII TX 物理输出共 429 帧：系统信息 14、Info DATA 413、Info DONE 2；两 hart 的全部记录均按 sequence coverage 收齐，无重复、无越界。
7. 最终结果：`FULL_SYSTEM_RGMII_PASS ... min_ifg=87 rx_overflow=0`，仿真耗时约 20 分 48 秒。测试平台的 `min_ifg=87` 是其 RGMII 驱动/统计的周期计数结果，程序注入没有为 DMA done 人为插入等待。

这次长仿真还暴露并修复了两个此前短测试未触发的问题：写 DMA 对 XPM occupancy 与 elastic queue 重复计数会声明过长 AW burst；回传调度器的注册 `read_start/build_start` 脉冲可能导致同一帧重复启动。两项修复均先做定向测试，再完成上述唯一完整顶层闭环。详细根因见 `build_issue_readme.md`。

## 9. 2026-08-25 两轮最终自动化回归

用户将原计划的十轮缩减为两轮，因此最终只执行并认可两轮；自动化脚本默认值也已改为 2。证据目录为 `output/verification/automation_10x10k/campaign_20260825_005851`，`campaign_summary.json` 明确记录 `rounds_requested=2`、`completed_rounds=2`、`status=PASS`。`round_03_seed_32052533` 只是在取消前生成了程序文件，没有启动 Vivado、没有仿真结果，不计入通过轮次。

两轮共同条件：

- 每轮使用不同 seed：`32052531`、`32052532`；BIN SHA-256 分别为 `ad6dd8bc...c1e5` 和 `02585e66...2fb8`；
- 本地生成 RV32IM 指令，运行环境保持 RV32IMAC；hart0 独占执行 `csrw 0x7FC,2` 启动 hart1；
- 程序 80024 Byte，拆为 79 个 `4-byte frame number + 1024-byte program` 帧；
- 从顶层 RGMII RX 以 96 ns IFG 连续注入，不等待逐帧 DMA；结束帧紧随最后数据帧；
- 每轮结果均为 `FULL_SYSTEM_RGMII_PASS frames=350 info=14 data=334 done=2 records=10001/10000 rgmii_cycles=492132 min_ifg=80 rx_overflow=0`；
- hart0 10001 条是停止 store 提交后、AXI 停止握手形成前允许的 drain window 行为；检查规则要求每 hart 处于目标 10000 到 10016 的硬件包络，并以完成帧声明值检查实际 sequence，不把 10000 写死；
- hart0/hart1 各 167 个数据帧和 1 个完成帧，WebUI 重新解析 `.eh2log` 后验证源 MAC、EtherType、帧号、记录总数、最后 sequence、无重复、无缺失和尾帧补零；
- 下一轮程序只有在上一轮完整顶层仿真和 WebUI 日志检查均 PASS 后才允许生成，验证了 strict sequential barrier。

前两次试运行曾因测试平台把“目标随机主体 10000 条”错误等同于“停止握手前精确提交 10000 条”而报告 10001，不是 RTL 记录重复。修复仅调整测试判定为明确的 stop-drain window，网络完成帧中的实际记录数、连续 sequence 和 DDR1 内容仍逐条验证。

## 10. 2026-08-25 专项回归

生产采集器拆成两个物理 hart bank 后，运行 50000 周期差分仿真，把新结构与保留的单体参考模块逐周期比较，外部完整签名一致。参考模块只用于测试，综合审计确认没有进入生产网表。

最新 Info 路径回归全部通过：

- `tb_info_fifo_read_elastic`：1000 beat/1999 records，随机背压；
- `tb_info_elastic_dma_integration`：hart0 259、hart1 150 条，随机 AXI 背压与公平轮转；
- `tb_info_ddr_read_dma_fixed30`：有效行真实读取、本地补零到固定 30 beat，以及 4 KiB 拆分；
- `tb_info_tx_frame_fifo_2slot`：两槽 full、背压、释放恢复和数据顺序；
- `tb_info_log_dump_subsystem_multiframe`：419 帧、12510 次 DDR read，覆盖超过板上早期约 205 帧故障点；
- `tb_info_fifo_async_tail`：真实 XPM async FIFO 的 17 条奇数尾记录；
- capture/basic/handoff/differential、控制状态机、PRECONFIG 只能一帧、RX 分类、程序 DMA 序号、DDR 检查、FCS/overflow/error CDC 均通过。

这组测试补齐了过去只验证“产生少量记录”而没有让发送端处于长期满速背压的缺口。
