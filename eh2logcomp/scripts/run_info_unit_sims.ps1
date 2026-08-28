$ErrorActionPreference='Stop'
$root=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vb='D:\vivado23\Vivado\2023.2\bin'
$work=Join-Path $root 'build\sim_info_unit'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
function Run-One([string]$top,[string[]]$sources) {
  Remove-Item -Recurse -Force xsim.dir -ErrorAction SilentlyContinue
  & "$vb\xvlog.bat" --sv @sources
  if($LASTEXITCODE){throw "xvlog $top"}
  & "$vb\xelab.bat" $top --mt 8 -s "${top}_sim"
  if($LASTEXITCODE){throw "xelab $top"}
  $log = "${top}_xsim.log"
  & "$vb\xsim.bat" "${top}_sim" -runall -log $log
  if($LASTEXITCODE){throw "xsim $top"}
  if (Select-String -Path $log -Pattern 'Fatal:|FATAL_ERROR' -Quiet) {
    throw "xsim $top reported a SystemVerilog fatal assertion"
  }
}
function Run-OneXpm([string]$top,[string[]]$sources) {
  Remove-Item -Recurse -Force xsim.dir -ErrorAction SilentlyContinue
  & "$vb\xvlog.bat" --sv @sources 'D:\vivado23\Vivado\2023.2\data\verilog\src\glbl.v'
  if($LASTEXITCODE){throw "xvlog $top"}
  & "$vb\xelab.bat" $top glbl --mt 8 -L xpm -L unisims_ver -s "${top}_sim"
  if($LASTEXITCODE){throw "xelab $top"}
  $log = "${top}_xsim.log"
  & "$vb\xsim.bat" "${top}_sim" -runall -log $log
  if($LASTEXITCODE){throw "xsim $top"}
  if (Select-String -Path $log -Pattern 'Fatal:|FATAL_ERROR' -Quiet) {
    throw "xsim $top reported a SystemVerilog fatal assertion"
  }
}
Run-One tb_info_log_packetizer @(
  (Join-Path $root 'rtl\eth\info_log_tx_packetizer.sv'),
  (Join-Path $root 'tb\tb_info_log_packetizer.sv'))
$captureSources=@(
  (Join-Path $root 'rtl\info\info_struct_pkg.sv'),
  (Join-Path $root 'rtl\info\instr_info_capture_dual.sv'),
  (Join-Path $root 'rtl\info\instr_info_capture_hart_bank.sv'),
  (Join-Path $root 'rtl\info\instr_info_capture_dual_hier.sv'))
Run-One tb_instr_info_capture @(
  $captureSources + (Join-Path $root 'tb\tb_instr_info_capture.sv'))
Run-One tb_instr_info_capture_handoff @(
  $captureSources + (Join-Path $root 'tb\tb_instr_info_capture_handoff.sv'))
Run-One tb_instr_info_capture_differential @(
  $captureSources + (Join-Path $root 'tb\tb_instr_info_capture_differential.sv'))
Run-One tb_info_fifo_read_elastic @(
  (Join-Path $root 'rtl\info\info_fifo_read_elastic.sv'),
  (Join-Path $root 'tb\tb_info_fifo_read_elastic.sv'))
Run-One tb_info_elastic_dma_integration @(
  (Join-Path $root 'rtl\common\axi4_if.sv'),
  (Join-Path $root 'rtl\info\info_fifo_read_elastic.sv'),
  (Join-Path $root 'rtl\ddr\info_ddr_write_dma.sv'),
  (Join-Path $root 'tb\tb_info_elastic_dma_integration.sv'))
Run-One tb_info_ddr_read_dma_fixed30 @(
  (Join-Path $root 'rtl\common\axi4_if.sv'),
  (Join-Path $root 'rtl\ddr\info_ddr_read_dma.sv'),
  (Join-Path $root 'tb\axi512_memory_model.sv'),
  (Join-Path $root 'tb\tb_info_ddr_read_dma_fixed30.sv'))
