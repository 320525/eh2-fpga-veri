# EH2 FPGA verification projects

本仓库汇总 VeriTiger V19P/VU19P 平台上的 VeeR-EH2、双 DDR4、以太网收发、DMA 与日志归约工程。仓库保留可重新生成工程所需的 RTL、约束、IP 配置/输出产品、初始化数据、构建脚本、必要 EDIF 网表，以及已经完成实现的最终比特流。

## 环境

- Vivado 2023.2。
- 目标器件主要为 `xcvu19p_CIV-fsva3824-1-e`；两个早期参考/综合工程仍保留其原始 `-2-e` 器件配置。
- 重新生成 EH2 EDIF 时需要 Synplify Pro Q-2020.03 和有效许可证；已提交的 EDIF 可直接供 Vivado 使用。
- 仓库使用 Git LFS 保存 `*.edf` 和 `*.bit`。克隆后先执行 `git lfs pull`。
- 部分历史 Synplify 工程仍记录 `D:/eh2_fpga` 绝对路径。最稳妥的复现方式是克隆到 `D:\eh2_fpga`；各 Vivado 建工程脚本本身以工程根目录推导路径。

## 工程索引

| 目录 | 用途 | 主要入口 | 已交付比特流 |
|---|---|---|---|
| `eh2fpga_veri_system` | 双 hart EH2、双 DDR4、以太网程序加载和日志归约完整系统 | `scripts/create_project.tcl` | 当前目录尚未生成最终板级 bit；按 README 运行综合和板级实现 |
| `eh2_veri_iss_proj` | EH2 双 DDR4、初始化回读和八灯验证 | `scripts/create_project.tcl` | `output/bitstreams/` 下 3 个版本 |
| `eth_tx` | TEMAC/DP83867 发送链路和 TX FIFO | `scripts/run_build.tcl` | `output/eth_tx_board_top.bit` |
| `mac_fifo_dma_proj` | TEMAC RX FIFO、DataMover、DDR4 和首帧 LED 检查 | `full_build_board_top.tcl` | `board_build/mac_fifo_dma_ddr4_board_top.bit` |
| `Cores-VeeR-EH2-main/Cores-VeeR-EH2-main` | VeeR-EH2 RTL、仿真及双 hart 指令 CRC/归约 FPGA 集成 | `README.md`、`log_eh2_crc_fpga/README.md` | `log_eh2_crc_fpga/vivado_build/output/eh2_crc_fpga_top.bit` |
| `eh2_sys` | 早期 EH2 wrapper 综合工程，不含板级约束 | `eh2_sys.xpr` | 无板级 bit |
| `tri_mode_ethernet_mac_0_ex` | Xilinx TEMAC 示例/参考工程 | `tri_mode_ethernet_mac_0_ex.xpr` | 无针对当前板卡的 bit |
| `source` | 多工程共享的 EH2、Ethernet RTL、约束和初始化文件 | 各上层工程引用 | 不单独生成 bit |
| `ddr2test` | 预留目录，目前没有可构建源码 | `README.md` | 无 |

## 克隆与恢复大文件

```powershell
git clone https://github.com/320525/eh2-fpga-veri.git D:\eh2_fpga
Set-Location D:\eh2_fpga
git lfs pull
```

不要把 `.Xil`、`*.runs`、`*.sim`、缓存、波形、日志或中间 DCP 当作源码。这些内容在重新综合、仿真或实现时由工具生成。

## 已提交比特流校验

| 文件 | SHA-256 |
|---|---|
| `Cores-VeeR-EH2-main/Cores-VeeR-EH2-main/log_eh2_crc_fpga/vivado_build/output/eh2_crc_fpga_top.bit` | `C5848CD59B44873E7B85AC823B08AE210DA6503F96F72AA8507026CA7FE7B2AA` |
| `eh2_veri_iss_proj/output/bitstreams/eh2_dual_ddr_gclkt0_50mhz_led4.bit` | `543CE239A3E64738DCAB88C8F34C6169BA256FE054820C3C93F48A069AD2BB8F` |
| `eh2_veri_iss_proj/output/bitstreams/eh2_dual_ddr_gclkt0_50mhz_led8_verified.bit` | `621B4136F51ABA837993441A166DD40BEEA303251E3A7F44A0E16BB634457B95` |
| `eh2_veri_iss_proj/output/bitstreams/eh2_dual_ddr_gclkt2_50mhz_led4.bit` | `F90B10B9B8DF8B2DF77C81BA6CD88F984EE9DBA749EEF9CB3DA965C98E3750CF` |
| `eth_tx/output/eth_tx_board_top.bit` | `CB222974A61A5AF3585A452A2272B328CFB7FD9194D1BB309958A5D01078E252` |
| `mac_fifo_dma_proj/board_build/mac_fifo_dma_ddr4_board_top.bit` | `B6E08875289E4855A7C0867197ED3D6BEC945DE092028B3AF148C27F3FD40DC4` |

各工程的详细连接、时钟、复位、验证结果和具体构建命令见相应目录 README。

