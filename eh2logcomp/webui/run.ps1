$ErrorActionPreference = 'Stop'

$webuiRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonPath = Join-Path $webuiRoot '.venv\Scripts\python.exe'
$appPath = Join-Path $webuiRoot 'app.py'

if (-not (Test-Path -LiteralPath $pythonPath)) {
    throw 'WebUI environment is missing. Run .\install.ps1 first.'
}

function Stop-PreviousWebUiProcess {
    $configPath = Join-Path $webuiRoot 'config.json'
    $configuredPort = 3205
    if (Test-Path -LiteralPath $configPath) {
        $configuredPort = [int]((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).http_port)
    }
    if ($env:EH2_WEB_PORT -match '^\d+$') {
        $configuredPort = [int]$env:EH2_WEB_PORT
    }
    $listenerPids = @()
    try {
        $listenerPids += Get-NetTCPConnection -LocalPort $configuredPort -State Listen -ErrorAction Stop |
            Select-Object -ExpandProperty OwningProcess
    }
    catch {
        # Some Windows policies deny Get-NetTCPConnection to normal users.
        # netstat still lets us locate the owner of this one configured port.
        foreach ($line in (netstat.exe -ano -p TCP)) {
            if ($line -match '^\s*TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and
                    [int]$matches[1] -eq $configuredPort) {
                $listenerPids += [int]$matches[2]
            }
        }
    }

    $eh2ApiDetected = $false
    try {
        $status = Invoke-RestMethod -Uri "http://127.0.0.1:$configuredPort/api/status" -TimeoutSec 2
        $propertyNames = @($status.PSObject.Properties.Name)
        $eh2ApiDetected = (
            $propertyNames -contains 'board_state' -and
            $propertyNames -contains 'capture_running' -and
            $propertyNames -contains 'diagnostics'
        )
    }
    catch {
        # A stopped or still-starting old instance may not answer the API.
    }

    foreach ($candidatePid in ($listenerPids | Sort-Object -Unique)) {
        $knownInstance = $eh2ApiDetected
        if (-not $knownInstance) {
            try {
                $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$candidatePid" -ErrorAction Stop).CommandLine
                $knownInstance = $commandLine -and $commandLine.Contains($appPath)
            }
            catch {
                # Command-line inspection may be blocked by local policy.
            }
        }
        if (-not $knownInstance) {
            throw "Port $configuredPort is occupied by PID $candidatePid, but it is not an EH2 WebUI process."
        }

        try {
            $process = Get-Process -Id $candidatePid -ErrorAction Stop
            Write-Host "Stopping previous EH2 WebUI process PID $candidatePid..."
            Stop-Process -Id $candidatePid -Force -ErrorAction Stop
            $null = $process.WaitForExit(5000)
        }
        catch {
            if (Get-Process -Id $candidatePid -ErrorAction SilentlyContinue) {
                throw
            }
        }
    }
}

Stop-PreviousWebUiProcess

function Clear-LocalPythonBytecode {
    $resolvedRoot = (Resolve-Path -LiteralPath $webuiRoot).Path.TrimEnd('\\')
    $resolvedRootPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    $cacheDirectories = @()
    $rootCache = Join-Path $resolvedRoot '__pycache__'
    if (Test-Path -LiteralPath $rootCache) {
        $cacheDirectories += Get-Item -LiteralPath $rootCache
    }
    foreach ($sourceName in @('eh2web', 'vm_tools', 'tests')) {
        $sourceRoot = Join-Path $resolvedRoot $sourceName
        if (Test-Path -LiteralPath $sourceRoot) {
            $cacheDirectories += Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Force |
                Where-Object { $_.Name -eq '__pycache__' }
        }
    }
    foreach ($cacheDirectory in $cacheDirectories) {
        $resolvedCache = (Resolve-Path -LiteralPath $cacheDirectory.FullName).Path
        if (-not $resolvedCache.StartsWith(
                $resolvedRootPrefix,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove Python cache outside WebUI root: $resolvedCache"
        }
        Remove-Item -LiteralPath $resolvedCache -Recurse -Force
    }
}

Clear-LocalPythonBytecode
$env:PYTHONDONTWRITEBYTECODE = '1'
Write-Host "Launching latest EH2 WebUI source from $appPath"

try {
    Push-Location $webuiRoot
    & $pythonPath -B $appPath
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
