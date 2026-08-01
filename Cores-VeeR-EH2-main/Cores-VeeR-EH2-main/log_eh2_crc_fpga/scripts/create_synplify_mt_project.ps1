param(
    [string]$ProjectRoot = "D:\eh2_fpga\Cores-VeeR-EH2-main\Cores-VeeR-EH2-main"
)

$ErrorActionPreference = "Stop"

$sourceProject = Join-Path $ProjectRoot "fpga_eh2_synplify\eh2_veer_wrapper.prj"
$sourceConstraint = Join-Path $ProjectRoot "fpga_eh2_synplify\eh2_veer_wrapper.sdc"
$targetDirectory = Join-Path $ProjectRoot "log_eh2_crc_fpga\synplify_mt"
$targetProject = Join-Path $targetDirectory "eh2_veer_wrapper_mt.prj"
$targetConstraint = Join-Path $targetDirectory "eh2_veer_wrapper.sdc"

New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

$projectText = Get-Content -LiteralPath $sourceProject -Raw
$projectText = $projectText.Replace(
    "# VeeR-EH2 out-of-context synthesis with commit/WAW monitor outputs only.",
    "# VeeR-EH2 default_mt dual-hart out-of-context synthesis with commit/WAW monitor outputs only."
)
$projectText = $projectText.Replace("rev_1", "rev_mt")
[System.IO.File]::WriteAllText($targetProject, $projectText, [System.Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $sourceConstraint -Destination $targetConstraint -Force

Write-Output $targetProject
