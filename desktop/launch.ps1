$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw '请先安装 Python 3.9 或更新版本' }
python -c "import tidevice" 2>$null
if ($LASTEXITCODE -ne 0) { python -m pip install -r requirements.txt }
python trafficmonitor.py | ForEach-Object {
    try { $result = $_ | ConvertFrom-Json; if ($result.url) { Start-Process $result.url } } catch { Write-Host $_ }
}
