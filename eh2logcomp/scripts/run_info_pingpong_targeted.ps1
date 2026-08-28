$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vb = 'D:\vivado23\Vivado\2023.2\bin'
$work = Join-Path $root 'build\sim_info_pingpong_targeted'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

$sources = @(
  (Join-Path $root 'rtl\common\sync_bits.sv'),
  (Join-Path $root 'rtl\common\event_toggle_cdc.sv'),
  (Join-Path $root 'rtl\common\axi4_if.sv'),
  (Join-Path $root 'rtl\info\info_record_elastic_4w4r.sv'),
  (Join-Path $root 'rtl\info\info_fifo_async_4w2r.sv'),
  (Join-Path $root 'rtl\info\info_fifo_pingpong_4w2r.sv'),
  (Join-Path $root 'rtl\info\info_fifo_read_elastic.sv'),
  (Join-Path $root 'rtl\ddr\info_ddr_pingpong_write_dma.sv'),
  (Join-Path $root 'tb\tb_info_fifo_pingpong_dma.sv'),
  'D:\vivado23\Vivado\2023.2\data\verilog\src\glbl.v'
)

Remove-Item -Recurse -Force xsim.dir -ErrorAction SilentlyContinue
& "$vb\xvlog.bat" --sv @sources
if ($LASTEXITCODE) { throw 'xvlog targeted pingpong' }
& "$vb\xelab.bat" tb_info_fifo_pingpong_dma_100k_cdc glbl --mt 8 `
  -L xpm -L unisims_ver -s tb_info_fifo_pingpong_dma_100k_cdc_sim
if ($LASTEXITCODE) { throw 'xelab targeted pingpong' }
$log = 'tb_info_fifo_pingpong_dma_100k_cdc_xsim.log'
& "$vb\xsim.bat" tb_info_fifo_pingpong_dma_100k_cdc_sim -runall -log $log
if ($LASTEXITCODE) { throw 'xsim targeted pingpong' }
if (Select-String -Path $log -Pattern 'Fatal:|FATAL_ERROR' -Quiet) {
  throw 'targeted pingpong reported a SystemVerilog fatal assertion'
}
