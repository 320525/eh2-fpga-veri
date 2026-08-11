$ErrorActionPreference = 'Stop'

$webuiRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonPath = Join-Path $webuiRoot '.venv\Scripts\python.exe'

if (-not (Test-Path -LiteralPath $pythonPath)) {
    throw 'WebUI environment is missing. Run .\install.ps1 first.'
}

Push-Location $webuiRoot
try {
    & $pythonPath (Join-Path $webuiRoot 'app.py')
}
finally {
    Pop-Location
}
