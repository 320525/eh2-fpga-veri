$ErrorActionPreference = 'Stop'

$webuiRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$venvPath = Join-Path $webuiRoot '.venv'
$pythonPath = Join-Path $venvPath 'Scripts\python.exe'

if (-not (Test-Path -LiteralPath $pythonPath)) {
    python -m venv $venvPath
}

& $pythonPath -m pip install --upgrade pip
& $pythonPath -m pip install -r (Join-Path $webuiRoot 'requirements.txt')
& $pythonPath -c "from scapy.all import conf; print('Scapy:', conf.version, 'pcap provider:', conf.use_pcap)"

Write-Host ''
Write-Host 'WebUI Python dependencies installed.'
Write-Host 'Npcap is a Windows driver and must be installed separately.'
