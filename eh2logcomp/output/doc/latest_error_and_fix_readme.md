# EH2LOGCOMP 最终 10k 闭环、DMA 与 RGMII 时序问题记录

## 1. 文档适用版本

本文对应 2026-08-15 生成的最终交付：

- `output/board/eh2logcomp_2slot.bit`
- `output/board/eh2logcomp_2slot_postroute_timing_fixed.dcp`
- `output/board/reports_final`
- `output/board/riscvdv_10k_top`

本文只说明最后一轮 riscv-dv 10k、DDR1 DMA/双帧槽和 RGMII routed timing 中实际暴露的问题。系统历史问题见 `build_issue_readme.md`，全部前仿见 `veri_readme.md`。

## 2. riscv-dv 10k 为什么曾无法执行结束

### 2.1 行为

程序能够从 `0x80000000` 进入 EXECUTE，但某个 hart 不一定到达 stop；控制器因此一直等双 hart 完成，无法进入 END。单纯缩短程序或增加 watchdog 只能改变等待时间，不能修复地址或启动条件。

### 2.2 原因

随机主体不是可直接上板的完整程序。它必须由确定性的硬件包络完成以下工作：建立两个 hart 的栈和入口；只让 hart0 写 `csrw 0x7FC` 启动 hart1；保证 hart1 在初始化后才运行；为两个 hart 写结束 MMIO。硬件 ELF 中的 EH2 私有 CSR/停止 store 还需要在 Spike ELF 的相同 PC 上替换为等长指令，比较器再按 manifest 恢复硬件语义。

另外，当前 EH2 配置的普通 load/store 可以访问 DDR0，但 AMO/LR/SC 只允许访问内部 DCCM。把 riscv-dv 的全部数据统一放到外部 DDR 会使原子事务失败。riscv-dv 原始 `amo_0` 页又由两个 hart 共享，EH2 与 Spike 的调度顺序不同会造成结果不确定。随机 branch/jump 也可能跳过统一尾部或长时间回跳，不适合“快速执行完静态 10k 主体”的当前自动化模式。

### 2.3 修复

- 程序、复位向量和烧写地址保持 `0x80000000`。
- program 区间为 `[0x80000000,0xA0000000)`。
- 所有随机 LSU 地址总包络为 `0xA0000000–0xFFFFFFFF`。
- 普通 DDR 数据、双 hart 栈为 `[0xA0000000,0xD0000000)`。
- 原子页限制为真实 64 KiB DCCM `[0xF0040000,0xF0050000)`；hart0/hart1 当前实际页分别是 `0xF0040000–0xF004003F`、`0xF0040040–0xF004007F`。
- hart0 在 `csrw 0x7FC` 前清零两份 DCCM 原子页；两个 hart 不再共享 `amo_0`。
- 当前快速比较配置关闭随机 branch/jump 和子程序，但保留 RV32IMAC 的普通访存、乘除、压缩及原子覆盖。
- linker 用三个 PT_LOAD 隔离 program/data/amo；data/amo 为 NOLOAD，避免 objcopy 生成跨高地址的巨大稀疏 BIN。

最终 seed `32052517`：program 88,040 Byte，86 帧，普通随机 LSU 约 2,957 条、原子/LRSC 289 条；程序哈希为 `065E5AF9C246A612F6504B1A77F2C7DF9FFFE4F19FA30C914C2FABA9C351C70F`。

## 3. DDR1 写 DMA 为什么会永久 busy

### 3.1 连接关系

每 hart 的 4-write 异步 FIFO 在 DDR1 266.525 MHz 读侧一次给出最多两条 256-bit 记录，组成一个 512-bit beat。FIFO 与写 DMA 之间有 `info_fifo_read_elastic` 两级弹性队列，用于切断高频组合反馈。DMA 根据 occupancy 规划 AW burst，再通过 W 通道发送 beat。

### 3.2 错误

旧顶层把 `XPM rd_occupancy + elastic buffered_records` 相加。XPM 计数跨指针同步并在 pop 后滞后，已进入 elastic 的记录可能仍包含在 XPM 计数里。同一条记录被计算两次后，DMA 可能只有一个真实 beat，却发出声明两个 beat 的 AW。

AXI 的关键规则是：AW 一旦握手，主设备必须发送 `AWLEN+1` 个 W beat，并仅在最后一拍拉 `WLAST`。已接受的 burst 不能缩短。因此第二拍永远不存在时，DMA 会永久 busy。这也是板级看到“进入执行后总是 DDR1 DMA/双 buffer 错误”的直接原因之一，不是 MAC 读取速度慢。

### 3.3 修复和证据

burst 规划只使用保守的 XPM `rd_occupancy`；empty 同时检查 XPM 和 elastic。低估时只会产生一个较短 burst，elastic 尾部由单 beat fallback 排出，不影响 AXI 完整性。定向测试结果：hart0 259、hart1 150 条全部写完；最终顶层产生 hart0 12116、hart1 12601 条并正常进入 END。

## 4. DDR1 读 DMA/双帧槽为什么会重复帧

调度器的 `read_start`/`build_start` 是寄存的请求 pulse。旧判断发出 pulse 后只观察下游 `read_busy`；下一拍 busy 尚未建立时，旧条件会再次启动相同 frame number。修复后启动条件显式排除 `read_done/read_busy/read_start/build_start`，并要求构帧槽 ready、双槽未满、remaining 非零。`read_done` 优先更新 frame number 和剩余记录数。

