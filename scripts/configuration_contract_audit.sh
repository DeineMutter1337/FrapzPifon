#!/usr/bin/env bash
set -euo pipefail

URL='https://franzfon.de/updates/proxmox/vzdump-qemu-900-2026_08_04-01_09_26.vma.zst'
WORK="${GITHUB_WORKSPACE:-$PWD}"
EXTRACTED="$WORK/extracted-config-contract"
MNT="$WORK/franzfon-config-root"
OUT="$WORK/config-contract-report"
LOOP=''
MOUNTED=0

mkdir -p "$EXTRACTED" "$MNT" "$OUT"
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then sudo umount "$MNT" 2>/dev/null || true; fi
  if [ -n "$LOOP" ]; then sudo losetup -d "$LOOP" 2>/dev/null || true; fi
}
trap cleanup EXIT

python3 "$WORK/scripts/stream_vma_extract.py" "$URL" "$EXTRACTED"
RAW="$(find "$EXTRACTED" -maxdepth 1 -type f -size +16M -printf '%s\t%p\n' | sort -nr | head -n1 | cut -f2-)"
[ -n "$RAW" ] || { echo 'No disk image found' >&2; exit 1; }
LOOP="$(sudo losetup --find --show --partscan --read-only "$RAW")"
sudo udevadm settle 2>/dev/null || true
sleep 2
ROOT_LINE="$(sudo lsblk -bprno PATH,FSTYPE,SIZE "$LOOP" 2>/dev/null \
  | awk '$2 ~ /^(ext2|ext3|ext4|xfs|btrfs)$/ {print $3 "\t" $1 "\t" $2}' \
  | sort -nr | head -n1)"
ROOTDEV="$(printf '%s' "$ROOT_LINE" | cut -f2)"
ROOTFS="$(printf '%s' "$ROOT_LINE" | cut -f3)"
[ -n "$ROOTDEV" ] || { echo 'No root filesystem found' >&2; exit 1; }
case "$ROOTFS" in
  ext2|ext3|ext4) sudo mount -o ro,noload "$ROOTDEV" "$MNT" 2>/dev/null || sudo mount -o ro "$ROOTDEV" "$MNT" ;;
  xfs) sudo mount -o ro,norecovery "$ROOTDEV" "$MNT" ;;
  btrfs) sudo mount -o ro "$ROOTDEV" "$MNT" ;;
  *) echo "Unsupported filesystem: $ROOTFS" >&2; exit 1 ;;
esac
MOUNTED=1
ROOT="$MNT"

{
  echo '=== ENVIRONMENT FILE KEY NAMES ONLY ==='
  while IFS= read -r -d '' ENVFILE; do
    echo "--- ${ENVFILE#$ROOT} ---"
    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$ENVFILE" | sort -u
  done < <(find "$ROOT/opt/franzfon" -type f -name '*.env' -print0 2>/dev/null || true)
  echo
  echo '=== PROCESS.ENV REFERENCES IN APPLICATION SOURCE ==='
  grep -RhoE 'process\.env\.[A-Za-z_][A-Za-z0-9_]*|process\.env\[["'"'][A-Za-z_][A-Za-z0-9_]*["'"']\]' \
    "$ROOT/opt/franzfon/wizard/backend/src" 2>/dev/null \
    | sed -E 's/^process\.env\.//; s/^process\.env\[["'"']([^"'"']+)["'"']\]$/\1/' \
    | sort -u || true
} > "$OUT/environment-contract.txt"

DB="$ROOT/opt/franzfon/wizard/backend/data/franzfon.db"
{
  echo '=== SQLITE TABLES ==='
  if [ -f "$DB" ]; then
    sqlite3 -readonly "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
    echo
    echo '=== SQLITE COLUMNS ==='
    while IFS= read -r TABLE; do
      [ -n "$TABLE" ] || continue
      echo "--- $TABLE ---"
      sqlite3 -readonly -separator $'\t' "$DB" "PRAGMA table_info('$TABLE');" \
        | awk -F'\t' '{print $2 "\t" $3 "\tnotnull=" $4 "\tpk=" $6}'
    done < <(sqlite3 -readonly "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
  else
    echo 'Database file missing.'
  fi
} > "$OUT/sqlite-schema-contract.txt"

{
  echo '=== MARIADB DATABASE DIRECTORY NAMES ==='
  if [ -d "$ROOT/var/lib/mysql" ]; then
    find "$ROOT/var/lib/mysql" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
      | grep -Ev '^(mysql|performance_schema|sys)$' | sort || true
  fi
  echo
  echo '=== NON-SYSTEM MARIADB TABLE FILE STEMS ==='
  if [ -d "$ROOT/var/lib/mysql" ]; then
    find "$ROOT/var/lib/mysql" -mindepth 2 -maxdepth 2 -type f \
      \( -name '*.ibd' -o -name '*.frm' -o -name '*.MAD' -o -name '*.MAI' \) \
      -printf '%h/%f\n' \
      | sed "s#^$ROOT/var/lib/mysql/##; s/\.[^.]*$//" \
      | grep -Ev '^(mysql|performance_schema|sys)/' | sort -u || true
  fi
} > "$OUT/mariadb-layout-contract.txt"

{
  echo '=== ASTERISK CONFIG FILES ==='
  find "$ROOT/etc/asterisk" -maxdepth 2 -type f -printf '%P\n' 2>/dev/null | sort
  echo
  echo '=== ASTERISK INCLUDE GRAPH ==='
  grep -RHnE '^[[:space:]]*#(include|tryinclude)[[:space:]]+' "$ROOT/etc/asterisk" 2>/dev/null \
    | sed "s#$ROOT/etc/asterisk/##" \
    | sed -E 's#:[0-9]+:.*#\tINCLUDES_CONFIG#' \
    | sort -u || true
} > "$OUT/asterisk-config-contract.txt"

{
  echo '=== REQUIRED FILE/DIRECTORY PATHS FROM SERVICE UNITS ==='
  grep -RhoE '(WorkingDirectory|EnvironmentFile|ExecStart)=([^[:space:]]+)' \
    "$ROOT/etc/systemd/system"/franzfon*.service \
    "$ROOT/etc/systemd/system/asterisk.service" 2>/dev/null \
    | sed -E 's#=.*#=[PATH_OR_COMMAND]#' | sort -u || true
} > "$OUT/service-contract.txt"

{
  echo 'Configuration contract audit completed.'
  find "$OUT" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort
} > "$OUT/summary.txt"

cleanup
trap - EXIT
