param([switch]$SkipCompile)

$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$referenceRoot = 'D:\eh2_fpga\Cores-VeeR-EH2-main\Cores-VeeR-EH2-main'
$referenceLog = Join-Path $referenceRoot 'log_eh2_crc_fpga'
$vivadoBin = 'D:\vivado23\Vivado\2023.2\bin'
$gnuBin = 'D:\vivado23\Vivado\2023.2\gnu\riscv\nt\riscv64-unknown-elf\bin'
$work = Join-Path $root 'build\sim_struct_buffer_prestest'
$caseRoot = Join-Path $root 'verification_log\struct_buffer_prestest'

New-Item -ItemType Directory -Path $work -Force | Out-Null
Set-Location $work

$designSources = Get-Content (Join-Path $referenceLog 'sim\eh2_rtl_flist.f') |
  Where-Object { $_.Trim() -ne '' } |
  ForEach-Object {
    [System.IO.Path]::GetFullPath(
      (Join-Path (Join-Path $referenceLog 'sim') $_.Trim())
    )
  }

$crcSources = @(
  (Join-Path $root 'rtl\crc\crc64_ecma_pair_160.sv'),
  (Join-Path $root 'rtl\crc\crc_pair_fifo_async_4w1r.sv'),
  (Join-Path $root 'rtl\crc\crc_mix_accumulator.sv'),
  (Join-Path $root 'rtl\crc\instr_crc_hash_dual.sv'),
  (Join-Path $root 'rtl\crc\instr_crc_system_dual.sv'),
  (Join-Path $referenceLog 'rtl\eh2_unified_axi_bram.sv'),
  (Join-Path $referenceLog 'rtl\eh2_crc_soc.sv'),
  (Join-Path $root 'tb\tb_struct_buffer_prestest_vivado.sv')
)

$packageSource = Join-Path $referenceRoot 'design\include\eh2_def.sv'
$glblSource = 'D:\vivado23\Vivado\2023.2\data\verilog\src\glbl.v'

# Compile/elaborate the current Vivado-project EH2 RTL and the modified CRC
# subsystem once.  Every case then starts a fresh XSim process and reloads the
# corresponding program.mem64 at time zero.
if (!$SkipCompile) {
  & (Join-Path $vivadoBin 'xvlog.bat') --sv `
    -i (Join-Path $referenceLog 'config\default_mt') `
    -i (Join-Path $referenceRoot 'design') `
    $packageSource @designSources @crcSources $glblSource
  if ($LASTEXITCODE -ne 0) {
    throw "xvlog failed with exit code $LASTEXITCODE"
  }

  & (Join-Path $vivadoBin 'xelab.bat') `
    -L xpm -L unisims_ver -timescale 1ns/1ps --mt 8 `
    tb_struct_buffer_prestest_vivado glbl `
    -snapshot tb_struct_buffer_prestest_vivado_sim
  if ($LASTEXITCODE -ne 0) {
    throw "xelab failed with exit code $LASTEXITCODE"
  }
} elseif (!(Test-Path (Join-Path $work `
             'xsim.dir\tb_struct_buffer_prestest_vivado_sim\xsimk.exe'))) {
  throw 'SkipCompile requested but the XSim snapshot does not exist'
}

$objcopy = Join-Path $gnuBin 'riscv64-unknown-elf-objcopy.exe'
foreach ($caseNumber in 0..9) {
  $caseId = '{0:D2}' -f $caseNumber
  $caseDir = Join-Path $caseRoot ("case_" + $caseId)
  $elf = Join-Path $caseDir 'program.elf'
  $binary = Join-Path $caseDir 'program.bin'
  $imageDir = Join-Path $caseDir 'vivado_image'
  if (!(Test-Path $elf)) {
    throw "missing compiled ELF for case_$caseId"
  }
  & $objcopy -O binary $elf $binary
  if ($LASTEXITCODE -ne 0) {
    throw "objcopy failed for case_$caseId"
  }
  python (Join-Path $root 'scripts\make_program_images.py') `
    $binary $imageDir --memory-bytes 131072
  if ($LASTEXITCODE -ne 0) {
    throw "memory image generation failed for case_$caseId"
  }
  Copy-Item -Force `
    (Join-Path $imageDir 'stress_200k_dualhart_system.mem64') `
    (Join-Path $work 'program.mem64')

  $xsimLog = Join-Path $caseDir 'vivado_xsim.log'
  & (Join-Path $vivadoBin 'xsim.bat') `
    tb_struct_buffer_prestest_vivado_sim -runall `
    -testplusarg ("CASE" + $caseId) -log $xsimLog
  if ($LASTEXITCODE -ne 0) {
    throw "XSim failed for case_$caseId with exit code $LASTEXITCODE"
  }
  if (!(Select-String -Quiet -Path $xsimLog `
        -Pattern 'STRUCT_BUFFER_PRETEST_VIVADO_PASS')) {
    throw "XSim did not report PASS for case_$caseId"
  }
  $summary = Select-String -Path (Join-Path $caseDir 'vivado_interface.log') `
    -Pattern '^SUMMARY ' | Select-Object -Last 1
  Write-Output ("case_" + $caseId + " " + $summary.Line)
}

Write-Output 'STRUCT_BUFFER_PRETEST_VIVADO_ALL_PASS cases=10'
