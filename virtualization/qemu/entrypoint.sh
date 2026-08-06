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
  -device virtio-rng-pci \
  -device virtio-net-pci,netdev=net0,romfile= \
  -netdev "$NETDEV" \
  -qmp "unix:$QMP_SOCKET,server=on,wait=off" \
  -display none \
  -monitor none \
  -serial stdio
