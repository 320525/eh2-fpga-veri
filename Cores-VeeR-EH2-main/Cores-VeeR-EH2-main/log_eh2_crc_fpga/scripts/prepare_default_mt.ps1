param(
    [string]$ProjectRoot = "D:\eh2_fpga\Cores-VeeR-EH2-main\Cores-VeeR-EH2-main"
)

$ErrorActionPreference = "Stop"

$perl = "C:\Program Files\Git\usr\bin\perl.exe"
$config = Join-Path $ProjectRoot "configs\veer.config"
$output = Join-Path $ProjectRoot "log_eh2_crc_fpga\config\default_mt"
$backup = Join-Path $ProjectRoot "log_eh2_crc_fpga\config\original_single_hart"

New-Item -ItemType Directory -Force -Path $output | Out-Null
New-Item -ItemType Directory -Force -Path $backup | Out-Null

Copy-Item -LiteralPath (Join-Path $ProjectRoot "design\eh2_param.vh") -Destination (Join-Path $backup "eh2_param.vh") -Force
Copy-Item -LiteralPath (Join-Path $ProjectRoot "design\eh2_pdef.vh") -Destination (Join-Path $backup "eh2_pdef.vh") -Force

$env:RV_ROOT = $ProjectRoot.Replace('\', '/')
$env:BUILD_PATH = $output.Replace('\', '/')
$env:PWD = $ProjectRoot.Replace('\', '/')

& $perl $config -target=default_mt
if ($LASTEXITCODE -ne 0) {
    throw "veer.config failed with exit code $LASTEXITCODE"
}

$generatedParam = Join-Path $output "eh2_param.vh"
$generatedPdef = Join-Path $output "eh2_pdef.vh"
if (!(Test-Path -LiteralPath $generatedParam) -or !(Test-Path -LiteralPath $generatedPdef)) {
    throw "default_mt parameter files were not generated"
}

Copy-Item -LiteralPath $generatedParam -Destination (Join-Path $ProjectRoot "design\eh2_param.vh") -Force
Copy-Item -LiteralPath $generatedPdef -Destination (Join-Path $ProjectRoot "design\eh2_pdef.vh") -Force

$numThreads = Select-String -LiteralPath (Join-Path $ProjectRoot "design\eh2_param.vh") -Pattern "NUM_THREADS\s+:\s+6'h02"
if (!$numThreads) {
    throw "Generated configuration is not NUM_THREADS=2"
}

Write-Output "default_mt configuration installed"
Write-Output "generated=$output"
Write-Output "backup=$backup"