Run-One tb_info_tx_frame_fifo_2slot @(
  (Join-Path $root 'rtl\common\sync_bits.sv'),
  (Join-Path $root 'rtl\eth\info_tx_frame_fifo_2slot.sv'),
  (Join-Path $root 'tb\tb_info_tx_frame_fifo_2slot.sv'))
Run-One tb_info_log_dump_subsystem_multiframe @(
  (Join-Path $root 'rtl\common\axi4_if.sv'),
  (Join-Path $root 'rtl\common\sync_bits.sv'),
  (Join-Path $root 'rtl\common\event_toggle_cdc.sv'),
  (Join-Path $root 'rtl\ddr\info_ddr_read_dma.sv'),
  (Join-Path $root 'rtl\info\info_dma_data_elastic.sv'),
  (Join-Path $root 'rtl\eth\info_tx_frame_fifo_2slot.sv'),
  (Join-Path $root 'rtl\eth\info_log_done_formatter.sv'),
  (Join-Path $root 'rtl\eth\info_log_dump_subsystem.sv'),
  (Join-Path $root 'tb\axi512_memory_model.sv'),
  (Join-Path $root 'tb\tb_info_log_dump_subsystem_multiframe.sv'))
Run-OneXpm tb_info_fifo_async_tail @(
  (Join-Path $root 'rtl\common\sync_bits.sv'),
  (Join-Path $root 'rtl\info\info_fifo_async_4w2r.sv'),
  (Join-Path $root 'tb\tb_info_fifo_async_tail.sv'))
Run-OneXpm tb_info_fifo_bank_release_race @(
  (Join-Path $root 'rtl\common\sync_bits.sv'),
  (Join-Path $root 'rtl\common\event_toggle_cdc.sv'),
  (Join-Path $root 'rtl\info\info_fifo_async_4w2r.sv'),
  (Join-Path $root 'rtl\info\info_fifo_pingpong_4w2r.sv'),
  (Join-Path $root 'tb\tb_info_fifo_bank_release_race.sv'))

# Four 512-record banks per hart: (1) full-rate production with no artificial
# stall, (2) all banks full while DDR is blocked then recovery, and (3)
# periodic AW/W/B channel backpressure.  Each run checks exact 256-bit record
# order, AXI 4 KiB/max-burst legality, tail padding and per-hart accounting.
$pingpongSources=@(
  (Join-Path $root 'rtl\common\sync_bits.sv'),
  (Join-Path $root 'rtl\common\event_toggle_cdc.sv'),
  (Join-Path $root 'rtl\common\axi4_if.sv'),
  (Join-Path $root 'rtl\info\info_record_elastic_4w4r.sv'),
  (Join-Path $root 'rtl\info\info_fifo_async_4w2r.sv'),
  (Join-Path $root 'rtl\info\info_fifo_pingpong_4w2r.sv'),
  (Join-Path $root 'rtl\info\info_fifo_read_elastic.sv'),
  (Join-Path $root 'rtl\ddr\info_ddr_pingpong_write_dma.sv'),
  (Join-Path $root 'tb\tb_info_fifo_pingpong_dma.sv'))
# Long processor-free acceptance run first: 100,000 records at the complete
# 2..4-record/cycle EH2 logging envelope, real asynchronous bank handoff and
# whole-bank DDR DMA, followed by a direct modeled-DDR image comparison.
Run-OneXpm tb_info_fifo_pingpong_dma_100k_cdc $pingpongSources
Run-OneXpm tb_info_fifo_pingpong_dma_nominal $pingpongSources
Run-OneXpm tb_info_fifo_pingpong_dma $pingpongSources
Run-OneXpm tb_info_fifo_pingpong_dma_variable_axi $pingpongSources
Run-OneXpm tb_info_fifo_pingpong_dma_tiny_tail $pingpongSources
Run-OneXpm tb_info_fifo_pingpong_dma_bank_boundary $pingpongSources
Run-OneXpm tb_info_fifo_pingpong_dma_exact_capacity $pingpongSources
Run-OneXpm tb_info_fifo_pingpong_dma_single_hart $pingpongSources
