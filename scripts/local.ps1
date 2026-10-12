param(
    [ValidateSet('Start', 'Setup', 'Build', 'Deploy', 'Frontend', 'Stop', 'Status')]
    [string]$Action = 'Start'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$toolsDir = Join-Path $projectRoot '.tools'

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE." }
}

function Invoke-ProjectYarn {
    param([string[]]$Arguments)
    Invoke-Checked 'node' -Arguments (@((Join-Path $projectRoot '.yarn\releases\yarn-3.3.1.cjs')) + $Arguments)
}

function Initialize-Tools {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        $portableNode = Get-ChildItem -LiteralPath $toolsDir -Directory -Filter 'node-*-win-x64' |
            Where-Object { Test-Path (Join-Path $_.FullName 'node.exe') } |
            Select-Object -First 1
        if (-not $portableNode) {
            Write-Output 'Downloading official portable Node.js 22 into .tools...'
            $checksums = (Invoke-WebRequest -UseBasicParsing 'https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt').Content
            $archiveEntry = ($checksums -split "`n") | Where-Object { $_ -match '  node-v[\d.]+-win-x64\.zip\s*$' } | Select-Object -First 1
            if (-not $archiveEntry) { throw 'Cannot find the Windows Node.js archive.' }
            $expectedHash, $archiveName = $archiveEntry.Trim() -split '\s+', 2
            $archivePath = Join-Path $toolsDir $archiveName
            Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/latest-v22.x/$archiveName" -OutFile $archivePath
            if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $expectedHash) {
                throw 'Node.js checksum mismatch.'
            }
            Expand-Archive -LiteralPath $archivePath -DestinationPath $toolsDir -Force
            $portableNode = Get-Item (Join-Path $toolsDir ($archiveName -replace '\.zip$', ''))
        }
        $env:Path = "$($portableNode.FullName);$env:Path"
    }

    $env:Path = "$projectRoot\node_modules\.bin;$toolsDir\cli\node_modules\.bin;$env:Path"
    foreach ($dockerBin in @("$env:ProgramFiles\Docker\Docker\resources\bin", "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin")) {
        if (Test-Path -LiteralPath $dockerBin) { $env:Path = "$dockerBin;$env:Path" }
    }
    $env:npm_config_cache = Join-Path $toolsDir 'npm-cache'
    if (-not (Get-Command lstk -ErrorAction SilentlyContinue)) {
        Invoke-Checked 'npm.cmd' -Arguments @('install', '--prefix', (Join-Path $toolsDir 'cli'), '@localstack/lstk@1.4.0', '--no-audit', '--no-fund')
    }
    if ($Action -eq 'Setup' -or -not (Test-Path (Join-Path $projectRoot 'node_modules\.yarn-state.yml'))) {
        $env:YARN_ENABLE_PROGRESS_BARS = '0'
        Invoke-ProjectYarn -Arguments @('install', '--immutable')
    }
}

function Initialize-LocalStack {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Install Docker Desktop and start its Linux container engine first.' }
    Invoke-Checked 'docker' -Arguments @('info', '--format', '{{.ServerVersion}}')
    if (-not (Test-Path (Join-Path $projectRoot '.env'))) {
        Copy-Item (Join-Path $projectRoot '.env.example') (Join-Path $projectRoot '.env')
    }
    if (-not $env:LOCALSTACK_AUTH_TOKEN) {
        $tokenEntry = Get-Content (Join-Path $projectRoot '.env') | Where-Object { $_ -match '^\s*LOCALSTACK_AUTH_TOKEN\s*=' } | Select-Object -First 1
        if ($tokenEntry) { $env:LOCALSTACK_AUTH_TOKEN = (($tokenEntry -split '=', 2)[1]).Trim().Trim('"').Trim("'") }
    }
    if (-not $env:LOCALSTACK_AUTH_TOKEN) { throw 'Set LOCALSTACK_AUTH_TOKEN in the root .env file, then run this script again.' }
    # These dummy credentials target only the local emulator.
    $env:AWS_ACCESS_KEY_ID = 'test'
    $env:AWS_SECRET_ACCESS_KEY = 'test'
    $env:AWS_SESSION_TOKEN = $null
    $env:AWS_PROFILE = $null
    $env:AWS_REGION = 'us-east-1'
    $env:AWS_DEFAULT_REGION = 'us-east-1'
    Invoke-Checked 'docker' -Arguments @('compose', 'up', '-d')
    $deadline = (Get-Date).AddMinutes(5)
    do {
        try {
            $health = Invoke-RestMethod 'http://127.0.0.1:4566/_localstack/health' -TimeoutSec 5
            if ($health.services) { return }
        } catch { }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw 'LocalStack did not become ready. Run docker compose logs localstack.'
}

function Deploy-LocalStack {
    Initialize-LocalStack
    Invoke-ProjectYarn -Arguments @('build:backend')
    Push-Location (Join-Path $projectRoot 'packages\infra')
    try {
        Invoke-ProjectYarn -Arguments @('workspace', '@aws-sdk-notes-app/infra', 'build')
        Invoke-Checked 'lstk' -Arguments @('--endpoint-url', 'http://127.0.0.1:4566', 'cdk', 'bootstrap')
        $outputsFile = Join-Path $toolsDir 'cdk-outputs.json'
        Invoke-Checked 'lstk' -Arguments @('--endpoint-url', 'http://127.0.0.1:4566', 'cdk', 'deploy', '--require-approval', 'never', '--outputs-file', $outputsFile)
    } finally { Pop-Location }
    Invoke-Checked 'node' -Arguments @('packages/scripts/populate-frontend-config.js', '--local', '--dev', '--outputs-file', $outputsFile)
}

Push-Location $projectRoot
try {
    Initialize-Tools
    switch ($Action) {
        'Setup' { Write-Output 'Project tooling and dependencies are ready.' }
        'Build' {
            Invoke-ProjectYarn -Arguments @('build:backend')
            Invoke-ProjectYarn -Arguments @('build:frontend')
            Invoke-ProjectYarn -Arguments @('workspace', '@aws-sdk-notes-app/infra', 'build')
        }
        'Deploy' { Deploy-LocalStack }
        'Start' {
            Deploy-LocalStack
            Invoke-ProjectYarn -Arguments @('workspace', '@aws-sdk-notes-app/frontend', 'start', '--host', '127.0.0.1', '--port', '5173', '--strictPort')
        }
        'Frontend' {
            if (-not (Test-Path 'packages/frontend/.env')) { throw 'Deploy the local infrastructure first: .\scripts\local.ps1 -Action Deploy' }
            Invoke-ProjectYarn -Arguments @('workspace', '@aws-sdk-notes-app/frontend', 'start', '--host', '127.0.0.1', '--port', '5173', '--strictPort')
        }
        'Stop' { Invoke-Checked 'docker' -Arguments @('compose', 'stop') }
        'Status' { Invoke-Checked 'docker' -Arguments @('compose', 'ps') }
    }
} finally { Pop-Location }
