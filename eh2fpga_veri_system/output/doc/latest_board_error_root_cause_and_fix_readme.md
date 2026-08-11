# 板级丢包、程序超时与 WAW 列表异常归因及修复记录

## 1. 文档范围

本文档记录 2026-08-05 至 2026-08-06 板级运行中两类问题的证据、数据流分析、RTL/约束修改、前仿与 Vivado 实现结果：

1. 硬复位后第一次程序发送若丢包、超时或无响应，同一次复位前的后续会话会重复相同模式；再次硬复位可能改变结果。
2. 归约 hash 值能与黄金值一致，但 hart0 的 WAW 序号列表偶发多出若干项；多出值位于 hart1 相邻 WAW 序号之间。

本次最终位流已完成综合、布局布线、时序签核和 bitstream 生成。物理 RX 改动已进入位流；WAW 问题的最终结论必须用这个新位流再做板级复测，不得用 behavioral simulation 代替这一结论。

## 2. 板级日志证据

分析过的上位机日志为：

- `saved_log_20260805_154309_160489.json`
- `saved_log_20260805_154447_415453.json`
- `saved_log_20260805_154627_039135.json`
- `saved_log_20260805_154835_103265.json`

结果具有以下稳定特征：

- hart0/package0 黄金 WAW 只有 `[18, 20, 26, 28]`；
- hart1/package0 黄金 WAW 为 128 项，以 `17,19,25,27,...,521,523` 的相邻对形式出现；
- 异常轮次中，hart0 多出值例如 `50,154,290,426`、`74,210,346,482`、`58,194,330,466`；这些值位于 hart1 相邻对之间，而且多出个数随会话变化；
- 四帧 CRC/hash 的 count、`xor0/xor1`、`sum0..sum3` 仍与 Spike 黄金值一致；
- 成功、丢包、超时模式通常在一次硬复位周期内保持，再次硬复位后可改变。

因此两类问题不能简化为“上位机偶发少发一帧”或“CRC 算法错误”。

## 3. 程序接收数据流与原因

正式程序流为：

```text
WebUI/Npcap
  -> 1042-byte Ethernet frame
  -> DP83867 RGMII
  -> TEMAC FCS/length check
  -> MAC RX asynchronous FIFO
  -> 100 MHz streaming classifier
  -> sequence/length checker
  -> 1024-byte AXI-Stream payload
  -> DataMover S2MM
  -> MIG0 instruction DDR at 0x80000000 + sequence*0x400
```

WebUI 用同一个原始二层发送句柄连续提交 782 帧程序数据，然后立即提交结束帧；它不等待最后一帧 DMA done。FPGA 内部只在“结束帧总数 = 连续接收数 = DMA 成功数”且 DataMover idle 时发送 `PROGRAM_WRITE_DONE=0x44444444`。

旧分类器会完整收一帧、停止读 MAC FIFO、再重放一帧。虽然 FIFO 读侧理论带宽是 `16 bit @ 100 MHz = 200 MB/s`，两遍处理使持续服务能力低于千兆线速，这是早期 RX FIFO overflow 的 RTL 原因。当前分类器只保留目的 MAC 的3个 16-bit word，其余数据单遍流式转发，已去掉该结构性吞吐瓶颈。

板上仍然呈现“每次复位后固定成功或固定失败”，与 DP83867 内部 RX delay、FPGA IDELAY 校准和恢复 RX clock 的启动相位每次复位后重新建立的特征一致。旧采样点的 hold 余量只有约 0.047 ns；单帧 PRECONFIG 可能通过，但 782 帧中出现至少一帧 FCS 错误的概率显著增大。TEMAC 丢弃坏 FCS 帧后，旧版只能在结束帧比较或 20 s watchdog 才发现，所以上位机看到超时或无响应。

## 4. RGMII RX 时序与确定性改动

### 4.1 PHY 延时重新标定

DP83867 保持 `RGMII_ID`，但将 RX 内部 delay code 改为 4（约 1.25 ns），TX code 保持 7（约 2.00 ns）。MDIO 初始化对 `RGMIICTL` 和 `RGMIIDCTL` 写入后进行回读比较，避免写入未生效时仍进入收包状态。

