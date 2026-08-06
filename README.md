# FrapzPifon

Native ARM64 porting toolkit for the official FRANZFON appliance.

The project extracts the architecture-independent FRANZFON application from the official Proxmox backup, rebuilds all native Node.js dependencies for ARM64, compiles Asterisk 22.7.0 natively and creates fresh local databases and service configuration. It does not run an x86 virtual machine or require Box64 for the validated core stack.

## Validation status

The complete installation has passed two native ARM64 validations:

- staged end-to-end validation of payload, application, Node.js addons, Asterisk, bootstrap and functional checks
- clean-host validation using only the public unified installer command

The validated stack includes:

- Node.js 20 ARM64 and the FRANZFON backend/frontend
- native `better-sqlite3` AArch64 addon
- Asterisk 22.7.0 ARM64
- PJSIP, WebSocket, ARI, voicemail and ODBC modules
- MariaDB 10.11, Redis and SQLite
- FRANZFON web interface on port 3000
- Asterisk CDR database access through ODBC

The automated validation confirms that no x86 executable remains below `/opt/franzfon` or `/opt/franzfon-arm64`.

## Recommended validation path

Do not move directly from CI to a physical Raspberry Pi. The next layer is the resettable full-system ARM64 virtual lab in [`virtualization/`](virtualization/README.md).

It runs a complete Debian 12 ARM64 guest under QEMU inside Docker Desktop and provides reusable QCOW2 checkpoints. This keeps systemd, Asterisk, MariaDB, permissions and reboot behavior close to the later Pi installation while allowing a broken experiment to be discarded without reinstalling hardware.

On Windows 11:

```powershell
cd virtualization
.\lab.ps1 start
.\lab.ps1 ssh
```

Inside the VM:

```bash
cd ~/FrapzPifon
git pull
sudo bash installer/franzfon-arm64-install.sh --activate
sudo bash installer/franzfon-arm64-selftest.sh
```

After the first green VM installation:

```powershell
.\lab.ps1 checkpoint installed-green
```

Restore that exact state after later experiments:

```powershell
.\lab.ps1 restore installed-green
```

The physical Pi test comes only after clean install, checkpoint restore, cold boot and functional SIP checks have passed in this VM.

## Target system

Use a clean Debian-compatible ARM64 installation, preferably:

- Raspberry Pi OS 64-bit based on Debian 12
- Debian 12 ARM64
- Ubuntu Server 24.04 ARM64

A Raspberry Pi 4 or Pi 5 with at least 4 GB RAM is recommended. Keep at least 16 GB free during installation because the official appliance is downloaded and extracted as a sparse virtual disk. The preparer refuses to start with less than 12 GiB available in its working directory.

## Installation

```bash
git clone https://github.com/DeineMutter1337/FrapzPifon.git
cd FrapzPifon
sudo bash installer/franzfon-arm64-install.sh --activate
```

The installer performs these stages:

1. downloads and validates the official FRANZFON Proxmox appliance
2. extracts a sanitized application payload read-only
3. installs the application and rebuilds Node.js dependencies for ARM64
4. verifies and normalizes native Node.js addons
5. compiles and verifies Asterisk 22.7.0 for AArch64
6. creates fresh MariaDB, ODBC and Asterisk configuration
7. handles the FRANZFON first-boot Asterisk restart
8. enables services only after HTTP and Asterisk health checks pass
9. runs the read-only ARM64 post-install self-test

Without `--activate`, the software is installed but Asterisk and FRANZFON remain disabled and stopped:

```bash
sudo bash installer/franzfon-arm64-install.sh
```

The completed installation can then be activated with:

```bash
sudo bash installer/franzfon-arm64-bootstrap.sh --activate
```

## Access and ports

After successful activation, open:

```text
http://<device-ip>:3000/
```

Relevant ports:

| Purpose | Port |
|---|---:|
| FRANZFON web interface | TCP 3000 |
| SIP/PJSIP | UDP/TCP 5060 |
| Asterisk HTTP/WebSocket | TCP 8088 |
| RTP audio | UDP 10000-10200 |
| Asterisk Manager Interface | TCP 5038, localhost only |

Firewall and router rules are not changed automatically.

## Status and diagnostics

```bash
sudo bash installer/franzfon-arm64-selftest.sh
systemctl status franzfon-wizard.service asterisk.service mariadb.service redis-server.service
journalctl -u franzfon-wizard.service -u asterisk.service -n 200 --no-pager
sudo /opt/franzfon-arm64/asterisk/sbin/asterisk -rx 'core show version'
sudo /opt/franzfon-arm64/asterisk/sbin/asterisk -rx 'pjsip show endpoints'
sudo /opt/franzfon-arm64/asterisk/sbin/asterisk -rx 'odbc show'
```

Installation state is recorded without secrets in:

```text
/etc/franzfon-arm64/install-state
```

Fresh credentials are stored root-only in:

```text
/opt/franzfon/config/database.env
```

## Intentionally omitted from the first ARM64 version

- FreePBX
- DAHDI hardware drivers
- proprietary G.729 codec
- Digium phone module
- imported passwords, customer databases or machine identity
- existing license state
- local x86-only AI components

The original FRANZFON licensing mechanism remains intact and is not bypassed. Activation or transfer to new hardware may require a legitimate license reset by FRANZFON support.

## Test evidence

Sanitized machine-readable reports are published below:

```text
analysis-results/arm64-end-to-end-v5/latest/
analysis-results/arm64-unified-installer/latest/
analysis-results/installer-static/latest/
```

The next milestone is a repeatable Debian 12 ARM64 VM cycle: clean install, self-test, checkpoint, restore, cold boot and a real SIP call between disposable test endpoints. The Raspberry Pi follows only after that cycle is green.
