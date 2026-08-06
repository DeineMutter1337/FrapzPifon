#!/usr/bin/env bash
set -euo pipefail

URL='https://franzfon.de/updates/proxmox/vzdump-qemu-900-2026_08_04-01_09_26.vma.zst'
WORK="${GITHUB_WORKSPACE:-$PWD}"
EXTRACTED="$WORK/extracted-arm64-node"
MNT="$WORK/franzfon-arm64-node-root"
PAYLOAD="$WORK/arm64-smoke/payload"
REPORT="$WORK/arm64-smoke-report"
LOOP=''
MOUNTED=0

mkdir -p "$EXTRACTED" "$MNT" "$PAYLOAD" "$REPORT"

cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    sudo umount "$MNT" 2>/dev/null || true
  fi
  if [ -n "$LOOP" ]; then
    sudo losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

python3 "$WORK/scripts/stream_vma_extract.py" "$URL" "$EXTRACTED"
RAW="$(find "$EXTRACTED" -maxdepth 1 -type f -size +16M -printf '%s\t%p\n' | sort -nr | head -n1 | cut -f2-)"
[ -n "$RAW" ] || { echo 'No extracted disk image found' >&2; exit 1; }

LOOP="$(sudo losetup --find --show --partscan --read-only "$RAW")"
sudo udevadm settle 2>/dev/null || true
sleep 2

ROOT_LINE="$(sudo lsblk -bprno PATH,FSTYPE,SIZE "$LOOP" 2>/dev/null \
  | awk '$2 ~ /^(ext2|ext3|ext4|xfs|btrfs)$/ {print $3 "\t" $1 "\t" $2}' \
  | sort -nr | head -n1)"
ROOTDEV="$(printf '%s' "$ROOT_LINE" | cut -f2)"
ROOTFS="$(printf '%s' "$ROOT_LINE" | cut -f3)"
[ -n "$ROOTDEV" ] || { echo 'No Linux root filesystem found' >&2; exit 1; }

case "$ROOTFS" in
  ext2|ext3|ext4)
    sudo mount -o ro,noload "$ROOTDEV" "$MNT" 2>/dev/null || sudo mount -o ro "$ROOTDEV" "$MNT"
    ;;
  xfs) sudo mount -o ro,norecovery "$ROOTDEV" "$MNT" ;;
  btrfs) sudo mount -o ro "$ROOTDEV" "$MNT" ;;
  *) echo "Unsupported filesystem: $ROOTFS" >&2; exit 1 ;;
esac
MOUNTED=1

BACKEND_SRC="$MNT/opt/franzfon/wizard/backend"
FRONTEND_SRC="$MNT/opt/franzfon/wizard/frontend"
[ -f "$BACKEND_SRC/package.json" ] || { echo 'Backend package.json missing' >&2; exit 1; }
[ -f "$FRONTEND_SRC/package.json" ] || { echo 'Frontend package.json missing' >&2; exit 1; }

rm -rf "$PAYLOAD/backend" "$PAYLOAD/frontend"
mkdir -p "$PAYLOAD/backend" "$PAYLOAD/frontend"

# Copy only architecture-independent application/build inputs. Runtime data,
# credentials, backups and pre-existing x86 node_modules remain in the image.
sudo rsync -a \
  --exclude='node_modules/' \
  --exclude='data/' \
  --exclude='backups/' \
  --exclude='*.env' \
  --exclude='*.db' \
  --exclude='*.db-shm' \
  --exclude='*.db-wal' \
  "$BACKEND_SRC/" "$PAYLOAD/backend/"

sudo rsync -a \
  --exclude='node_modules/' \
  --exclude='.astro/' \
  --exclude='*.env' \
  "$FRONTEND_SRC/" "$PAYLOAD/frontend/"

sudo chown -R "$(id -u):$(id -g)" "$PAYLOAD"

{
  echo '=== PAYLOAD CONTENT ==='
  du -h -d 2 "$PAYLOAD" | sort -h
  echo
  echo '=== BACKEND MANIFEST HASHES ==='
  sha256sum "$PAYLOAD/backend/package.json" "$PAYLOAD/backend/package-lock.json"
  echo
  echo '=== FRONTEND MANIFEST HASHES ==='
  sha256sum "$PAYLOAD/frontend/package.json" "$PAYLOAD/frontend/package-lock.json"
  echo
  echo 'No runtime databases, env files, backups or node_modules were copied.'
} > "$REPORT/payload-preparation.txt"

cleanup
trap - EXIT