FPGA 端保留 1100 ps RX IODELAY，输入约束与 PHY 一起改为上升/下降沿 `-0.250 ns / -1.250 ns`。这个修改将旧配置中过多的 setup 余量转移到紧张的 hold 侧，使采样点更接近数据眼中心。PHY 延时和 XDC 必须成对修改，不能只改其中一边。

### 4.2 确定性 RX 启动放行

全局复位释放后，RX 客户端不立即读数据，而是依次等待：

1. MAC AXI4-Lite 配置完成；
2. DP83867 寄存器配置及回读成功；
3. 自动协商完成，链路连续稳定 100 ms；
4. 再等待 1 ms IDELAY guard；
5. 在 `rgmii_rxc` 域观察 4096 个连续 RX 时钟边沿；
6. 将 ready 同步回 100 MHz 控制域，最后释放 MAC RX 客户端 FIFO。

这使每次上电或全局复位都重新完成 PHY/IDELAY/RX clock 的确定性建立，比旧版“配置 done 就立即放行”具有更好的启动稳定性。

### 4.3 FCS 错误不再静默

TEMAC RX statistics 中的 FCS error 事件经过专用 CDC 计数器进入 100 MHz 控制域。首次错误立即锁存 `ERR_MAC_RX_FCS=0x66660075`，进入 ERROR 并发送一次错误帧。定向前仿注入两次事件，获得 `pulses=2, count=2`，证明该窄事件不会因跨时钟域而丢失。

## 5. 包错误、上位机停止和全局复位

- 程序帧序号不连续时立即发送 `0x44440055`，不等待结束帧；
- 帧长、RX FIFO、FCS、DMA 或其他程序通路错误也立即进入 ERROR；
- 上位机收到任一错误码后立即停止后续程序帧，然后发送 `HOST_SEND_STOPPED=0x44124445`；
- FPGA 要求“错误帧已物理发送完成”且“已收到 HOST_SEND_STOPPED”同时成立，才提出全局复位；
- 正常 END 中的 `EH2_DONE/EXE_END` 也必须由 MAC 物理完成计数证明已离开 TX 通路，然后才复位；
- 复位监督器将全系统 reset 保持 64 个 100 MHz 周期，覆盖 MAC、PHY、MIG、FIFO、DMA、EH2、CRC/WAW 和状态机，然后从 PRECONFIG 重启。

这取消了旧版只清除局部会话计数的软复位，目的是避免第一次丢包/超时后残留的 FIFO、DataMover、PHY/MAC 或日志状态污染后续会话。

## 6. WAW 多出序号的分析边界

### 6.1 已证明的事实

1. CRC/hash 值与黄金值一致，说明 EH2 提交结构和归约累加器没有把多出列表项当成一条额外有效指令重新计算。
2. 多出值不固定，且呈现 hart1 相邻 WAW 对的中间值特征，因此问题局限在 WAW sideband 事件、CDC FIFO、会话复位或序号存储路径，不是 CRC-64 多项式或日志帧字节序错误。
3. RTL 使用四个 33-bit×16 异步 FIFO 保留同周期两个 direct victim 和两个 pending-nonblock victim；每 hart/package 的最大可发数仍为 483，四个 FIFO 不改变协议容量。

### 6.2 当前位流已做的处理

新位流在每次正常结束或错误恢复时重置 WAW 四路 XPM FIFO、`waw_sequence_store` 的 count/bank-valid/package 以及日志 packetizer，不再保留旧会话的局部状态。定向前仿中导出的结果为 hart0=4、hart1=128，全部 132 项顺序与黄金值一致。

### 6.3 不能过度声明的部分

截止本文档生成时，新位流还没有用同一块板卡连续运行多轮并确认“hart0 始终只有4项”。因此全局复位已解决旧会话残留条件，但不把这写成 WAW 板级异常已被物理实验证明完全消失。

最新 `report_cdc` 还会把全局异步复位进入 XPM FIFO 复位机的路径标为 Critical：`CDC-1=160`、`CDC-7=339`、`CDC-10=33`、`CDC-11=6`。其中 `CDC-10` 的31位是 TX 完成计数器 Gray 编码组合网络，其他主要是 PHY/RX ready 和全局 reset 结构。这些分类不是 WAW 数据已错的直接证据，但是如果新位流仍复现 WAW 多项，下一步必须：

