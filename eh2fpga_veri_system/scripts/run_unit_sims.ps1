$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vivadoBin = 'D:\vivado23\Vivado\2023.2\bin'
$work = Join-Path $root 'build\sim_unit'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Location $work

function Invoke-Step {
  param([string]$Program, [string[]]$Arguments)
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Program failed with exit code $LASTEXITCODE"
  }
}

function Run-Xsim {
  param(
    [string]$Top,
    [string[]]$Sources
  )
  $absoluteSources = $Sources | ForEach-Object {
    [System.IO.Path]::GetFullPath((Join-Path $root $_))
  }
  Invoke-Step "$vivadoBin\xvlog.bat" (@('--sv') + $absoluteSources)
  Invoke-Step "$vivadoBin\xelab.bat" @(
    $Top, '--mt', '8', '-s', "${Top}_sim"
  )
  Invoke-Step "$vivadoBin\xsim.bat" @("${Top}_sim", '-runall')
}

Run-Xsim 'tb_system_controller' @(
  'rtl\common\eh2_system_pkg.sv',
  'rtl\common\sync_fifo.sv',
  'rtl\eth\system_info_tx_fifo.sv',
  'rtl\eth\system_info_tx_formatter.sv',
  'rtl\control\eh2_system_controller.sv',
  'tb\tb_system_controller.sv'
)
Run-Xsim 'tb_preconfig_frame_count_error' @(
  'rtl\common\eh2_system_pkg.sv',
  'rtl\control\eh2_system_controller.sv',
  'tb\tb_preconfig_frame_count_error.sv'
)
Run-Xsim 'tb_preconfig_zero_frame_error' @(
  'rtl\common\eh2_system_pkg.sv',
  'rtl\control\eh2_system_controller.sv',
  'tb\tb_preconfig_frame_count_error.sv'
)
Run-Xsim 'tb_eth_rx_separation' @(
  'rtl\common\sync_fifo.sv',
  'rtl\eth\eth_rx_frame_classifier.sv',
  'rtl\eth\system_info_rx_fifo.sv',
  'rtl\eth\system_info_rx_decoder.sv',
  'tb\tb_eth_rx_separation.sv'
)
Run-Xsim 'tb_program_rx_dma_sequence' @(
  'rtl\eth\program_rx_dma_ctrl.v',
  'tb\tb_program_rx_dma_sequence.sv'
)
Run-Xsim 'tb_ddr_masters' @(
  'rtl\common\axi4_if.sv',
  'rtl\common\axi_owner_mux2.sv',
  'rtl\ddr\ddr_fill_master.sv',
  'rtl\ddr\ddr_read_compare_master.sv',
  'tb\tb_ddr_masters.sv'
)
Run-Xsim 'tb_log_frame_packetizer' @(
  'rtl\log\waw_sequence_store.sv',
  'rtl\log\log_frame_packetizer.sv',
  'tb\tb_log_frame_packetizer.sv'
)
Run-Xsim 'tb_rx_fifo_overflow_cdc' @(
  'rtl\common\eh2_system_pkg.sv',
  'rtl\common\event_toggle_cdc.sv',
  'rtl\control\system_error_monitor.sv',
  'rtl\control\eh2_system_controller.sv',
  'tb\tb_rx_fifo_overflow_cdc.sv'
)
Run-Xsim 'tb_error_global_reset_flow' @(
  'rtl\common\eh2_system_pkg.sv',
  'rtl\common\system_global_reset_supervisor.sv',
  'rtl\control\system_error_monitor.sv',
  'rtl\control\eh2_system_controller.sv',
  'tb\tb_error_global_reset_flow.sv'
)
Run-Xsim 'tb_mac_rx_statistics_cdc' @(
  'rtl\common\event_toggle_cdc.sv',
  'rtl\common\sync_bits.sv',
  'rtl\eth\mac_rx_statistics_cdc.sv',
  'tb\tb_mac_rx_statistics_cdc.sv'
)
