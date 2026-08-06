#!/usr/bin/env bash
set -euo pipefail

APP_ROOT='/opt/franzfon'

usage() {
  cat <<'EOF'
Usage:
  sudo ./installer/franzfon-arm64-normalize-native-addons.sh [--app-root PATH]

Finds the native Node.js addons installed by npm, verifies every ELF addon as
AArch64 and creates the canonical better-sqlite3 path expected by the FRANZFON
bootstrap. No application code, license checks or runtime data are modified.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-root)
      [ "$#" -ge 2 ] || { echo 'Missing value for --app-root' >&2; exit 2; }
      APP_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
command -v readelf >/dev/null || { echo 'readelf is required. Install binutils.' >&2; exit 1; }

NODE_MODULES="$APP_ROOT/wizard/backend/node_modules"
[ -d "$NODE_MODULES" ] || { echo "Missing node_modules: $NODE_MODULES" >&2; exit 1; }

assert_aarch64_elf() {
  local target="$1"
  local machine
  machine="$(readelf -h "$target" 2>/dev/null | awk '$1 == "Machine:" {print $2}')"
  [ "$machine" = AArch64 ] || {
    echo "Expected AArch64 ELF, found '${machine:-unknown}': $target" >&2
    exit 1
  }
}

NATIVE_COUNT=0
while IFS= read -r -d '' addon; do
  assert_aarch64_elf "$addon"
  printf 'PASS  %s\n' "$addon"
  NATIVE_COUNT=$((NATIVE_COUNT + 1))
done < <(find -L "$NODE_MODULES" -type f -name '*.node' -print0)

[ "$NATIVE_COUNT" -gt 0 ] || {
  echo 'No native Node.js addon was found after npm installation.' >&2
  exit 1
}

ACTUAL_BETTER_SQLITE="$(find -L "$NODE_MODULES" -type f -name 'better_sqlite3.node' -print -quit)"
[ -n "$ACTUAL_BETTER_SQLITE" ] || {
  echo 'The better-sqlite3 native addon could not be located.' >&2
  exit 1
}
assert_aarch64_elf "$ACTUAL_BETTER_SQLITE"

CANONICAL="$NODE_MODULES/better-sqlite3/build/Release/better_sqlite3.node"
ACTUAL_REAL="$(realpath "$ACTUAL_BETTER_SQLITE")"

if [ -e "$CANONICAL" ]; then
  CANONICAL_REAL="$(realpath "$CANONICAL")"
  [ "$CANONICAL_REAL" = "$ACTUAL_REAL" ] || {
    echo "Canonical path points to a different file: $CANONICAL" >&2
    exit 1
  }
else
  install -d -m 0755 "$(dirname "$CANONICAL")"
  ln -s "$ACTUAL_REAL" "$CANONICAL"
fi

assert_aarch64_elf "$CANONICAL"
printf 'Native addons verified: %s\n' "$NATIVE_COUNT"
printf 'Canonical better-sqlite3 addon: %s -> %s\n' "$CANONICAL" "$ACTUAL_REAL"
