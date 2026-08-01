$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent $PSScriptRoot
$eh2Root = "D:\eh2_fpga\source\eh2_design"
$compatRoot = Join-Path $rootDir "build\synplify\compat"

$files = @(
  "ifu\eh2_ifu_ic_mem.sv",
  "ifu\eh2_ifu_mem_ctl.sv",
  "lsu\eh2_lsu_bus_intf.sv",
  "lsu\eh2_lsu_bus_buffer.sv"
)

$commonDefines = [System.IO.File]::ReadAllText((Join-Path $eh2Root "common_defines.vh"))
$expectedDefines = @{
  "RV_ICACHE_BANK_BITS" = 1
  "RV_ICACHE_BEAT_BITS" = 3
  "RV_IFU_BUS_TAG" = 4
  "RV_LSU_BUS_TAG" = 4
}
foreach ($entry in $expectedDefines.GetEnumerator()) {
  if ($commonDefines -notmatch ("(?m)^``define\s+" + $entry.Key + "\s+" + $entry.Value + "\s*$")) {
    throw "Unexpected or missing $($entry.Key) in common_defines.vh"
  }
}

$casts = @{
  "(pt.ICACHE_BANK_BITS)'" = "1'"
  "(pt.ICACHE_BEAT_BITS)'" = "3'"
  "(pt.IFU_BUS_TAG)'" = "4'"
  "(pt.LSU_BUS_TAG)'" = "4'"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($relativePath in $files) {
  $source = Join-Path $eh2Root $relativePath
  $destination = Join-Path $compatRoot $relativePath
  if (-not (Test-Path -LiteralPath $source)) {
    throw "EH2 source not found: $source"
  }

  $text = [System.IO.File]::ReadAllText($source)
  foreach ($entry in $casts.GetEnumerator()) {
    $text = $text.Replace($entry.Key, $entry.Value)
  }
  if ($text -match "\(pt\.[A-Za-z0-9_]+\)'\(") {
    throw "Unsupported parameter-selected sized cast remains in $relativePath"
  }

  $destinationDir = Split-Path -Parent $destination
  New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
  [System.IO.File]::WriteAllText($destination, $text, $utf8NoBom)
  Write-Host "SYNPLIFY_COMPAT_SOURCE=$destination"
}
