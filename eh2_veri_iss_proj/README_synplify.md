# EH2 的 Synplify 网表综合与 Vivado 全流程

本流程把 VeeR-EH2 的 `eh2_veer_wrapper` 作为独立模块交给 Synplify Pro
综合，生成 EDIF 网表；Vivado 工程中的 DDR4 MIG、AXI 转换器、ATG、初始化
控制器和顶层连接仍保留为原工程实现。Vivado 综合时只使用 EH2 的 Synplify
网表，EH2 RTL 仅保留给行为仿真。

## 器件一致性

- Vivado 完整器件：`xcvu19p_CIV-fsva3824-1-e`
- Synplify 对应选择：Technology=`Virtex-UltraScalePlus-FPGAs`、
  Part=`XCVU19P`、Package=`FSVA3824`、Speed grade=`-1-e`

`_CIV` 是该工程使用的 Vivado 器件变体后缀，Synplify Q-2020.03 的器件库
没有这个后缀字段。芯片、封装、速度级与温度级均完全对应。运行脚本会同时
检查 Vivado 工程 part 和 Synplify 器件库，任一不一致就停止。

## 一键运行

在工程根目录的 PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synplify_netlist_flow.ps1
```

执行顺序为：

1. Synplify 综合 `eh2_veer_wrapper` 并生成 EDIF；
2. 把 EDIF 接入 `eh2_dual_ddr_top`，关闭 EH2 RTL 的 Vivado 综合用途；
3. 系统级行为仿真；
4. Vivado 顶层综合；
5. 使用已回接 EH2 网表的顶层综合后功能仿真；
6. 布局布线、时序/利用率/DRC/CDC 等报告；
7. 比特流生成和实现后 bus-skew 检查。

## 主要输出

- Synplify EH2 网表：`build/synplify/rev_1/eh2_veer_wrapper.edf`
- Synplify 日志：`reports/synplify_eh2.log`
- 行为仿真日志：`reports/system_pre_sim.log`
- 综合后仿真日志：`reports/system_post_synth_sim.log`
- 综合报告：`reports/post_synth_*.rpt`
- 实现与时序报告：`reports/*_impl.rpt`
- 最终比特流：`build/vivado/eh2_dual_ddr.runs/impl_1/eh2_dual_ddr_top.bit`

也可以分步运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_synplify.ps1
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source .\scripts\integrate_synplify_netlist.tcl -notrace
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source .\scripts\run_pre_sim.tcl -notrace
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source .\scripts\run_synthesis.tcl -notrace
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source .\scripts\run_post_synth_sim.tcl -notrace
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source .\scripts\run_implementation.tcl -notrace
D:\vivado23\Vivado\2023.2\bin\vivado.bat -mode batch -source .\scripts\check_post_impl_bus_skew.tcl -notrace
```

Synplify 需要可用的 `synplifypro` FlexNet 许可证。若许可证由服务器提供，请在
运行前按许可证管理员给出的值设置 `LM_LICENSE_FILE` 或
`SNPSLMD_LICENSE_FILE`。本机脚本默认使用
`C:\Synopsys\fpga_Q-2020.03\license.txt`，也可通过 `-LicenseFile` 指定；
许可证路径只传给当前 Synplify 子进程，不会写入系统环境。
