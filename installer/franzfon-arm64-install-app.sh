#!/usr/bin/env bash
set -euo pipefail

NODE_VERSION='20.20.2'
NODE_ARCHIVE="node-v${NODE_VERSION}-linux-arm64.tar.xz"
NODE_SHA256='73093db209e4e9e09dd7d15a47aeaab1b74833830df03efa5f942a1122c5fa71'
NODE_BASE_URL="https://nodejs.org/download/release/v${NODE_VERSION}"

PAYLOAD_DIR=''
ACTIVATE=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./installer/franzfon-arm64-install-app.sh --payload /var/lib/franzfon-arm64/payload

Options:
  --payload PATH  Output directory produced by franzfon-arm64-prepare.sh.
  --activate      Enable/start the wizard only when its database environment and
                  Asterisk are already configured. Default: install but do not start.
  -h, --help      Show help.

This installs only native ARM64 runtimes and architecture-independent FRANZFON
application files. It does not migrate licenses, bypass activation, import raw
MariaDB files or install x86 binaries.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --payload)
      [ "$#" -ge 2 ] || { echo 'Missing value for --payload' >&2; exit 2; }
      PAYLOAD_DIR="$2"; shift 2 ;;
    --activate) ACTIVATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$PAYLOAD_DIR" ] || { echo '--payload is required' >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in arm64|aarch64) ;; *) echo "ARM64 required, found: $ARCH" >&2; exit 1 ;; esac

PAYLOAD_DIR="$(realpath "$PAYLOAD_DIR")"
[ -f "$PAYLOAD_DIR/SHA256SUMS" ] || { echo 'Payload SHA256SUMS is missing.' >&2; exit 1; }
[ -f "$PAYLOAD_DIR/payload/opt/franzfon/wizard/backend/package-lock.json" ] || {
  echo 'FRANZFON backend package-lock.json is missing from payload.' >&2; exit 1;
}
[ -d "$PAYLOAD_DIR/payload/opt/franzfon/wizard/frontend/dist" ] || {
  echo 'Prebuilt FRANZFON frontend dist directory is missing from payload.' >&2; exit 1;
}

printf '\n[1/7] Verifying payload manifest\n'
(
  cd "$PAYLOAD_DIR"
  sha256sum -c SHA256SUMS
)

printf '\n[2/7] Installing native Debian ARM64 runtime packages\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils file rsync jq \
  build-essential python3 make g++ pkg-config \
  mariadb-server mariadb-client redis-server sqlite3 \
  ffmpeg sox imagemagick \
  iproute2 procps net-tools openssl

printf '\n[3/7] Installing verified Node.js %s ARM64\n' "$NODE_VERSION"
NODE_ROOT='/usr/local/lib/nodejs'
NODE_HOME="$NODE_ROOT/node-v${NODE_VERSION}-linux-arm64"
TMP_NODE="$(mktemp -d /var/tmp/franzfon-node.XXXXXX)"
trap 'rm -rf "$TMP_NODE"' EXIT

curl --fail --location --retry 3 \
  "$NODE_BASE_URL/$NODE_ARCHIVE" \
  --output "$TMP_NODE/$NODE_ARCHIVE"
printf '%s  %s\n' "$NODE_SHA256" "$TMP_NODE/$NODE_ARCHIVE" | sha256sum -c -
mkdir -p "$NODE_ROOT"
rm -rf "$NODE_HOME"
tar -xJf "$TMP_NODE/$NODE_ARCHIVE" -C "$NODE_ROOT"

for TOOL in node npm npx corepack; do
  [ -e "$NODE_HOME/bin/$TOOL" ] || continue
  ln -sfn "$NODE_HOME/bin/$TOOL" "/usr/local/bin/$TOOL"
done

[ "$(/usr/local/bin/node -p 'process.arch')" = arm64 ] || {
  echo 'Installed Node.js is not ARM64.' >&2; exit 1;
}
/usr/local/bin/node --version
/usr/local/bin/npm --version

printf '\n[4/7] Installing FRANZFON application payload\n'
INSTALL_ROOT='/opt/franzfon'
BACKUP_ROOT='/var/backups/franzfon-arm64-port'
mkdir -p "$BACKUP_ROOT"

if [ -e "$INSTALL_ROOT" ]; then
  BACKUP_PATH="$BACKUP_ROOT/opt-franzfon-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "Backing up existing $INSTALL_ROOT to $BACKUP_PATH"
  cp -a "$INSTALL_ROOT" "$BACKUP_PATH"
