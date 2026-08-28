# EH2LOGCOMP 双 Hart 指令信息采集系统

本工程是独立于原系统的新工程。EH2 的取指与访存统一使用 DDR0；每个 hart 提交的逐指令 Info Struct 经各自的异步 FIFO 和写 DMA 保存到 DDR1，程序执行结束后再由 DDR1 读 DMA、双整帧缓冲和同一个 TEMAC/RGMII 接口回传。旧 CRC/hash 归约模块只保留为未编译参考，不参与当前硬件。

最终交付：

- [系统功能、数据流与协议](output/doc/README.md)
- [全部前仿与软件验证记录](output/doc/veri_readme.md)
- [板级时钟、引脚、时序与运行说明](output/doc/system_board_readme.md)
- [问题归因、修复和易忽略事项](output/doc/build_issue_readme.md)
- [最终 10k、DMA、WAW 与 RGMII 时序问题专项记录](output/doc/latest_error_and_fix_readme.md)
- [WebUI 使用说明](output/doc/webui_readme.md)
- [WebUI 完整协议与操作说明](output/doc/webui_full_readme.md)
- [WebUI 一键自动化、riscv-dv 与 Spike 说明](output/doc/webui_automation_readme.md)
- [最终 BIT](output/board/eh2logcomp_2slot.bit)
- [最终 timing-fixed DCP](output/board/eh2logcomp_2slot_postroute_timing_fixed.dcp)
- [原始完整 routed DCP](output/board/eh2logcomp_2slot_routed.dcp)
- [20 万条测试程序 BIN](output/board/stress_200k_dualhart_system.bin)
- [最终 10k 顶层验证程序、帧镜像和 ELF](output/board/riscvdv_10k_top)
- [硬件产物 SHA-256 清单](output/board/SHA256SUMS.txt)
- [Vivado 最终报告](output/board/reports_final)

最终实现结果（Vivado 2023.2）：WNS `+0.007 ns`，TNS `0`，WHS `+0.010 ns`，THS `0`；RGMII 输入建立/保持为 `+0.254/+0.306 ns`；全部可路由网络完成路由；总线偏斜违规 0；Bitgen 成功，0 Error、0 Critical Warning。最终 RGMII RX 时钟根为 `X2Y2`，五个候选的合法 implemented-design 扫描和失败方案均记录在问题说明中。

上板前请先阅读 `system_board_readme.md`。当前正建立时序，但 setup/hold 裕量都很窄；修改 RTL、约束、Vivado 版本、布局布线 seed/directive 或板级 PHY 延迟后必须重新完整综合、实现和时序签核。