1. 用 ILA 同时采集 50 MHz 端 `waw_cancel_valid/hart/package/sequence`和 100 MHz 端出 FIFO 事件；
2. 区分伪事件是在 EH2 sideband 产生，还是在 XPM FIFO 释放后出现；
3. 对四个 FIFO 的 `wr_rst_busy/rd_rst_busy` 加入显式事件门控，并将全局 reset 在 50/100/125 MHz 及 RX 恢复时钟域改为异步置位、同步释放；
4. 重跑 WAW 定向前仿、CDC/methodology、综合、布局布线和 bitstream。

## 7. 前仿回归结果

最终只执行了一次顶层 20 万条闭环长仿真，程序不是测试平台直接写 DDR，而是拆成 782 帧，通过顶层 RGMII/MAC RX→分类器→DataMover 写入 `0x80000000`。完整路径检查到：

```text
FULL_SYSTEM_RGMII_PASS frames=18 info=14 log=4 rgmii_cycles=5208 min_ifg=783 rx_overflow=0
FULL_SYSTEM_FRAME_PASS frames=18 info=14 log=4 errors=0
```

其他定向结果：

- MAC RX FCS 事件/CDC：`pulses=2 count=2`；
- 包序号立即拒绝/重载：`TB_PASS`；
- ERROR、上位机停止确认和全局复位握手：`TB_PASS`；
- RX FIFO overflow 窄脉冲 CDC：只生成一次目的域事件，错误码 `0x66660073`；
- WAW 导出：`count=132 hart0=4 hart1=128`；
- WebUI 协议、错误立即停止、日志清理/保存、时间戳和黄金比较单元测试通过。

## 8. 综合、实现和位流结果

| 项目 | 结果 |
| --- | --- |
| 目标器件 | `xcvu19p_CIV-fsva3824-1-e` |
| 未解析系统黑盒 | `0` |
| 布线 | 471183/471183 条可路由网络完成，unrouted/error=0 |
| Setup | WNS `+0.082 ns`, TNS `0`, 失败端点 0 |
| Hold | WHS `+0.010 ns`, THS `0`, 失败端点 0 |
| Pulse width | WPWS `+0.046 ns`, TPWS `0`, 失败端点 0 |
| Bus skew | 113 项全部满足，最小 slack `+2.508 ns` |
| DRC | 0 Error, 0 Critical Warning, 102 Warning, 6 Advisory |
| Bitstream | 199112135 byte，未压缩 |
| Bitstream SHA-256 | `1A201E64A760228E298B285A723EBD2D911B7F275CF80E9733EE6826BBF2D2FC` |
| Routed DCP SHA-256 | `2A8C84692268E6967B26175D4C9AC1A2FDE960F43A16F15726224D8BF7049DAA` |

`report_power` 的 vector-less 估算是 9.960 W，confidence=Low；没有 SAIF/VCD 实际活动率，不应将该数字作为热设计的精确上限。

## 9. 新位流的板级复测顺序

1. 下载 `output/board/eh2_veri_system.bit`，核对 SHA-256。
2. 启动 WebUI 监听后再复位 FPGA，确认收到新的 `PREINIT_DONE`。
3. 连续运行至少 20 轮 782 帧线速程序会话，不在轮次间手动硬复位；每轮 END 后由 FPGA 自动全局复位。
4. 每轮核对 FCS 计数、sequence/count/DMA 结果、四帧 hash 和 WAW 列表。
5. hart0/package0 必须每轮严格为 `[18,20,26,28]`，hart1/package0 必须为 128 项；任一轮多项都应保留 PCAP/JSONL 并转入 ILA 定位，不应通过放宽上位机黄金值规避。

## 10. 结论

程序丢包/超时的主要结构性问题已分成两层处理：分类器改为单遍流式消除吞吐瓶颈，PHY/IDELAY 重新标定加确定性 RX 放行消除启动相位依赖；FCS 错误现在可观测且会立即终止上位机发送。正常 END 和 ERROR 恢复均使用全局复位，不再复用可能被污染的会话状态。

WAW 异常已从 hash 算法错误中排除，范围收窄到 WAW sideband/CDC/store 通路及复位边界。新位流已全量复位该路径并在前仿中输出正确 4/128 项；是否完全消除板级多项，仍以第9节的新位流连续板测为最终判定。
