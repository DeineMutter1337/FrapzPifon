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

export FRANZFON_CONTRACT_ROOT="$ROOT"
export FRANZFON_CONTRACT_OUT="$OUT"
python3 - <<'PY'
from __future__ import annotations

import os
import pathlib
import re

root = pathlib.Path(os.environ["FRANZFON_CONTRACT_ROOT"])
out = pathlib.Path(os.environ["FRANZFON_CONTRACT_OUT"])
app_root = root / "opt/franzfon"
source_root = app_root / "wizard/backend/src"

env_assignment = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=")
process_env = re.compile(
    r"process\.env(?:\.([A-Za-z_][A-Za-z0-9_]*)|\[['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\])"
)

lines: list[str] = ["=== ENVIRONMENT FILE KEY NAMES ONLY ==="]
for env_file in sorted(app_root.rglob("*.env")) if app_root.exists() else []:
    lines.append(f"--- /{env_file.relative_to(root)} ---")
    keys: set[str] = set()
    try:
        for line in env_file.read_text(encoding="utf-8", errors="ignore").splitlines():
            match = env_assignment.match(line)
            if match:
                keys.add(match.group(1))
    except OSError:
        pass
    lines.extend(sorted(keys))

lines.extend(["", "=== PROCESS.ENV REFERENCES IN APPLICATION SOURCE ==="])
refs: set[str] = set()
if source_root.exists():
    for path in source_root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".js", ".mjs", ".cjs", ".ts"}:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for first, second in process_env.findall(text):
            refs.add(first or second)
lines.extend(sorted(refs))
(out / "environment-contract.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

DB="$ROOT/opt/franzfon/wizard/backend/data/franzfon.db"
{
  echo '=== SQLITE TABLES ==='
  if [ -f "$DB" ]; then
    sqlite3 -readonly "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
    echo
    echo '=== SQLITE COLUMNS ==='
    while IFS= read -r TABLE; do
      [ -n "$TABLE" ] || continue
      SAFE_TABLE="${TABLE//\'/\'\'}"
      echo "--- $TABLE ---"
      sqlite3 -readonly -separator $'\t' "$DB" "PRAGMA table_info('$SAFE_TABLE');" \
        | awk -F'\t' '{print $2 "\t" $3 "\tnotnull=" $4 "\tpk=" $6}'
    done < <(sqlite3 -readonly "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
  else
    echo 'Database file missing.'
  fi
} > "$OUT/sqlite-schema-contract.txt"

{
  echo '=== MARIADB DATABASE DIRECTORY NAMES ==='
  if [ -d "$ROOT/var/lib/mysql" ]; then
    sudo find "$ROOT/var/lib/mysql" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
      | grep -Ev '^(mysql|performance_schema|sys)$' | sort || true
  fi
  echo
  echo '=== NON-SYSTEM MARIADB TABLE FILE STEMS ==='
  if [ -d "$ROOT/var/lib/mysql" ]; then
    sudo find "$ROOT/var/lib/mysql" -mindepth 2 -maxdepth 2 -type f \
      \( -name '*.ibd' -o -name '*.frm' -o -name '*.MAD' -o -name '*.MAI' \) \
      -printf '%h/%f\n' 2>/dev/null \
      | sed "s#^$ROOT/var/lib/mysql/##; s/\.[^.]*$//" \
      | grep -Ev '^(mysql|performance_schema|sys)/' | sort -u || true
  fi
} > "$OUT/mariadb-layout-contract.txt"

{
  echo '=== ASTERISK CONFIG FILES ==='
  sudo find "$ROOT/etc/asterisk" \
    -path "$ROOT/etc/asterisk/keys" -prune -o \
    -maxdepth 2 -type f -printf '%P\n' 2>/dev/null | sort
  echo
  echo '=== ASTERISK INCLUDE GRAPH ==='
  while IFS= read -r -d '' CONF; do
    REL="${CONF#$ROOT/etc/asterisk/}"
    sudo awk -v source="$REL" '
      /^[[:space:]]*#(include|tryinclude)[[:space:]]+/ {
        target=$0
        sub(/^[[:space:]]*#(include|tryinclude)[[:space:]]+/, "", target)
        gsub(/["<>]/, "", target)
        printf "%s\t%s\n", source, target
      }
    ' "$CONF"
  done < <(
    sudo find "$ROOT/etc/asterisk" \
      -path "$ROOT/etc/asterisk/keys" -prune -o \
      -type f \( -name '*.conf' -o -name '*.conf.inc' \) -print0 2>/dev/null
  ) | sort -u
} > "$OUT/asterisk-config-contract.txt"

{
  echo '=== REQUIRED PATHS AND COMMANDS FROM SERVICE UNITS ==='
  shopt -s nullglob
  UNITS=(
    "$ROOT"/etc/systemd/system/franzfon*.service
    "$ROOT"/etc/systemd/system/asterisk.service
  )
  for UNIT in "${UNITS[@]}"; do
    [ -f "$UNIT" ] || continue
    echo "--- ${UNIT#$ROOT} ---"
    grep -E '^(WorkingDirectory|EnvironmentFile|ExecStart|ExecStartPre|ExecStartPost)=' "$UNIT" \
      | sed -E 's#(PASSWORD|PASS|TOKEN|SECRET|KEY)=([^[:space:]]+)#\1=[REDACTED]#Ig' || true
  done
  shopt -u nullglob
} > "$OUT/service-contract.txt"

{
  echo 'Configuration contract audit completed.'
  find "$OUT" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort
} > "$OUT/summary.txt"

cleanup
trap - EXIT
