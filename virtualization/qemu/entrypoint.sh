#!/usr/bin/env bash
set -euo pipefail

STATE_DIR='/state'
BASE_DIR="$STATE_DIR/base"
CHECKPOINT_DIR="$STATE_DIR/checkpoints"
BASE_NAME='debian-12-generic-arm64.qcow2'
BASE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/$BASE_NAME"
SUMS_URL='https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS'
BASE_IMAGE="$BASE_DIR/$BASE_NAME"
ACTIVE_IMAGE="$STATE_DIR/active.qcow2"
BACKING_FILE="$STATE_DIR/backing-path"
SEED_IMAGE="$STATE_DIR/cloud-init-seed.img"
VARS_IMAGE="$STATE_DIR/AAVMF_VARS.fd"
EFI_HELPER_IMAGE="$STATE_DIR/efi-compat.raw"
EFI_HELPER_UUID_FILE="$STATE_DIR/efi-compat.partuuid"
GPT_HEAD="$BASE_DIR/gpt-head.raw"
QMP_SOCKET="$STATE_DIR/qmp.sock"
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
VM_DISK_SIZE="${VM_DISK_SIZE:-32G}"

mkdir -p "$BASE_DIR" "$CHECKPOINT_DIR"

if [ ! -s "$BASE_IMAGE" ]; then
  echo "Downloading official Debian 12 ARM64 image..."
  TMP_IMAGE="$BASE_IMAGE.part"
  TMP_SUMS="$BASE_DIR/SHA512SUMS.part"
  rm -f "$TMP_IMAGE" "$TMP_SUMS"
  curl --fail --location --retry 4 --output "$TMP_IMAGE" "$BASE_URL"
  curl --fail --location --retry 4 --output "$TMP_SUMS" "$SUMS_URL"

  EXPECTED="$(awk -v name="$BASE_NAME" '$2 == name || $2 == "*" name {print $1; exit}' "$TMP_SUMS")"
  [ -n "$EXPECTED" ] || {
    echo "No SHA-512 entry found for $BASE_NAME." >&2
    exit 1
  }
  printf '%s  %s\n' "$EXPECTED" "$TMP_IMAGE" | sha512sum -c -
  mv "$TMP_IMAGE" "$BASE_IMAGE"
  mv "$TMP_SUMS" "$BASE_DIR/SHA512SUMS"
fi

if [ ! -s "$SEED_IMAGE" ]; then
  cloud-localds "$SEED_IMAGE" \
    /opt/franzfon-lab/cloud-init/user-data \
    /opt/franzfon-lab/cloud-init/meta-data
fi

if [ ! -s "$VARS_IMAGE" ]; then
  cp /usr/share/AAVMF/AAVMF_VARS.fd "$VARS_IMAGE"
fi

if [ ! -s "$BACKING_FILE" ]; then
  printf '%s\n' "$BASE_IMAGE" > "$BACKING_FILE"
fi

BACKING_IMAGE="$(cat "$BACKING_FILE")"
[ -s "$BACKING_IMAGE" ] || {
  echo "Configured backing image does not exist: $BACKING_IMAGE" >&2
  exit 1
}

if [ ! -s "$ACTIVE_IMAGE" ]; then
  qemu-img create \
    -f qcow2 \
    -F qcow2 \
    -b "$BACKING_IMAGE" \
    "$ACTIVE_IMAGE" \
    "$VM_DISK_SIZE"
fi

# Debian's ARM64 cloud image mounts /boot/efi by PARTUUID. During the first
# boot, cloud-initramfs-growroot may rewrite the GPT while expanding partition
# 1 to the larger overlay. On some image revisions this changes the EFI
# partition GUID and systemd falls into emergency mode. Supply a tiny FAT EFI
# compatibility disk carrying the original partition-15 GUID so the fstab
# dependency remains resolvable. The real boot still comes from the Debian disk.
rm -f "$GPT_HEAD"
qemu-img dd \
  -f qcow2 \
  -O raw \
  bs=512 \
  count=34 \
  if="$BASE_IMAGE" \
  of="$GPT_HEAD" >/dev/null

