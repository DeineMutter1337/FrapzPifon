#!/usr/bin/env bash
set -euo pipefail

IMAGE_URL_DEFAULT='https://franzfon.de/updates/proxmox/vzdump-qemu-900-2026_08_04-01_09_26.vma.zst'
IMAGE_URL="$IMAGE_URL_DEFAULT"
OUTPUT_DIR=''
WORK_DIR=''
KEEP_WORK=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./installer/franzfon-arm64-prepare.sh --output /var/lib/franzfon-arm64/payload [options]

Options:
  --output PATH      Required output directory for the architecture-independent payload.
  --workdir PATH     Temporary working directory. Default: /var/tmp/franzfon-arm64-prepare.
  --image-url URL    Official VMA.ZST source URL.
  --keep-work        Keep extracted sparse disk for debugging.
  -h, --help         Show this help.

This stage does not install or enable FRANZFON services. It creates a sanitized
payload from the official appliance and refuses to copy x86 binaries,
node_modules, databases, environment files, private keys or machine identity.
Application code implementing the original license mechanism is preserved;
license state itself is excluded with the runtime databases and environment files.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || { echo 'Missing value for --output' >&2; exit 2; }
      OUTPUT_DIR="$2"; shift 2 ;;
    --workdir)
      [ "$#" -ge 2 ] || { echo 'Missing value for --workdir' >&2; exit 2; }
      WORK_DIR="$2"; shift 2 ;;
    --image-url)
      [ "$#" -ge 2 ] || { echo 'Missing value for --image-url' >&2; exit 2; }
      IMAGE_URL="$2"; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$OUTPUT_DIR" ] || { echo '--output is required' >&2; usage >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
  arm64|aarch64) ;;
  *) echo "Unsupported architecture: $ARCH. This preparer is for ARM64." >&2; exit 1 ;;
esac

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != debian ] && [ "${ID_LIKE:-}" != *debian* ]; then
    echo "Unsupported OS family: ${ID:-unknown}. Debian-compatible ARM64 is required." >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXTRACTOR="$REPO_ROOT/scripts/stream_vma_extract.py"
[ -f "$EXTRACTOR" ] || { echo "Missing extractor: $EXTRACTOR" >&2; exit 1; }

WORK_DIR="${WORK_DIR:-/var/tmp/franzfon-arm64-prepare}"
WORK_PARENT="$(dirname "$WORK_DIR")"
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
WORK_DIR="$(realpath -m "$WORK_DIR")"

case "$OUTPUT_DIR/" in
  "$WORK_DIR/"*)
    echo '--output must not be inside --workdir because temporary files are removed.' >&2
    exit 1
    ;;
esac

EXTRACTED="$WORK_DIR/extracted"
MOUNT_DIR="$WORK_DIR/root"
STAGE_DIR="$WORK_DIR/stage"
LOOP=''
MOUNTED=0

cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    umount "$MOUNT_DIR" 2>/dev/null || true
  fi
  if [ -n "$LOOP" ]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
  if [ "$KEEP_WORK" -eq 0 ]; then
    rm -rf "$WORK_DIR"
  else
    echo "Working files retained at: $WORK_DIR"
  fi
}
trap cleanup EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates python3 python3-zstandard file util-linux e2fsprogs rsync coreutils

mkdir -p "$WORK_PARENT"
AVAILABLE_KB="$(df -Pk "$WORK_PARENT" | awk 'NR==2 {print $4}')"
REQUIRED_KB=$((12 * 1024 * 1024))
if [ "${AVAILABLE_KB:-0}" -lt "$REQUIRED_KB" ]; then
  echo "At least 12 GiB free space is required in $WORK_PARENT." >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$EXTRACTED" "$MOUNT_DIR" "$STAGE_DIR/payload" "$STAGE_DIR/templates/systemd"
chmod 0700 "$WORK_DIR" "$STAGE_DIR"

printf '\n[1/6] Streaming and validating official VMA image\n'
python3 "$EXTRACTOR" "$IMAGE_URL" "$EXTRACTED"

RAW="$(find "$EXTRACTED" -maxdepth 1 -type f -size +16M -printf '%s\t%p\n' \
  | sort -nr | head -n1 | cut -f2-)"
[ -n "$RAW" ] || { echo 'No extracted virtual disk found.' >&2; exit 1; }

printf '\n[2/6] Attaching source disk read-only\n'
LOOP="$(losetup --find --show --partscan --read-only "$RAW")"
udevadm settle 2>/dev/null || true
sleep 2

ROOT_LINE="$(lsblk -bprno PATH,FSTYPE,SIZE "$LOOP" 2>/dev/null \
  | awk '$2 ~ /^(ext2|ext3|ext4|xfs|btrfs)$/ {print $3 "\t" $1 "\t" $2}' \
  | sort -nr | head -n1)"
ROOTDEV="$(printf '%s' "$ROOT_LINE" | cut -f2)"
ROOTFS="$(printf '%s' "$ROOT_LINE" | cut -f3)"
[ -n "$ROOTDEV" ] || { echo 'No Linux root filesystem found.' >&2; exit 1; }

