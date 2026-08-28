$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$programDir = Join-Path $root 'programs\stress_200k_dualhart_system'
$outputDir = Join-Path $programDir 'build'
$toolchain = 'D:\vivado23\Vivado\2023.2\gnu\riscv\nt\riscv64-unknown-elf\bin'

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$elf = Join-Path $outputDir 'stress_200k_dualhart_system.elf'
$spikeElf = Join-Path $outputDir 'stress_200k_dualhart_spike.elf'
$binary = Join-Path $outputDir 'stress_200k_dualhart_system.bin'
$disassembly = Join-Path $outputDir 'stress_200k_dualhart_system.dis'
$map = Join-Path $outputDir 'stress_200k_dualhart_system.map'

& (Join-Path $toolchain 'riscv64-unknown-elf-gcc.exe') `
  -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles `
  '-Wl,--build-id=none' "-Wl,-Map,$map" `
  "-T$(Join-Path $programDir 'link.ld')" `
  -o $elf (Join-Path $programDir 'stress_200k_dualhart_system.S')
if ($LASTEXITCODE -ne 0) {
  throw "RISC-V link failed with exit code $LASTEXITCODE"
}

& (Join-Path $toolchain 'riscv64-unknown-elf-gcc.exe') `
  -march=rv32imac_zicsr -mabi=ilp32 -nostdlib -nostartfiles `
  -DSPIKE_COMPAT `
  '-Wl,--build-id=none' `
  "-T$(Join-Path $programDir 'link.ld')" `
  -o $spikeElf (Join-Path $programDir 'stress_200k_dualhart_system.S')
if ($LASTEXITCODE -ne 0) {
  throw "RISC-V Spike-compatible link failed with exit code $LASTEXITCODE"
}

& (Join-Path $toolchain 'riscv64-unknown-elf-objcopy.exe') `
  -O binary $elf $binary
if ($LASTEXITCODE -ne 0) {
  throw "RISC-V objcopy failed with exit code $LASTEXITCODE"
}

& (Join-Path $toolchain 'riscv64-unknown-elf-objdump.exe') `
  -d -M no-aliases,numeric $elf |
  Set-Content -Path $disassembly -Encoding ascii
if ($LASTEXITCODE -ne 0) {
  throw "RISC-V objdump failed with exit code $LASTEXITCODE"
}

python (Join-Path $root 'scripts\make_program_images.py') `
  $binary $outputDir --base 0x80000000 --memory-bytes 0x100000
if ($LASTEXITCODE -ne 0) {
  throw "Program image generation failed with exit code $LASTEXITCODE"
}

& (Join-Path $toolchain 'riscv64-unknown-elf-readelf.exe') -h -S $elf
& (Join-Path $toolchain 'riscv64-unknown-elf-size.exe') $elf
& (Join-Path $toolchain 'riscv64-unknown-elf-objdump.exe') `
  -d -M no-aliases,numeric $spikeElf |
  Select-String -Pattern '8000000c'
