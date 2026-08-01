# Shared project sources

该目录保存多个 Vivado 工程共享的正式源码，不是临时目录：

- `eh2_design/`：VeeR-EH2 RTL；
- `eth/`：TEMAC、RX FIFO、DMA/DDR 顶层、PHY 初始化和 testbench；
- `constraints/`：DDR4、RGMII、板卡时钟与引脚约束。

`mac_fifo_dma_proj`、`eh2_veri_iss_proj` 等工程通过相对路径引用这里的文件。克隆仓库时必须保留 `source` 与各工程目录的同级关系。