EFI_PARTUUID="$(python3 - "$GPT_HEAD" <<'PY'
import struct
import sys
import uuid

path = sys.argv[1]
with open(path, 'rb') as handle:
    handle.seek(512)
    header = handle.read(92)
    if header[:8] != b'EFI PART':
        raise SystemExit('Debian image does not contain a readable GPT header')
    entries_lba = struct.unpack_from('<Q', header, 72)[0]
    entry_size = struct.unpack_from('<I', header, 84)[0]
    handle.seek(entries_lba * 512 + 14 * entry_size)
    entry = handle.read(entry_size)

if len(entry) < 32 or entry[:16] == b'\x00' * 16:
    raise SystemExit('Debian image has no GPT partition 15')
print(uuid.UUID(bytes_le=entry[16:32]))
PY
)"
rm -f "$GPT_HEAD"

STORED_EFI_PARTUUID="$(cat "$EFI_HELPER_UUID_FILE" 2>/dev/null || true)"
if [ ! -s "$EFI_HELPER_IMAGE" ] || [ "$STORED_EFI_PARTUUID" != "$EFI_PARTUUID" ]; then
  echo "Creating EFI compatibility disk for PARTUUID $EFI_PARTUUID..."
  rm -f "$EFI_HELPER_IMAGE" "$EFI_HELPER_UUID_FILE"
  truncate -s 64M "$EFI_HELPER_IMAGE"
  sgdisk \
    --clear \
    --new=1:2048:0 \
    --typecode=1:ef00 \
    --partition-guid=1:"$EFI_PARTUUID" \
    --change-name=1:FRANZFON-EFI \
    "$EFI_HELPER_IMAGE" >/dev/null
  mkfs.fat \
    -F 32 \
    -n FRANZFON_EFI \
    --offset 2048 \
    "$EFI_HELPER_IMAGE" >/dev/null
  printf '%s\n' "$EFI_PARTUUID" > "$EFI_HELPER_UUID_FILE"
fi

rm -f "$QMP_SOCKET"

NETDEV='user,id=net0,hostfwd=tcp:0.0.0.0:2222-:22,hostfwd=tcp:0.0.0.0:3000-:3000,hostfwd=udp:0.0.0.0:5060-:5060,hostfwd=tcp:0.0.0.0:8088-:8088'
for port in $(seq 10000 10020); do
  NETDEV+=",hostfwd=udp:0.0.0.0:${port}-:${port}"
done

cat <<EOF
Starting FRANZFON ARM64 lab
  CPUs:       $VM_CPUS
  Memory:     ${VM_MEMORY_MB} MiB
  Active:     $ACTIVE_IMAGE
  Backing:    $BACKING_IMAGE
  EFI helper: $EFI_PARTUUID
  SSH guest:  127.0.0.1:2222
  Web guest:  http://127.0.0.1:3000/
EOF

exec qemu-system-aarch64 \
  -name franzfon-arm64-lab \
  -machine virt,gic-version=3,highmem=on \
  -cpu max \
  -accel tcg,thread=multi \
  -smp "$VM_CPUS" \
  -m "$VM_MEMORY_MB" \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
  -drive if=pflash,format=raw,file="$VARS_IMAGE" \
  -drive if=virtio,format=qcow2,file="$ACTIVE_IMAGE",discard=unmap \
  -drive if=virtio,format=raw,readonly=on,file="$SEED_IMAGE" \
  -drive if=virtio,format=raw,file="$EFI_HELPER_IMAGE" \
  -device virtio-rng-pci \
  -device virtio-net-pci,netdev=net0,romfile= \
  -netdev "$NETDEV" \
  -qmp "unix:$QMP_SOCKET,server=on,wait=off" \
  -display none \
  -monitor none \
  -serial stdio
