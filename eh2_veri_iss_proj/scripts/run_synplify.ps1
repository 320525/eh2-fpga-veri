param(
  [string]$SynplifyHome = "C:\Synopsys\fpga_Q-2020.03",
  [string]$LicenseFile = "C:\Synopsys\fpga_Q-2020.03\license.txt"
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent $PSScriptRoot
$projectFile = Join-Path $rootDir "synplify\eh2_veer_wrapper.prj"
$resultDir = Join-Path $rootDir "build\synplify\rev_1"
$resultFile = Join-Path $resultDir "eh2_veer_wrapper.edf"
$logFile = Join-Path $rootDir "reports\synplify_eh2.log"
$vivadoProject = Join-Path $rootDir "build\vivado\eh2_dual_ddr.xpr"
$partsDb = Join-Path $SynplifyHome "lib\parts\xilinx_parts.txt"
$synbatch = Join-Path $SynplifyHome "bin64\mbin\synbatch.exe"

$expectedVivadoPart = "xcvu19p_CIV-fsva3824-1-e"
if (-not (Test-Path -LiteralPath $vivadoProject)) {
  throw "Vivado project not found: $vivadoProject"
}
$xprText = Get-Content -LiteralPath $vivadoProject -Raw
if ($xprText -notmatch [regex]::Escape("<Option Name=`"Part`" Val=`"$expectedVivadoPart`"/>")) {
  throw "Vivado part must be exactly $expectedVivadoPart before Synplify is run."
}

if (-not (Test-Path -LiteralPath $synbatch)) {
  throw "Synplify batch executable not found: $synbatch"
}
if (-not (Test-Path -LiteralPath $LicenseFile)) {
  throw "Synplify license file not found: $LicenseFile"
}
if (-not (Test-Path -LiteralPath $partsDb)) {
  throw "Synplify parts database not found: $partsDb"
}
$partsText = Get-Content -LiteralPath $partsDb -Raw
if ($partsText -notmatch 'part\s+XCVU19P\s*\{' -or
    $partsText -notmatch 'package\s+FSVA3824\s*;' -or
    $partsText -notmatch 'grade\s+-1-e\s*;') {
  throw "Installed Synplify does not support XCVU19P/FSVA3824/-1-e."
}

New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logFile) | Out-Null
& (Join-Path $PSScriptRoot "prepare_synplify_sources.ps1")

Push-Location $rootDir
try {
  # Apply the user-provided FlexNet file to this process and its Synplify
  # child only; do not modify persistent user or machine environment values.
  $env:LM_LICENSE_FILE = $LicenseFile
  $env:SNPSLMD_LICENSE_FILE = $LicenseFile
  & $synbatch -batch -run rev_1 -log $logFile $projectFile
  if ($LASTEXITCODE -ne 0) {
    throw "Synplify failed with exit code $LASTEXITCODE. See $logFile"
  }
} finally {
  Pop-Location
}

if (-not (Test-Path -LiteralPath $resultFile)) {
  throw "Synplify reported success but did not create $resultFile"
}

$size = (Get-Item -LiteralPath $resultFile).Length
if ($size -lt 1024) {
  throw "Generated EDIF is unexpectedly small ($size bytes): $resultFile"
}

Write-Host "SYNPLIFY_COMPLETE"
Write-Host "VIVADO_PART=$expectedVivadoPart"
Write-Host "SYNPLIFY_PART=XCVU19P/FSVA3824/-1-e"
Write-Host "NETLIST=$resultFile"
