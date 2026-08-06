#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="$SCRIPT_DIR/franzfon-arm64-normalize-native-addons.sh"
INSTALL_BUNDLE="$SCRIPT_DIR/franzfon-arm64-install-asterisk-bundle.sh"
BOOTSTRAP="$SCRIPT_DIR/franzfon-arm64-bootstrap.sh"
SELFTEST="$SCRIPT_DIR/franzfon-arm64-selftest.sh"

[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in arm64|aarch64) ;; *) echo "ARM64 required, found: $ARCH" >&2; exit 1 ;; esac

[ -f /etc/franzfon-arm64/install-state ] || { echo 'Application installation state is missing.' >&2; exit 1; }
grep -Fxq 'APPLICATION_INSTALLED=yes' /etc/franzfon-arm64/install-state || { echo 'Application stage is incomplete.' >&2; exit 1; }
grep -Fxq 'APPLICATION_ARCH=arm64' /etc/franzfon-arm64/install-state || { echo 'Application stage is not ARM64.' >&2; exit 1; }
[ -f /opt/franzfon/wizard/backend/src/index.js ] || { echo 'FRANZFON backend is missing.' >&2; exit 1; }
[ "$(/usr/local/bin/node -p 'process.arch')" = arm64 ] || { echo 'ARM64 Node.js is missing.' >&2; exit 1; }

printf '\n[Fast 1/4] Verifying native Node.js addons\n'
bash "$NORMALIZE"

printf '\n[Fast 2/4] Installing verified prebuilt Asterisk ARM64 bundle\n'
BUNDLE_ARGS=()
if [ -f /opt/franzfon-arm64/asterisk/.franzfon-arm64-asterisk ]; then
  BUNDLE_ARGS+=(--force)
fi
bash "$INSTALL_BUNDLE" "${BUNDLE_ARGS[@]}"

printf '\n[Fast 3/4] Configuring databases and activating services\n'
bash "$BOOTSTRAP" --activate

printf '\n[Fast 4/4] Running complete local ARM64 self-test\n'
bash "$SELFTEST"

echo
echo 'Fast resume completed successfully.'
echo 'FRANZFON guest web interface: http://127.0.0.1:3000/'
