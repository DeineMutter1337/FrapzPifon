#!/usr/bin/env bash
set -euo pipefail

PAYLOAD_DIR='/var/lib/franzfon-arm64/payload'
PREPARE_WORKDIR='/var/tmp/franzfon-arm64-prepare'
ASTERISK_WORKDIR='/var/tmp/franzfon-arm64-asterisk-build'
IMAGE_URL=''
ACTIVATE=0
SKIP_PREPARE=0
FORCE_ASTERISK=0
KEEP_PREPARE_WORK=0
KEEP_ASTERISK_WORK=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./installer/franzfon-arm64-install.sh [options]

Options:
  --activate                Enable and start the validated stack after installation.
  --payload-dir PATH        Sanitized payload location.
                            Default: /var/lib/franzfon-arm64/payload
  --image-url URL           Override the official appliance image URL.
  --skip-prepare            Reuse an existing validated payload directory.
  --force-asterisk          Replace an existing managed Asterisk installation.
  --keep-prepare-work       Keep extracted VM working files for debugging.
  --keep-asterisk-work      Keep Asterisk build files for debugging.
  -h, --help                Show this help.

Without --activate, all installation stages run but Asterisk and FRANZFON remain
disabled and stopped. Existing passwords, databases, machine identity and
license state are not imported. The original licensing mechanism is preserved.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --activate) ACTIVATE=1; shift ;;
    --payload-dir)
      [ "$#" -ge 2 ] || { echo 'Missing value for --payload-dir' >&2; exit 2; }
      PAYLOAD_DIR="$2"; shift 2 ;;
    --image-url)
      [ "$#" -ge 2 ] || { echo 'Missing value for --image-url' >&2; exit 2; }
      IMAGE_URL="$2"; shift 2 ;;
    --skip-prepare) SKIP_PREPARE=1; shift ;;
    --force-asterisk) FORCE_ASTERISK=1; shift ;;
    --keep-prepare-work) KEEP_PREPARE_WORK=1; shift ;;
    --keep-asterisk-work) KEEP_ASTERISK_WORK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in arm64|aarch64) ;; *) echo "ARM64 required, found: $ARCH" >&2; exit 1 ;; esac

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|raspbian:*|*:debian*) ;;
    *) echo "Debian-compatible ARM64 is required, found: ${ID:-unknown}" >&2; exit 1 ;;
  esac
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREPARE="$SCRIPT_DIR/franzfon-arm64-prepare.sh"
INSTALL_APP="$SCRIPT_DIR/franzfon-arm64-install-app.sh"
NORMALIZE_ADDONS="$SCRIPT_DIR/franzfon-arm64-normalize-native-addons.sh"
INSTALL_ASTERISK="$SCRIPT_DIR/franzfon-arm64-install-asterisk.sh"
BOOTSTRAP="$SCRIPT_DIR/franzfon-arm64-bootstrap.sh"
SELFTEST="$SCRIPT_DIR/franzfon-arm64-selftest.sh"

for stage in "$PREPARE" "$INSTALL_APP" "$NORMALIZE_ADDONS" "$INSTALL_ASTERISK" "$BOOTSTRAP" "$SELFTEST"; do
  [ -f "$stage" ] || { echo "Missing installer stage: $stage" >&2; exit 1; }
done

PAYLOAD_DIR="$(realpath -m "$PAYLOAD_DIR")"

printf '\nFRANZFON native ARM64 installation\n'
printf '  Payload:   %s\n' "$PAYLOAD_DIR"
printf '  Activate:  %s\n' "$([ "$ACTIVATE" -eq 1 ] && echo yes || echo no)"
printf '  Asterisk:  22.7.0 native ARM64\n\n'

if [ "$SKIP_PREPARE" -eq 0 ]; then
  PREPARE_ARGS=(--output "$PAYLOAD_DIR" --workdir "$PREPARE_WORKDIR")
  [ -z "$IMAGE_URL" ] || PREPARE_ARGS+=(--image-url "$IMAGE_URL")
  [ "$KEEP_PREPARE_WORK" -eq 0 ] || PREPARE_ARGS+=(--keep-work)

  printf '[Stage 1/5] Preparing sanitized payload\n'
  bash "$PREPARE" "${PREPARE_ARGS[@]}"
else
  printf '[Stage 1/5] Reusing existing sanitized payload\n'
  [ -f "$PAYLOAD_DIR/SHA256SUMS" ] || {
    echo "Existing payload is missing SHA256SUMS: $PAYLOAD_DIR" >&2
    exit 1
  }
fi

printf '\n[Stage 2/5] Installing FRANZFON application natively\n'
bash "$INSTALL_APP" --payload "$PAYLOAD_DIR"

printf '\n[Stage 3/5] Verifying native Node.js addons\n'
bash "$NORMALIZE_ADDONS"

printf '\n[Stage 4/5] Compiling Asterisk natively\n'
ASTERISK_ARGS=(--workdir "$ASTERISK_WORKDIR")
[ "$FORCE_ASTERISK" -eq 0 ] || ASTERISK_ARGS+=(--force)
[ "$KEEP_ASTERISK_WORK" -eq 0 ] || ASTERISK_ARGS+=(--keep-work)
bash "$INSTALL_ASTERISK" "${ASTERISK_ARGS[@]}"

printf '\n[Stage 5/5] Bootstrapping databases and services\n'
BOOTSTRAP_ARGS=()
[ "$ACTIVATE" -eq 0 ] || BOOTSTRAP_ARGS+=(--activate)
bash "$BOOTSTRAP" "${BOOTSTRAP_ARGS[@]}"

if [ "$ACTIVATE" -eq 1 ]; then
  printf '\n[Post-install] Running complete local ARM64 self-test\n'
  bash "$SELFTEST"
fi

printf '\nInstallation completed successfully.\n'
if [ "$ACTIVATE" -eq 1 ]; then
  printf 'FRANZFON web interface: http://<device-ip>:3000/\n'
  systemctl --no-pager --full status asterisk.service franzfon-wizard.service
else
  printf 'Services remain disabled. Activate after review with:\n'
  printf '  sudo bash %q --activate\n' "$BOOTSTRAP"
fi
