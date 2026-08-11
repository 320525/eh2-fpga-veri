# EH2 FPGA 整机验证系统

本目录集成 EH2 双 hart、双 DDR、RGMII/TEMAC 程序加载、CRC/hash 归约、WAW 序号记录、系统状态控制和板级 WebUI。

权威文档统一位于 `output/doc`：

- [系统功能与协议说明](output/doc/README.md)
- [全部前仿验证说明](output/doc/veri_readme.md)
- [板级时钟、引脚、状态与运行说明](output/doc/system_board_readme.md)
- [WebUI 使用说明](output/doc/webui_readme.md)
- [综合、实现与历史问题记录](output/doc/build_issue_readme.md)
- [板级丢包、超时与 WAW 异常归因](output/doc/latest_board_error_root_cause_and_fix_readme.md)
- [EH2 新增内部逻辑与信号说明](output/doc/eh2signal_readme.md)

最终板级位流为 `output/board/eh2_veri_system.bit`，由 Git LFS 管理。可再生成的 DCP、Vivado 报告、IP 缓存和临时实现目录不纳入 Git。