fi

mkdir -p "$INSTALL_ROOT"
rsync -a --delete "$PAYLOAD_DIR/payload/opt/franzfon/" "$INSTALL_ROOT/"
mkdir -p \
  "$INSTALL_ROOT/config" \
  "$INSTALL_ROOT/wizard/backend/data" \
  "$INSTALL_ROOT/wizard/backend/backups"
chmod 0750 "$INSTALL_ROOT/config" "$INSTALL_ROOT/wizard/backend/data" "$INSTALL_ROOT/wizard/backend/backups"

if [ -f "$PAYLOAD_DIR/payload/usr/local/bin/pnp_server" ]; then
  install -D -m 0755 "$PAYLOAD_DIR/payload/usr/local/bin/pnp_server" /usr/local/bin/pnp_server
fi

printf '\n[5/7] Rebuilding backend dependencies natively on ARM64\n'
cd "$INSTALL_ROOT/wizard/backend"
rm -rf node_modules
/usr/local/bin/npm ci --omit=dev
/usr/local/bin/node --check src/index.js
/usr/local/bin/node -e '
  const Database = require("better-sqlite3");
  const db = new Database(":memory:");
  db.exec("CREATE TABLE smoke (value TEXT)");
  db.prepare("INSERT INTO smoke(value) VALUES (?)").run("arm64-ok");
  const result = db.prepare("SELECT value FROM smoke").get();
  if (result.value !== "arm64-ok") throw new Error("SQLite ARM64 smoke test failed");
  console.log("better-sqlite3 ARM64 smoke test passed");
'
file node_modules/better-sqlite3/build/Release/better_sqlite3.node | grep -E 'ARM aarch64|ARM64' >/dev/null

printf '\n[6/7] Installing adapted systemd service without FreePBX dependency\n'
cat > /etc/systemd/system/franzfon-wizard.service <<'EOF'
[Unit]
Description=FRANZFON Wizard ARM64
After=network-online.target mariadb.service asterisk.service
Wants=network-online.target mariadb.service asterisk.service
ConditionPathExists=/opt/franzfon/config/database.env

[Service]
Type=simple
User=root
WorkingDirectory=/opt/franzfon/wizard/backend
ExecStartPre=/bin/bash -c 'for i in $(seq 1 15); do ss -tlnp | grep -q ":3000 " || exit 0; sleep 1; done; echo "Port 3000 nicht freigegeben"; exit 1'
ExecStart=/usr/local/bin/node src/index.js
EnvironmentFile=/opt/franzfon/config/database.env
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable franzfon-wizard.service 2>/dev/null || true

mkdir -p /etc/franzfon-arm64
cat > /etc/franzfon-arm64/install-state <<EOF
APPLICATION_INSTALLED=yes
APPLICATION_ARCH=arm64
NODE_VERSION=$NODE_VERSION
FREEPBX_REQUIRED=no
WIZARD_ENABLED=no
DATABASE_CONFIGURED=$([ -f /opt/franzfon/config/database.env ] && echo yes || echo no)
EOF
chmod 0600 /etc/franzfon-arm64/install-state

printf '\n[7/7] Final architecture and safety checks\n'
if find "$INSTALL_ROOT" -type f -print0 | while IFS= read -r -d '' F; do
  DESC="$(file -b "$F" 2>/dev/null || true)"
  case "$DESC" in *x86-64*|*Intel\ 80386*|*PE32*) echo "$F"; esac
done | grep -q .; then
  echo 'Unexpected x86 file found below /opt/franzfon.' >&2
  exit 1
fi

if [ "$ACTIVATE" -eq 1 ]; then
  [ -f /opt/franzfon/config/database.env ] || {
    echo 'Cannot activate: /opt/franzfon/config/database.env is missing.' >&2; exit 1;
  }
  command -v asterisk >/dev/null 2>&1 || {
    echo 'Cannot activate: native Asterisk is not installed.' >&2; exit 1;
  }
  systemctl enable --now mariadb redis-server franzfon-wizard.service
  systemctl --no-pager --full status franzfon-wizard.service
else
  echo
  echo 'Application stage installed successfully but not activated.'
  echo 'Next required stages: native Asterisk, database initialization/migration, then license migration.'
fi

rm -rf "$TMP_NODE"
trap - EXIT
