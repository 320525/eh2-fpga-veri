param(
  [string]$VivadoHome = "D:\vivado23\Vivado\2023.2",
  [string]$SynplifyHome = "C:\Synopsys\fpga_Q-2020.03",
  [string]$LicenseFile = "C:\Synopsys\fpga_Q-2020.03\license.txt",
  [switch]$SkipSynplify,
  [switch]$SkipBehavioralSimulation,
  [switch]$SkipPostSynthesisSimulation
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent $PSScriptRoot
$vivado = Join-Path $VivadoHome "bin\vivado.bat"
if (-not (Test-Path -LiteralPath $vivado)) {
  throw "Vivado executable not found: $vivado"
}

function Invoke-VivadoStage {
  param([string]$ScriptName)
  $scriptPath = Join-Path $PSScriptRoot $ScriptName
  Write-Host "RUNNING_VIVADO_STAGE=$ScriptName"
  & $vivado -mode batch -source $scriptPath -notrace
  if ($LASTEXITCODE -ne 0) {
    throw "Vivado stage failed: $ScriptName (exit code $LASTEXITCODE)"
  }
}

Push-Location $rootDir
try {
  if (-not (Test-Path -LiteralPath (Join-Path $rootDir "build\vivado\eh2_dual_ddr.xpr"))) {
    Invoke-VivadoStage "create_project.tcl"
  }

  $synplifyNetlist = Join-Path $rootDir "build\synplify\rev_1\eh2_veer_wrapper.edf"
  if ($SkipSynplify) {
    if (-not (Test-Path -LiteralPath $synplifyNetlist)) {
      throw "-SkipSynplify was specified, but the GUI-generated netlist was not found: $synplifyNetlist"
    }
    Write-Host "SKIPPING_SYNPLIFY_USING_EXISTING_NETLIST=$synplifyNetlist"
  } else {
    & (Join-Path $PSScriptRoot "run_synplify.ps1") -SynplifyHome $SynplifyHome -LicenseFile $LicenseFile
    if ($LASTEXITCODE -ne 0) {
      throw "Synplify stage failed with exit code $LASTEXITCODE"
    }
  }

  Invoke-VivadoStage "integrate_synplify_netlist.tcl"
  if (-not $SkipBehavioralSimulation) {
    Invoke-VivadoStage "run_pre_sim.tcl"
  }
  Invoke-VivadoStage "run_synthesis.tcl"
  if (-not $SkipPostSynthesisSimulation) {
    Invoke-VivadoStage "run_post_synth_sim.tcl"
  }
  Invoke-VivadoStage "run_implementation.tcl"
  Invoke-VivadoStage "check_post_impl_bus_skew.tcl"
} finally {
  Pop-Location
}

Write-Host "SYNPLIFY_NETLIST_FLOW_COMPLETE"
Write-Host "BITSTREAM=$(Join-Path $rootDir 'build\vivado\eh2_dual_ddr.runs\impl_1\eh2_dual_ddr_top.bit')"
