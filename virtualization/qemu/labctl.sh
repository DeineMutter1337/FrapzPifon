#!/usr/bin/env bash
set -euo pipefail

STATE_DIR='/state'
BASE_IMAGE="$STATE_DIR/base/debian-12-generic-arm64.qcow2"
ACTIVE_IMAGE="$STATE_DIR/active.qcow2"
BACKING_FILE="$STATE_DIR/backing-path"
CHECKPOINT_DIR="$STATE_DIR/checkpoints"
VARS_IMAGE="$STATE_DIR/AAVMF_VARS.fd"
QMP_SOCKET="$STATE_DIR/qmp.sock"
VARS_TEMPLATE='/usr/share/AAVMF/AAVMF_VARS.fd'

usage() {
  cat <<'EOF'
Usage:
  labctl poweroff
  labctl status
  labctl checkpoint NAME
  labctl restore NAME
  labctl reset

Checkpoint and restore commands must be run while the QEMU VM is stopped.
EOF
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

qmp_responds() {
  [ -S "$QMP_SOCKET" ] || return 1
  printf '{"execute":"qmp_capabilities"}\n{"execute":"query-status"}\n' \
    | socat -T 2 - "UNIX-CONNECT:$QMP_SOCKET" >/dev/null 2>&1
}

require_stopped() {
  if qmp_responds; then
    echo 'The VM appears to be running. Power it off before changing disk state.' >&2
    exit 1
  fi
  rm -f "$QMP_SOCKET"
}

command="${1:-}"
case "$command" in
  poweroff)
    qmp_responds || { echo 'QMP is unavailable; the VM may already be stopped.' >&2; exit 1; }
    printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n' \
      | socat -T 2 - "UNIX-CONNECT:$QMP_SOCKET" >/dev/null
    echo 'ACPI power-off requested.'
    ;;

  status)
    echo "VM running: $(qmp_responds && echo yes || echo no)"
    echo "Backing image: $(cat "$BACKING_FILE" 2>/dev/null || echo unset)"
    if [ -s "$ACTIVE_IMAGE" ]; then
      qemu-img info "$ACTIVE_IMAGE"
    else
      echo 'Active overlay: not created'
    fi
    echo
    echo 'Checkpoints:'
    find "$CHECKPOINT_DIR" -maxdepth 1 -type f -name '*.qcow2' -printf '  %f\n' 2>/dev/null | sort || true
    ;;

  checkpoint)
    name="${2:-}"
    valid_name "$name" || { echo 'Checkpoint name may contain only letters, numbers, dot, underscore and dash.' >&2; exit 2; }
    require_stopped
    [ -s "$ACTIVE_IMAGE" ] || { echo 'No active VM disk exists.' >&2; exit 1; }
    mkdir -p "$CHECKPOINT_DIR"
    target="$CHECKPOINT_DIR/$name.qcow2"
    target_vars="$CHECKPOINT_DIR/$name.vars.fd"
    [ ! -e "$target" ] || { echo "Checkpoint already exists: $name" >&2; exit 1; }

    qemu-img check "$ACTIVE_IMAGE"
    qemu-img convert -p -O qcow2 "$ACTIVE_IMAGE" "$target.part"
    mv "$target.part" "$target"
    cp "$VARS_IMAGE" "$target_vars"
    printf '%s\n' "$target" > "$BACKING_FILE"
    rm -f "$ACTIVE_IMAGE"
    echo "Checkpoint created and selected: $name"
    ;;

  restore)
    name="${2:-}"
    valid_name "$name" || { echo 'Checkpoint name may contain only letters, numbers, dot, underscore and dash.' >&2; exit 2; }
    require_stopped
    target="$CHECKPOINT_DIR/$name.qcow2"
    target_vars="$CHECKPOINT_DIR/$name.vars.fd"
    [ -s "$target" ] || { echo "Checkpoint does not exist: $name" >&2; exit 1; }

    printf '%s\n' "$target" > "$BACKING_FILE"
    rm -f "$ACTIVE_IMAGE"
    if [ -s "$target_vars" ]; then
      cp "$target_vars" "$VARS_IMAGE"
    else
      cp "$VARS_TEMPLATE" "$VARS_IMAGE"
    fi
    echo "Checkpoint selected: $name"
    ;;

  reset)
    require_stopped
    [ -s "$BASE_IMAGE" ] || { echo 'Debian base image is not available yet.' >&2; exit 1; }
    printf '%s\n' "$BASE_IMAGE" > "$BACKING_FILE"
    rm -f "$ACTIVE_IMAGE" "$VARS_IMAGE"
    echo 'VM reset to the clean Debian base image. Existing checkpoints were kept.'
    ;;

  -h|--help|'')
    usage
    ;;

  *)
    echo "Unknown command: $command" >&2
    usage >&2
    exit 2
    ;;
esac
