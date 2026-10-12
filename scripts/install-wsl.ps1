# Run this script as Administrator. It never restarts Windows automatically.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$logFile = Join-Path $projectRoot '.tools\wsl-admin-install.log'
New-Item -ItemType Directory -Path (Split-Path $logFile) -Force | Out-Null
Start-Transcript -Path $logFile -Force
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open PowerShell as Administrator and run this script again.'
    }
    & winget install --id Microsoft.WSL --exact --source winget --silent --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "WSL package installation failed ($LASTEXITCODE)." }
    & wsl --install --no-distribution --web-download
    if ($LASTEXITCODE -ne 0) { throw "WSL feature setup failed ($LASTEXITCODE)." }
    Write-Output 'WSL setup finished. Restart Windows if the installer requests it.'
} finally {
    Stop-Transcript
}
