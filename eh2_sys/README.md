# EH2 wrapper 综合参考工程

`eh2_sys.xpr` 是面向 `xcvu19p_CIV-fsva3824-2-e` 的早期 VeeR-EH2 wrapper 综合工程，顶层为 `eh2_veer_wrapper`。工程引用仓库内 VeeR-EH2 RTL，用于综合、接口检查和生成 EH2 中间网表。

该工程没有板级管脚/时钟约束，也没有可直接上板的顶层，因此不会单独生成可用板级比特流。需要完整板级实现时使用：

- `eh2_veri_iss_proj`：双 DDR4 EH2 验证系统；
- `eh2fpga_veri_system`：以太网加载、双 DDR4 与日志归约完整系统。

使用 Vivado 2023.2 打开 `eh2_sys.xpr` 可重新综合；工具生成的 runs、cache 和日志不纳入版本库。