case "$ROOTFS" in
  ext2|ext3|ext4)
    mount -o ro,noload "$ROOTDEV" "$MOUNT_DIR" 2>/dev/null || mount -o ro "$ROOTDEV" "$MOUNT_DIR"
    ;;
  xfs) mount -o ro,norecovery "$ROOTDEV" "$MOUNT_DIR" ;;
  btrfs) mount -o ro "$ROOTDEV" "$MOUNT_DIR" ;;
  *) echo "Unsupported source filesystem: $ROOTFS" >&2; exit 1 ;;
esac
MOUNTED=1

[ -f "$MOUNT_DIR/etc/os-release" ] || { echo 'Mounted filesystem is not the appliance root.' >&2; exit 1; }
[ -f "$MOUNT_DIR/opt/franzfon/wizard/backend/package.json" ] || { echo 'FRANZFON backend not found.' >&2; exit 1; }

printf '\n[3/6] Copying architecture-independent application files\n'
mkdir -p "$STAGE_DIR/payload/opt/franzfon"
rsync -a --safe-links \
  --exclude='node_modules/' \
  --exclude='.astro/' \
  --exclude='data/' \
  --exclude='backups/' \
  --exclude='backup/' \
  --exclude='config/' \
  --exclude='*.env' \
  --exclude='*.db' \
  --exclude='*.db-shm' \
  --exclude='*.db-wal' \
  --exclude='*.sqlite' \
  --exclude='*.sqlite3' \
  --exclude='*.key' \
  --exclude='id_rsa*' \
  --exclude='id_ed25519*' \
  "$MOUNT_DIR/opt/franzfon/" "$STAGE_DIR/payload/opt/franzfon/"

mkdir -p "$STAGE_DIR/payload/opt/franzfon/config"
chmod 0750 "$STAGE_DIR/payload/opt/franzfon/config"

shopt -s nullglob
for UNIT in \
  "$MOUNT_DIR"/etc/systemd/system/franzfon*.service \
  "$MOUNT_DIR"/etc/systemd/system/franzfon*.timer \
  "$MOUNT_DIR"/etc/systemd/system/asterisk.service \
  "$MOUNT_DIR"/etc/systemd/system/sangoma-pnpd.service; do
  [ -f "$UNIT" ] || continue
  cp -a "$UNIT" "$STAGE_DIR/templates/systemd/"
done
shopt -u nullglob

if [ -f "$MOUNT_DIR/usr/local/bin/pnp_server" ]; then
  mkdir -p "$STAGE_DIR/payload/usr/local/bin"
  cp -a "$MOUNT_DIR/usr/local/bin/pnp_server" "$STAGE_DIR/payload/usr/local/bin/"
fi

printf '\n[4/6] Refusing architecture-specific or sensitive payloads\n'
if find "$STAGE_DIR" -type d -name node_modules -print -quit | grep -q .; then
  echo 'Safety check failed: node_modules was copied.' >&2
  exit 1
fi

if find "$STAGE_DIR" -type f \( \
    -name '*.env' -o -name '*.db' -o -name '*.db-shm' -o -name '*.db-wal' \
    -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.key' \
    -o -name 'id_rsa*' -o -name 'id_ed25519*' \
  \) -print -quit | grep -q .; then
  echo 'Safety check failed: sensitive runtime file was copied.' >&2
  exit 1
fi

X86_REPORT="$STAGE_DIR/x86-files.txt"
: > "$X86_REPORT"
while IFS= read -r -d '' FILE_PATH; do
  DESCRIPTION="$(file -b "$FILE_PATH" 2>/dev/null || true)"
  case "$DESCRIPTION" in
    *x86-64*|*Intel\ 80386*|*PE32*)
      printf '%s\t%s\n' "${FILE_PATH#$STAGE_DIR/}" "$DESCRIPTION" >> "$X86_REPORT"
      ;;
  esac
done < <(find "$STAGE_DIR/payload" -type f -print0)

if [ -s "$X86_REPORT" ]; then
  echo 'Safety check failed: x86 files remain in the payload:' >&2
  cat "$X86_REPORT" >&2
  exit 1
fi
rm -f "$X86_REPORT"

printf '\n[5/6] Creating reproducible payload manifest\n'
(
  cd "$STAGE_DIR"
  find payload templates -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum > SHA256SUMS
)

cat > "$STAGE_DIR/README.txt" <<'EOF'
FRANZFON ARM64 clean application payload

This payload intentionally excludes:
- all existing node_modules and native x86 addons
- SQLite and MariaDB runtime data
- environment files and credentials
- license state stored in runtime data/configuration
- backups
- SSH/private keys and machine identity

Application code implementing the original licensing mechanism is preserved and
must not be modified to bypass activation. Backend and frontend dependencies
must be rebuilt natively on ARM64 from the included package-lock files.
Asterisk is installed separately as an ARM64 build.
EOF

printf '\n[6/6] Publishing local payload\n'
OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_PARENT"
chmod 0700 "$OUTPUT_PARENT" 2>/dev/null || true
rm -rf "$OUTPUT_DIR.new"
mv "$STAGE_DIR" "$OUTPUT_DIR.new"
rm -rf "$OUTPUT_DIR"
mv "$OUTPUT_DIR.new" "$OUTPUT_DIR"
chmod -R go-rwx "$OUTPUT_DIR"

printf '\nPayload prepared successfully:\n  %s\n' "$OUTPUT_DIR"
printf 'Files: %s\n' "$(find "$OUTPUT_DIR" -type f | wc -l)"
printf 'Size:  %s\n' "$(du -sh "$OUTPUT_DIR" | awk '{print $1}')"