每个槽完整保存一帧：14-Byte Ethernet header、4-Byte frame number、60×24-Byte记录。帧构造器每帧固定接收 30×512-bit beat；DDR1 读 DMA 只真实读取 `ceil(valid_records/2)` 拍，剩余拍在 DMA 内本地补零，避免访问未写 ECC 行。每个有效 beat 中两条 256-bit DDR 记录只取各自高 192 bit。UI 域先把槽置 dirty，30 beat 全到后 publish；125 MHz TX 域只有看到 publish 才读，整帧最后一字节握手后 release。两个槽都占用时不发新 AR，所以不存在在途 R 数据无落点的问题。

多帧/背压单元测试发出 6 个数据帧、2 个完成帧无重复；最终顶层发出 202 个 hart0 数据帧、211 个 hart1 数据帧和两个 done 帧。

## 5. WAW 为什么允许网络记录乱序

direct WAW 或普通记录可当拍完成；较老的 nonblock load/divide 必须等返回或取消后才补全。于是合法输出中可能先出现较新 sequence，再出现较老的延迟 sequence。严格按到达顺序递增会把这种行为误报为丢包，也会错误推动 RTL 为等待旧记录而阻塞处理器。

最终顶层和 WebUI 均按 hart 使用 sequence coverage：允许乱序，但每个 sequence 必须出现且只能出现一次。重复、越界、缺失仍然 FAIL。WAW victim 自身携带 kind、cancel number 和清零 data，比较器仍检查 cancel number 指向同 hart 的较新写者。

## 6. RGMII RX 为什么原来随复位表现为整轮好或整轮坏

### 6.1 根因

DP83867 内部 RX 延迟、FPGA IDELAY 校准和 RXC 全局时钟树共同决定采样点。最终主路由中，PHY RX code 3=1.00 ns、FPGA IDELAY=1100 ps、RX input delay=0/-1 ns，但原 `X3Y2` RXC root 的 5 条输入保持路径最差为 `-0.074 ns`。复位重新建立 PHY/RXC 相位后，采样点可能处在数据眼不同一侧，所以会出现“一次复位后每轮都正常；另一次复位后每轮都丢包/超时”的强相关行为。

确定性 RX 放行只能避免尚未稳定时过早接收，不能消除负的静态 hold 裕量；必须同时修改 routed clock balance。

### 6.2 不能采用的修复

1. IDELAY 1250 ps：时序看似通过，但器件/333.333 MHz 下最大合法值为 1100 ps，DRC 报 5 个 `AVAL-174`。
2. RXC root `X0Y1`：hold 变正，但 RGMII setup 变为 `-0.181 ns`。
3. 只调用 `update_clock_routing`：会留下一个 partially routed clock net，报 `RTSTAT-2`。
4. 在已路由时钟网直接用普通 auto-delay：不是正确的 UltraScale+ clock tree 重建流程，且内存曾升到约 24 GiB。

### 6.3 最终修复

五个 root 从同一原始 routed DCP 独立扫描，流程固定为：设置 `USER_CLOCK_ROOT`；只解 RXC 网；`update_clock_routing` 重建 gap tree；只补布 RXC 网；重新报告 setup/hold/route status。选择 setup/hold 最小裕量最大的 `X2Y2`。

最终结果：

| 项目 | 结果 |
| --- | ---: |
| 全局 WNS/TNS | +0.045 ns / 0（2026-08-25 完整重建） |
| 全局 WHS/THS | +0.009 ns / 0 |
| RGMII input setup/hold | +0.254 / +0.306 ns |
| 可路由网络 | 376352/376352 |
| routing errors | 0 |
| bus-skew violations | 0 |
| severe DRC / blackbox | 0 / 0 |
| Bitgen | 成功，0 Error、0 Critical Warning |

正式 XDC 已固定 `USER_CLOCK_ROOT X2Y2` 和合法 `DELAY_VALUE 1100`。旧 timing-fix 入口仅保留为兼容 wrapper，并直接调用合法 clock-root 流程，不再写 1250 ps。

## 7. 唯一最终顶层闭环结果

顶层仿真从 PRECONFIG 开始，不预装程序 DDR。PRECONFIG 通过真实 RGMII/MAC RX 注入一帧 1024 Byte 全 FF和结束帧，正式 DMA 写入 `0x80000000` 并回读；READY 后再按最小间隔注入 86 个 10k 程序帧和结束帧。DDR 镜像通过，hart0 在 `0x8000002C` 实际写 `csrw 0x7FC` 启动 hart1。

最终标志：

```text
PROGRAM_DDR_IMAGE_PASS frames=86 bytes=88064 final_addr=80015800
FULL_SYSTEM_RGMII_PASS frames=429 info=14 data=413 done=2
records=12116/12601 rgmii_cycles=608262 min_ifg=87
rx_overflow=0 ddr_writes=0/0
```

仿真约 20 分 48 秒。之后完成综合、opt/place/route、RXC 合法时钟树修复、最终签核和未压缩 bitstream 生成。

## 8. 后续修改的强制检查

- 改 RTL/XDC/IP/PHY 延迟/实现策略后必须重新综合与完整实现；不能只复用当前正裕量。
- IDELAY 值必须先通过器件 DRC；时序数字不能替代合法性检查。
- route status 必须确认 0 partially routed 和 0 routing errors。
- setup、hold、pulse width、unconstrained、bus skew、DRC、blackbox 都要检查，不能只看 WNS。
- AW/AR 握手前必须保证整笔 W/R 数据资源；burst 不得跨 4 KiB。
- WebUI 必须先监听再发送；FPGA 报错后立即停发并回送 `44124445`，等全局复位后重新开始。
- 最终文件烧写前用 `output/board/SHA256SUMS.txt` 校验，禁止使用 `reports_postroute_fix` 或旧哈希对应的 bitstream。
