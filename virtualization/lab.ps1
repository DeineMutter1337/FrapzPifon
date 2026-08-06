param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'status', 'logs', 'ssh', 'checkpoint', 'restore', 'reset')]
    [string]$Action = 'start',

    [Parameter(Position = 1)]
    [string]$Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LabRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $LabRoot

$SshPort = if ($env:FRANZFON_LAB_SSH_PORT) { $env:FRANZFON_LAB_SSH_PORT } else { '2222' }
$WebPort = if ($env:FRANZFON_LAB_WEB_PORT) { $env:FRANZFON_LAB_WEB_PORT } else { '13000' }

function Invoke-Compose {
    param([string[]]$ComposeArgs)

    & docker compose @ComposeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed: $($ComposeArgs -join ' ')"
    }
}

function Get-LabContainerId {
    $id = & docker compose ps -q vm 2>$null | Select-Object -First 1
    return [string]$id
}

function Stop-LabGracefully {
    $containerId = Get-LabContainerId
    if (-not [string]::IsNullOrWhiteSpace($containerId)) {
        & docker compose exec -T vm /usr/local/bin/labctl poweroff 2>$null

        for ($i = 0; $i -lt 60; $i++) {
            $running = & docker inspect --format '{{.State.Running}}' $containerId 2>$null
            if ($running -ne 'true') {
                break
            }
            Start-Sleep -Seconds 1
        }
    }

    Invoke-Compose @('down')
}

function Require-CheckpointName {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Action '$Action' requires a checkpoint name."
    }
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'Checkpoint names may contain only letters, numbers, dot, underscore and dash.'
    }
}

try {
    & docker version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Desktop is not available. Start Docker Desktop and use Linux containers.'
    }

    switch ($Action) {
        'start' {
            Invoke-Compose @('up', '-d', '--build')
            Write-Host ''
            Write-Host 'FRANZFON ARM64 VM started.'
            Write-Host "SSH:  ssh -p $SshPort franzfon@127.0.0.1"
            Write-Host 'User: franzfon  Password: franzfon'
            Write-Host "Web:  http://127.0.0.1:$WebPort/"
            Write-Host ''
            Write-Host 'First boot and cloud-init can take several minutes under ARM emulation.'
        }

        'stop' {
            Stop-LabGracefully
        }

        'status' {
            Invoke-Compose @('run', '--rm', '--no-deps', '--entrypoint', '/usr/local/bin/labctl', 'vm', 'status')
        }

        'logs' {
            Invoke-Compose @('logs', '-f', 'vm')
        }

        'ssh' {
            & ssh `
                -o StrictHostKeyChecking=no `
                -o UserKnownHostsFile=NUL `
                -p $SshPort `
                franzfon@127.0.0.1
        }

        'checkpoint' {
            Require-CheckpointName
            Stop-LabGracefully
            Invoke-Compose @('run', '--rm', '--no-deps', '--entrypoint', '/usr/local/bin/labctl', 'vm', 'checkpoint', $Name)
            Invoke-Compose @('up', '-d')
            Write-Host "Checkpoint '$Name' created. A fresh overlay is running on top of it."
        }

        'restore' {
            Require-CheckpointName
            Stop-LabGracefully
            Invoke-Compose @('run', '--rm', '--no-deps', '--entrypoint', '/usr/local/bin/labctl', 'vm', 'restore', $Name)
            Invoke-Compose @('up', '-d')
            Write-Host "Checkpoint '$Name' restored."
        }

        'reset' {
            Stop-LabGracefully
            Invoke-Compose @('run', '--rm', '--no-deps', '--entrypoint', '/usr/local/bin/labctl', 'vm', 'reset')
            Invoke-Compose @('up', '-d')
            Write-Host 'VM reset to clean Debian 12 ARM64. Existing checkpoints were kept.'
        }
    }
}
finally {
    Pop-Location
}
