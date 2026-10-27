$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw 'Install Python 3.9 or later first.' }
python -c "import tidevice" 2>$null
if ($LASTEXITCODE -ne 0) {
    python -m pip install -r requirements.txt
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
}
Write-Host 'TrafficMonitor: keep this window open. Press Ctrl+C to stop.'
python -u trafficmonitor.py | ForEach-Object {
    try { $result = $_ | ConvertFrom-Json; if ($result.url) { Start-Process $result.url } } catch { Write-Host $_ }
}
if ($LASTEXITCODE -ne 0) { throw 'TrafficMonitor stopped. Check whether port 27681 is already in use.' }
