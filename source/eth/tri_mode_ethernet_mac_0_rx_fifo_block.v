`timescale 1ps / 1ps

// Receive-side wrapper based on tri_mode_ethernet_mac_0_ex's FIFO block.
// The MAC-side interface remains 8 bits wide.  The existing project FIFO
// performs the clock-domain crossing and presents 16-bit words to the user.
(* DowngradeIPIdentifiedWarnings = "yes" *)
module tri_mode_ethernet_mac_0_rx_fifo_block (

  //==========================================================================
  // 1. MAC全局时钟与复位
  //==========================================================================

  input  wire        gtx_clk,       // 千兆以太网发送参考时钟，通常为125 MHz
  input  wire        glbl_rstn,     // MAC全局复位，低有效
  input  wire        rx_axi_rstn,   // MAC接收AXI-Stream接口复位，低有效
  input  wire        tx_axi_rstn,   // MAC发送AXI-Stream接口复位，低有效
  input  wire        refclk,        // IDELAY等逻辑使用的参考时钟


  //==========================================================================
  // 2. MAC接收侧状态信号
  //==========================================================================

  output wire        rx_mac_aclk,          // MAC接收AXI-Stream时钟
  output wire        rx_reset,             // MAC产生的接收侧复位，高有效
  output wire [27:0] rx_statistics_vector, // MAC接收统计信息
  output wire        rx_statistics_valid,  // 接收统计信息有效指示


  //==========================================================================
  // 3. 接收FIFO用户侧AXI-Stream接口
  //
  // MAC侧以8位数据写入FIFO，用户侧以16位数据从FIFO读出。
  // rx_fifo_clock和rx_mac_aclk可以属于不同时钟域。
  //==========================================================================

  input  wire        rx_fifo_clock,        // FIFO用户读出侧时钟
  input  wire        rx_fifo_resetn,       // FIFO用户读出侧复位，低有效

  output wire [15:0] rx_axis_fifo_tdata,   // FIFO输出的16位接收数据
  output wire        rx_axis_fifo_tvalid,  // FIFO输出数据有效
  input  wire        rx_axis_fifo_tready,  // 下游模块准备好接收数据
  output wire        rx_axis_fifo_tlast,   // 当前16位数据为以太网帧最后一个数据

  output wire [3:0]  rx_fifo_status,        // 接收FIFO占用状态
  output wire        rx_fifo_overflow,      // 接收FIFO溢出指示


  //==========================================================================
  // 4. MAC发送侧状态及控制信号
  //
  // 当前模块未实现发送FIFO，因此MAC发送AXI-Stream数据端口固定为0。
  //==========================================================================

  output wire        tx_mac_aclk,          // MAC发送AXI-Stream时钟
  output wire        tx_reset,             // MAC产生的发送侧复位，高有效
  input  wire [7:0]  tx_ifg_delay,          // 发送帧间隔附加延迟
  output wire [31:0] tx_statistics_vector, // MAC发送统计信息
  output wire        tx_statistics_valid,  // 发送统计信息有效指示


  //==========================================================================
  // 5. IEEE 802.3流量控制接口
  //==========================================================================

  input  wire        pause_req,      // 请求MAC发送Pause控制帧
  input  wire [15:0] pause_val,      // Pause帧中的暂停时间值


  //==========================================================================
  // 6. 外部RGMII物理接口
  //==========================================================================

  output wire [3:0]  rgmii_txd,      // RGMII发送数据
  output wire        rgmii_tx_ctl,   // RGMII发送控制信号
  output wire        rgmii_txc,      // RGMII发送时钟

  input  wire [3:0]  rgmii_rxd,      // RGMII接收数据
  input  wire        rgmii_rx_ctl,   // RGMII接收控制信号
  input  wire        rgmii_rxc,      // RGMII接收时钟


  //==========================================================================
  // 7. RGMII带内状态信号
  //==========================================================================

  output wire        inband_link_status,    // PHY链路状态
  output wire [1:0]  inband_clock_speed,    // PHY协商得到的链路速率
  output wire        inband_duplex_status,  // PHY双工模式


  //==========================================================================
  // 8. PHY管理接口
  //==========================================================================

  inout  wire        mdio,           // MDIO双向管理数据
  output wire        mdc,            // MDIO管理时钟


  //==========================================================================
  // 9. MAC配置AXI4-Lite从接口
  //
  // 用于软件访问MAC内部寄存器，配置MAC工作模式、地址和中断等。
  //==========================================================================

  input  wire        s_axi_aclk,     // AXI4-Lite接口时钟
  input  wire        s_axi_resetn,   // AXI4-Lite接口复位，低有效

  // AXI4-Lite写地址通道
  input  wire [11:0] s_axi_awaddr,
  input  wire        s_axi_awvalid,
  output wire        s_axi_awready,

  // AXI4-Lite写数据通道
  input  wire [31:0] s_axi_wdata,
  input  wire        s_axi_wvalid,
  output wire        s_axi_wready,

  // AXI4-Lite写响应通道
  output wire [1:0]  s_axi_bresp,
  output wire        s_axi_bvalid,
  input  wire        s_axi_bready,

  // AXI4-Lite读地址通道
  input  wire [11:0] s_axi_araddr,
  input  wire        s_axi_arvalid,
  output wire        s_axi_arready,

  // AXI4-Lite读数据通道
  output wire [31:0] s_axi_rdata,
  output wire [1:0]  s_axi_rresp,
  output wire        s_axi_rvalid,
  input  wire        s_axi_rready,

  // MAC中断
  output wire        mac_irq
);

  wire       rx_mac_aclk_int;
  wire       tx_mac_aclk_int;
  wire       rx_reset_int;
  wire       tx_reset_int;
  wire       rx_mac_reset;
  wire       rx_mac_resetn;

  wire [7:0] rx_axis_mac_tdata;
  wire       rx_axis_mac_tvalid;
  wire       rx_axis_mac_tlast;
  wire       rx_axis_mac_tuser;

  wire       tx_axis_mac_tready_unused;

  assign rx_mac_aclk = rx_mac_aclk_int;
  assign tx_mac_aclk = tx_mac_aclk_int;
  assign rx_reset    = rx_reset_int;
  assign tx_reset    = tx_reset_int;

  tri_mode_ethernet_mac_0 tri_mode_ethernet_mac_i (
    .gtx_clk              (gtx_clk),
    .refclk               (refclk),
    .glbl_rstn            (glbl_rstn),
    .rx_axi_rstn          (rx_axi_rstn),
    .tx_axi_rstn          (tx_axi_rstn),

    .rx_statistics_vector (rx_statistics_vector),
    .rx_statistics_valid  (rx_statistics_valid),
    .rx_mac_aclk          (rx_mac_aclk_int),
    .rx_reset             (rx_reset_int),
    .rx_axis_mac_tdata    (rx_axis_mac_tdata),
    .rx_axis_mac_tvalid   (rx_axis_mac_tvalid),
    .rx_axis_mac_tlast    (rx_axis_mac_tlast),
    .rx_axis_mac_tuser    (rx_axis_mac_tuser),

    .tx_ifg_delay         (tx_ifg_delay),
    .tx_statistics_vector (tx_statistics_vector),
    .tx_statistics_valid  (tx_statistics_valid),
    .tx_mac_aclk          (tx_mac_aclk_int),
    .tx_reset             (tx_reset_int),
    .tx_axis_mac_tdata    (8'b0),
    .tx_axis_mac_tvalid   (1'b0),
    .tx_axis_mac_tlast    (1'b0),
    .tx_axis_mac_tuser    (1'b0),
    .tx_axis_mac_tready   (tx_axis_mac_tready_unused),

    .pause_req            (pause_req),
    .pause_val            (pause_val),
    .speedis100           (),
    .speedis10100         (),

    .rgmii_txd            (rgmii_txd),
    .rgmii_tx_ctl         (rgmii_tx_ctl),
    .rgmii_txc            (rgmii_txc),
    .rgmii_rxd            (rgmii_rxd),
    .rgmii_rx_ctl         (rgmii_rx_ctl),
    .rgmii_rxc            (rgmii_rxc),
    .inband_link_status   (inband_link_status),
    .inband_clock_speed   (inband_clock_speed),
    .inband_duplex_status (inband_duplex_status),

    .mdio                 (mdio),
    .mdc                  (mdc),

    .s_axi_aclk           (s_axi_aclk),
    .s_axi_resetn         (s_axi_resetn),
    .s_axi_awaddr         (s_axi_awaddr),
    .s_axi_awvalid        (s_axi_awvalid),
    .s_axi_awready        (s_axi_awready),
    .s_axi_wdata          (s_axi_wdata),
    .s_axi_wvalid         (s_axi_wvalid),
    .s_axi_wready         (s_axi_wready),
    .s_axi_bresp          (s_axi_bresp),
    .s_axi_bvalid         (s_axi_bvalid),
    .s_axi_bready         (s_axi_bready),
    .s_axi_araddr         (s_axi_araddr),
    .s_axi_arvalid        (s_axi_arvalid),
    .s_axi_arready        (s_axi_arready),
    .s_axi_rdata          (s_axi_rdata),
    .s_axi_rresp          (s_axi_rresp),
    .s_axi_rvalid         (s_axi_rvalid),
    .s_axi_rready         (s_axi_rready),
    .mac_irq              (mac_irq)
  );

  // Same reset path used by tri_mode_ethernet_mac_0_ex: synchronize the
  // MAC-generated reset locally, then invert it for the FIFO resetn input.
  tri_mode_ethernet_mac_0_reset_sync rx_mac_reset_gen (
    .clk       (rx_mac_aclk_int),
    .enable    (1'b1),
    .reset_in  (rx_reset_int),
    .reset_out (rx_mac_reset)
  );

  assign rx_mac_resetn = ~rx_mac_reset;

  tri_mode_ethernet_mac_0_rx_client_fifo_8to16 rx_client_fifo_i (
    .rx_fifo_aclk        (rx_fifo_clock),
    .rx_fifo_resetn      (rx_fifo_resetn),
    .rx_axis_fifo_tdata  (rx_axis_fifo_tdata),
    .rx_axis_fifo_tvalid (rx_axis_fifo_tvalid),
    .rx_axis_fifo_tlast  (rx_axis_fifo_tlast),
    .rx_axis_fifo_tready (rx_axis_fifo_tready),

    .rx_mac_aclk         (rx_mac_aclk_int),
    .rx_mac_resetn       (rx_mac_resetn),
    .rx_axis_mac_tdata   (rx_axis_mac_tdata),
    .rx_axis_mac_tvalid  (rx_axis_mac_tvalid),
    .rx_axis_mac_tlast   (rx_axis_mac_tlast),
    .rx_axis_mac_tuser   (rx_axis_mac_tuser),

    .fifo_status         (rx_fifo_status),
    .fifo_overflow       (rx_fifo_overflow)
  );

endmodule
