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
    param([switch]$IncludeStopped)

    $args = @('compose', 'ps')
    if ($IncludeStopped) {
        $args += '-a'
    }
    $args += @('-q', 'vm')

    $id = & docker @args 2>$null | Select-Object -First 1
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

function Assert-LabContainerRunning {
    Start-Sleep -Seconds 3
    $containerId = Get-LabContainerId -IncludeStopped
    if ([string]::IsNullOrWhiteSpace($containerId)) {
        throw 'Docker did not create the FRANZFON lab container.'
    }

    $running = & docker inspect --format '{{.State.Running}}' $containerId 2>$null
    if ($running -ne 'true') {
        $exitCode = & docker inspect --format '{{.State.ExitCode}}' $containerId 2>$null
        Write-Host ''
        Write-Host "FRANZFON ARM64 VM exited during startup (exit code $exitCode)." -ForegroundColor Red
        Write-Host 'Docker log:' -ForegroundColor Yellow
        & docker compose logs --no-color --tail 200 vm
        throw 'The ARM64 VM did not remain running. See the Docker log above.'
    }
}

function Test-SshBanner {
    param(
        [string]$HostName = '127.0.0.1',
        [int]$Port
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($HostName, $Port)
        if (-not $connectTask.Wait(3000)) {
            return $false
        }

        $stream = $client.GetStream()
        $stream.ReadTimeout = 3000
        $buffer = New-Object byte[] 255
        $count = $stream.Read($buffer, 0, $buffer.Length)
        if ($count -le 0) {
            return $false
        }

        $banner = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $count)
        return $banner.StartsWith('SSH-')
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Wait-LabSsh {
    param([int]$TimeoutSeconds = 900)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0
    Write-Host "Waiting for Debian SSH on 127.0.0.1:$SshPort ..."

    while ((Get-Date) -lt $deadline) {
        $containerId = Get-LabContainerId
        if ([string]::IsNullOrWhiteSpace($containerId)) {
            throw 'The FRANZFON lab container is not running.'
        }

        if (Test-SshBanner -Port ([int]$SshPort)) {
            Write-Host 'Debian SSH is ready.' -ForegroundColor Green
            return
        }

        $attempt++
        if (($attempt % 6) -eq 0) {
            Write-Host 'ARM64 guest is still booting. This can take several minutes under emulation.'
        }
        Start-Sleep -Seconds 5
    }

    Write-Host 'SSH did not become ready. Last VM log lines:' -ForegroundColor Yellow
    & docker compose logs --no-color --tail 100 vm
    throw "SSH was not ready after $TimeoutSeconds seconds."
}

try {
    & docker version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker Desktop is not available. Start Docker Desktop and use Linux containers.'
    }

    switch ($Action) {
        'start' {
            Invoke-Compose @('up', '-d', '--build')
            Assert-LabContainerRunning
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
            Wait-LabSsh
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
            Assert-LabContainerRunning
            Write-Host "Checkpoint '$Name' created. A fresh overlay is running on top of it."
            Write-Host "Run '.\lab.ps1 ssh'. It will wait until Debian SSH is ready."
        }

        'restore' {
            Require-CheckpointName
            Stop-LabGracefully
            Invoke-Compose @('run', '--rm', '--no-deps', '--entrypoint', '/usr/local/bin/labctl', 'vm', 'restore', $Name)
            Invoke-Compose @('up', '-d')
            Assert-LabContainerRunning
            Write-Host "Checkpoint '$Name' restored."
            Write-Host "Run '.\lab.ps1 ssh'. It will wait until Debian SSH is ready."
        }

        'reset' {
            Stop-LabGracefully
            Invoke-Compose @('run', '--rm', '--no-deps', '--entrypoint', '/usr/local/bin/labctl', 'vm', 'reset')
            Invoke-Compose @('up', '-d')
            Assert-LabContainerRunning
            Write-Host 'VM reset to clean Debian 12 ARM64. Existing checkpoints were kept.'
            Write-Host "Run '.\lab.ps1 ssh'. It will wait until Debian SSH is ready."
        }
    }
}
finally {
    Pop-Location
}
