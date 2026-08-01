# MAC RX FIFO、DMA 与 DDR4 工程

本工程面向 `xcvu19p_CIV-fsva3824-1-e`，把 Tri-Mode Ethernet MAC、16 位接收 FIFO、帧控制器、AXI DataMover、AXI Clock Converter、32→512 位 AXI Data Width Converter 和 DDR4 MIG 连接为接收写存储通路。

## 主要功能

- DP83867 PHY 通过 MDIO 自动初始化。
- TEMAC 上电后由 AXI Traffic Generator 自动写寄存器配置。
- MAC 接收帧写入 RX FIFO；帧控制器丢弃前 7 个 16 位字。
- 每帧搬运 1024 字节，DDR 起始地址从 `0x0000_0000` 开始并按 `0x400` 连续递增。
- DataMover 工作在 125 MHz；DDR4 MIG 用户侧工作在约 266.5 MHz，通过 AXI 跨时钟和位宽转换连接。
- `dma_ddr_led_checker.v` 对第一帧 DMA 数据及 DDR 地址 0 的回读结果驱动 LED-T1～T4。

## 工程结构

- Vivado 工程：`mac_fifo_dma_proj.xpr`
- 板级顶层：`../source/eth/mac_fifo_dma_ddr4_board_top.v`
- 共享 RTL：`../source/eth/`
- 约束：`../source/constraints/ddr4_sodimm1.xdc`、`../source/constraints/rgmii_phy_timing.xdc`
- IP：`mac_fifo_dma_proj.srcs/sources_1/ip/`
- 可复现构建脚本：`full_build_board_top.tcl`
- 构建必需的 debug-hub 分区：`board_build/reference_dbg_hub.dcp`

## 生成比特流

使用 Vivado 2023.2，在本目录执行：

```powershell
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source .\full_build_board_top.tcl
```

脚本会重新综合、实现，检查黑盒、WNS/WHS、DRC 和 AXI bus skew，全部通过后才写出：

```text
board_build/mac_fifo_dma_ddr4_board_top.bit
```

当前交付文件 SHA-256：

```text
B6E08875289E4855A7C0867197ED3D6BEC945DE092028B3AF148C27F3FD40DC4
```

Vivado 生成的 `.Xil`、runs、cache、日志、报告和阶段 DCP 未纳入版本库，可由上述流程重新生成。

