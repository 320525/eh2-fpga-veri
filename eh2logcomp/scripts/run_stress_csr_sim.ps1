$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$referenceRoot = 'D:\eh2_fpga\Cores-VeeR-EH2-main\Cores-VeeR-EH2-main'
$referenceLog = Join-Path $referenceRoot 'log_eh2_crc_fpga'
$vivadoBin = 'D:\vivado23\Vivado\2023.2\bin'
$work = Join-Path $root 'build\sim_stress_csr'
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

$crcSources = @(
  (Join-Path $referenceLog 'rtl\crc64_ecma_pair_160.sv'),
  (Join-Path $referenceLog 'rtl\crc_pair_fifo_async_4w1r.sv'),
  (Join-Path $referenceLog 'rtl\crc_mix_accumulator.sv'),
  (Join-Path $referenceLog 'rtl\instr_crc_hash_dual.sv'),
  (Join-Path $referenceLog 'rtl\instr_crc_system_dual.sv'),
  (Join-Path $referenceLog 'rtl\eh2_unified_axi_bram.sv'),
  (Join-Path $referenceLog 'rtl\eh2_crc_soc.sv'),
  (Join-Path $root 'tb\tb_eh2_stress_200k_csr.sv')
)

$packageSource = Join-Path $referenceRoot 'design\include\eh2_def.sv'
$glblSource = 'D:\vivado23\Vivado\2023.2\data\verilog\src\glbl.v'
& (Join-Path $vivadoBin 'xvlog.bat') --sv `
  -i (Join-Path $referenceLog 'config\default_mt') `
  -i (Join-Path $referenceRoot 'design') `
  $packageSource @designSources @crcSources $glblSource
if ($LASTEXITCODE -ne 0) {
  throw "xvlog failed with exit code $LASTEXITCODE"
}

& (Join-Path $vivadoBin 'xelab.bat') `
  -L xpm -L unisims_ver -timescale 1ns/1ps `
  --mt 8 `
  tb_eh2_stress_200k_csr glbl `
  -snapshot tb_eh2_stress_200k_csr_sim
if ($LASTEXITCODE -ne 0) {
  throw "xelab failed with exit code $LASTEXITCODE"
}

& (Join-Path $vivadoBin 'xsim.bat') tb_eh2_stress_200k_csr_sim `
  -runall -log (Join-Path $artifactDir 'stress_200k_csr_xsim.log')
if ($LASTEXITCODE -ne 0) {
  throw "xsim failed with exit code $LASTEXITCODE"
}

$pythonPath = Join-Path $referenceLog 'scripts'
$oldPythonPath = $env:PYTHONPATH
try {
  $env:PYTHONPATH = $pythonPath
  python (Join-Path $referenceLog 'scripts\verify_struct_results.py') `
    (Join-Path $artifactDir 'stress_200k_csr_actual_structs.txt') `
    (Join-Path $artifactDir 'stress_200k_csr_results.txt') `
    --json (Join-Path $artifactDir 'stress_200k_csr_verified.json')
  if ($LASTEXITCODE -ne 0) {
    throw "independent CRC verification failed with exit code $LASTEXITCODE"
  }
}
finally {
  $env:PYTHONPATH = $oldPythonPath
}
