$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$referenceRoot = 'D:\eh2_fpga\Cores-VeeR-EH2-main\Cores-VeeR-EH2-main'
$referenceLog = Join-Path $referenceRoot 'log_eh2_crc_fpga'
$vivadoBin = 'D:\vivado23\Vivado\2023.2\bin'
$work = Join-Path $root 'build\sim_waw_export_early'
$artifactDir = Join-Path $root 'artifacts\sim'

New-Item -ItemType Directory -Path $work -Force | Out-Null
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
Set-Location $work

$designSources = Get-Content (Join-Path $referenceLog 'sim\eh2_rtl_flist.f') |
  Where-Object { $_.Trim() -ne '' } |
  ForEach-Object {
    [System.IO.Path]::GetFullPath(
      (Join-Path (Join-Path $referenceLog 'sim') $_.Trim())
    )
  }

$sources = @(
  (Join-Path $root 'rtl\crc\crc64_ecma_pair_160.sv'),
  (Join-Path $root 'rtl\crc\crc_pair_fifo_async_4w1r.sv'),
  (Join-Path $root 'rtl\crc\crc_mix_accumulator.sv'),
  (Join-Path $root 'rtl\crc\instr_crc_hash_dual.sv'),
  (Join-Path $root 'rtl\crc\instr_crc_system_dual.sv'),
  (Join-Path $referenceLog 'rtl\eh2_unified_axi_bram.sv'),
  (Join-Path $referenceLog 'rtl\eh2_crc_soc.sv'),
  (Join-Path $root 'tb\tb_waw_export_early.sv')
)

$packageSource = Join-Path $referenceRoot 'design\include\eh2_def.sv'
$glblSource = 'D:\vivado23\Vivado\2023.2\data\verilog\src\glbl.v'
& (Join-Path $vivadoBin 'xvlog.bat') --sv `
  -i (Join-Path $referenceLog 'config\default_mt') `
  -i (Join-Path $referenceRoot 'design') `
  $packageSource @designSources @sources $glblSource
if ($LASTEXITCODE -ne 0) { throw "xvlog failed: $LASTEXITCODE" }

& (Join-Path $vivadoBin 'xelab.bat') `
  -L xpm -L unisims_ver -timescale 1ns/1ps --mt 8 `
  tb_waw_export_early glbl -snapshot tb_waw_export_early_sim
if ($LASTEXITCODE -ne 0) { throw "xelab failed: $LASTEXITCODE" }

& (Join-Path $vivadoBin 'xsim.bat') tb_waw_export_early_sim `
  -runall -log (Join-Path $artifactDir 'waw_export_early_xsim.log')
if ($LASTEXITCODE -ne 0) { throw "xsim failed: $LASTEXITCODE" }
