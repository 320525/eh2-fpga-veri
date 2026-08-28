param(
  [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\init')
)

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null

$addresses = 0..255 | ForEach-Object { '{0:X8}' -f ($_ * 4) }
$data      = 0..255 | ForEach-Object { 'FFFFFFFF' }
$mask      = 0..255 | ForEach-Object { 'FFFFFFFF' }
$control   = 0..255 | ForEach-Object { '00010000' }

function Write-Coe {
  param([string]$Name, [string[]]$Values)
  $lines = @('memory_initialization_radix=16;', 'memory_initialization_vector=')
  for ($index = 0; $index -lt $Values.Count; $index += 8) {
    $last = [Math]::Min($index + 7, $Values.Count - 1)
    $chunk = $Values[$index..$last] -join ','
    if ($last -eq $Values.Count - 1) {
      $lines += "$chunk;"
    } else {
      $lines += "$chunk,"
    }
  }
  [System.IO.File]::WriteAllLines((Join-Path $resolvedOutput $Name), $lines)
}

Write-Coe 'data_test_atg_addr.coe' $addresses
Write-Coe 'data_test_atg_data.coe' $data
Write-Coe 'data_test_atg_mask.coe' $mask
Write-Coe 'data_test_atg_ctrl.coe' $control

