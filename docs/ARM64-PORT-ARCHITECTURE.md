# FRANZFON ARM64 Port Architecture

Status: validated through automated read-only appliance analysis and ARM64 smoke tests.

## Goal

Run the FRANZFON appliance natively on Debian 12 ARM64, especially Raspberry Pi 4/5, without a full x86 virtual machine.

The port must preserve FRANZFON's licensing and activation mechanisms. It does not bypass or modify license checks. A hardware-bound license may require an official reset or migration by FRANZFON support.

## Validated findings

### FRANZFON application

The FRANZFON application consists mainly of architecture-independent JavaScript, Astro, shell scripts, static assets and configuration templates.

Two Node projects exist:

- `/opt/franzfon/wizard/backend`
- `/opt/franzfon/wizard/frontend`

The backend starts with:

```text
/usr/bin/node /opt/franzfon/wizard/backend/src/index.js
```

The frontend is a static Astro build.

### ARM64 Node validation

Validated successfully inside Debian 12 ARM64:

- Node.js 20 starts as `arm64`
- backend `npm ci --omit=dev` completes
- `src/index.js` passes syntax validation
- `better-sqlite3` installs as an AArch64 ELF module
- an actual SQLite create/insert/select test passes
- frontend `npm ci` completes
- Astro builds all 30 application pages

Existing x86 `node_modules` must never be copied to ARM64. They are always rebuilt from the lockfiles.

### FreePBX dependency

The running FRANZFON backend does not reference `fwconsole`, `/var/www/html/admin`, `/etc/freepbx.conf` or `/etc/amportal.conf`.

All detected FreePBX references are confined to `prepare-iso.sh`, which belongs to image production rather than normal runtime operation.

Therefore the ARM64 V1 does not require the complete FreePBX web application.

The original service ordering:

```ini
After=network.target freepbx.service
```

is replaced with:

```ini
After=network-online.target mariadb.service asterisk.service
Wants=network-online.target mariadb.service asterisk.service
```

### Runtime dependencies

Native ARM64 packages or builds are required for:

- Node.js 20
- MariaDB client/server
- SQLite3
- Redis
- FFmpeg and FFprobe
- SoX
- ImageMagick compatibility command `convert`
- rsync, curl, tar, OpenSSL and standard networking tools
- Asterisk 22.7.0

### Databases

FRANZFON uses both SQLite and MariaDB.

SQLite application data lives below:

```text
/opt/franzfon/wizard/backend/data/
```

MariaDB data must be migrated through a logical dump and restore. Raw `/var/lib/mysql` files are not copied between installations.

### Asterisk

The source appliance uses Asterisk 22.7.0 and 27 AMD64-specific Asterisk packages.

For ARM64 these packages are replaced with a native Asterisk 22.7.0 build. The initial feature set targets:

- PJSIP
- AMI
- ARI
- HTTP/WebSocket
- voicemail
- SQLite
- ODBC
- Opus, Speex, ulaw, alaw and standard open codecs

Deferred or optional in V1:

- proprietary G.729 module
- DAHDI hardware stack
- Digium phone module
- hardware-specific Sangoma modules

The Sangoma `pnp_server` found in the appliance is a Python script, not an x86 ELF binary. It may be tested later as an optional component.

## V1 system layout

```text
Debian 12 ARM64
├── MariaDB 10.11
├── Redis
├── PHP 8.2 where required by helper components
├── Node.js 20 ARM64
├── Asterisk 22.7.0 ARM64
├── /opt/franzfon
│   ├── wizard/backend
│   ├── wizard/frontend/dist
│   ├── scripts
│   ├── assets
│   └── config
└── systemd
    ├── franzfon-firstboot.service
    ├── franzfon-setup.service
    ├── franzfon-wizard.service
    ├── franzfon-issue.service/timer
    └── asterisk.service
```

## Installation stages

1. Validate Debian 12 ARM64 and available disk space.
2. Install native ARM64 runtime packages.
3. Download and verify the official FRANZFON Proxmox appliance.
4. Extract the VMA locally and mount the disk read-only.
5. Copy architecture-independent application files only.
6. Exclude machine IDs, SSH keys, credentials, runtime secrets, raw MariaDB files, x86 binaries and existing `node_modules`.
7. Rebuild backend dependencies on ARM64.
8. Build or reuse the static frontend on ARM64.
9. Build and install Asterisk 22.7.0 ARM64.
10. Import SQLite application data and a logical MariaDB dump where appropriate.
11. Install adapted systemd services.
12. Run smoke tests before enabling services.
13. Handle legitimate license migration through the existing mechanism or FRANZFON support.

## Non-goals

- no x86 VM
- no license bypass
- no copying of AMD64 binaries into the native runtime
- no automatic local-AI installation in V1
- no raw MariaDB datadir migration
