# FRANZFON ARM64 Virtual Lab

This lab runs a complete Debian 12 ARM64 virtual machine under QEMU inside Docker Desktop. It is intentionally a full VM rather than a normal application container so that systemd, MariaDB, Redis, Asterisk, filesystem permissions and reboot behavior match the later Raspberry Pi installation much more closely.

The FRANZFON application is never stored in the repository or baked into the Docker image. The installer downloads the official appliance inside the guest and creates the sanitized payload locally.

## Requirements

- Windows 11
- Docker Desktop using Linux containers
- Docker Compose v2 (`docker compose`)
- At least 16 GB free disk space
- At least 8 GB host RAM; the VM uses 4 GB by default

ARM64 is fully emulated on an x86-64 Windows PC, so the first Asterisk compilation is considerably slower than on native ARM hardware. After a successful installation, create a checkpoint and restore it instead of rebuilding.

## Start the clean VM

Open PowerShell in this directory:

```powershell
.\lab.ps1 start
```

The first start downloads and verifies the official Debian 12 ARM64 cloud image. Cloud-init then creates the local lab account and clones this repository.

Connections:

- SSH: `127.0.0.1:2222`
- FRANZFON web: `http://127.0.0.1:3000/`
- SIP UDP: `127.0.0.1:5060`
- Asterisk HTTP/WebSocket: `127.0.0.1:8088`
- RTP UDP: `127.0.0.1:10000-10020`

Lab login:

```text
user: franzfon
password: franzfon
```

The ports are bound to localhost only. The password is for this disposable local VM and must never be reused elsewhere.

## Install FRANZFON inside the VM

```powershell
.\lab.ps1 ssh
```

Then inside Debian:

```bash
cd ~/FrapzPifon
git pull
sudo bash installer/franzfon-arm64-install.sh --activate
sudo bash installer/franzfon-arm64-selftest.sh
```

## Checkpoints and resets

After the first fully green installation:

```powershell
.\lab.ps1 checkpoint installed-green
```

Restore that checkpoint after an experiment:

```powershell
.\lab.ps1 restore installed-green
```

Return to a completely clean Debian image:

```powershell
.\lab.ps1 reset
```

List the current backing image and available checkpoints:

```powershell
.\lab.ps1 status
```

The VM is powered down through QEMU before a checkpoint is created. Checkpoints are standalone QCOW2 images in `virtualization/state/checkpoints/` and are ignored by Git.

## Why not only Docker Compose services?

A split container stack is useful later for fast application development, but it does not validate the actual host installer, systemd ordering, loop-mounted source image, Asterisk runtime data, permissions or reboot behavior. This full ARM64 VM is therefore the primary pre-Pi test environment. A lighter Compose-only development stack can be added after the VM path remains stable.
