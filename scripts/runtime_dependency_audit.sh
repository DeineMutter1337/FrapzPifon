#!/usr/bin/env bash
set -euo pipefail

URL='https://franzfon.de/updates/proxmox/vzdump-qemu-900-2026_08_04-01_09_26.vma.zst'
WORK="${GITHUB_WORKSPACE:-$PWD}"
EXTRACTED="$WORK/extracted-runtime-audit"
MNT="$WORK/franzfon-runtime-root"
OUT="$WORK/runtime-dependency-report"
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

export FRANZFON_AUDIT_ROOT="$MNT"
export FRANZFON_AUDIT_OUT="$OUT"
python3 - <<'PY'
from __future__ import annotations

import collections
import os
import pathlib
import re

root = pathlib.Path(os.environ["FRANZFON_AUDIT_ROOT"])
out = pathlib.Path(os.environ["FRANZFON_AUDIT_OUT"])

scan_roots = [
    root / "opt/franzfon/wizard/backend/src",
    root / "opt/franzfon/wizard/backend/agi",
    root / "opt/franzfon/wizard/backend/scripts",
    root / "opt/franzfon/scripts",
    root / "usr/local/sbin",
]

extensions = {".js", ".mjs", ".cjs", ".sh", ".py", ".service"}
command_names = {
    "fwconsole", "asterisk", "systemctl", "service", "mysql", "mariadb",
    "mysqldump", "sqlite3", "redis-cli", "ffmpeg", "ffprobe", "sox",
    "curl", "wget", "python3", "node", "npm", "tar", "rsync", "openssl",
    "journalctl", "ss", "ip", "hostnamectl", "timedatectl", "reboot",
    "shutdown", "pnp_server", "sendmail", "postfix", "convert", "magick",
}

command_re = re.compile(r"(?<![A-Za-z0-9_.-])(" + "|".join(sorted(map(re.escape, command_names), key=len, reverse=True)) + r")(?![A-Za-z0-9_.-])")
absolute_command_re = re.compile(r"/(?:usr/(?:s?bin|local/(?:s?bin))|s?bin)/[A-Za-z0-9_.+-]+")
path_markers = [
    "/etc/asterisk", "/var/lib/asterisk", "/var/spool/asterisk",
    "/var/log/asterisk", "/run/asterisk", "/var/www/html/admin",
    "/etc/freepbx.conf", "/etc/amportal.conf", "/usr/local/bin",
    "/opt/franzfon", "/var/lib/mysql", "/etc/systemd/system",
]

command_counts: collections.Counter[str] = collections.Counter()
command_files: dict[str, set[str]] = collections.defaultdict(set)
path_counts: collections.Counter[str] = collections.Counter()
path_files: dict[str, set[str]] = collections.defaultdict(set)
scanned_files = 0

for base in scan_roots:
    if not base.exists():
        continue
    for path in base.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in extensions:
            continue
        try:
            if path.stat().st_size > 2_000_000:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        scanned_files += 1
        rel = "/" + str(path.relative_to(root))
        for match in command_re.findall(text):
            command_counts[match] += 1
            command_files[match].add(rel)
        for match in absolute_command_re.findall(text):
            command_counts[match] += 1
            command_files[match].add(rel)
        for marker in path_markers:
            count = text.count(marker)
            if count:
                path_counts[marker] += count
                path_files[marker].add(rel)

with (out / "external-commands.txt").open("w", encoding="utf-8") as f:
    f.write(f"SCANNED_FILES={scanned_files}\n")
    f.write("COMMAND\tREFERENCES\tFILES\n")
    for command, count in command_counts.most_common():
        files = ",".join(sorted(command_files[command]))
        f.write(f"{command}\t{count}\t{files}\n")

with (out / "path-dependencies.txt").open("w", encoding="utf-8") as f:
    f.write("PATH\tREFERENCES\tFILES\n")
    for marker, count in path_counts.most_common():
        files = ",".join(sorted(path_files[marker]))
        f.write(f"{marker}\t{count}\t{files}\n")

freepbx_terms = ["fwconsole", "/var/www/html/admin", "/etc/freepbx.conf", "/etc/amportal.conf"]
with (out / "freepbx-dependency-summary.txt").open("w", encoding="utf-8") as f:
    total = 0
    for term in freepbx_terms:
        count = command_counts.get(term, 0) + path_counts.get(term, 0)
        total += count
        files = sorted(command_files.get(term, set()) | path_files.get(term, set()))
        f.write(f"{term}\t{count}\t{','.join(files)}\n")
    f.write(f"TOTAL_FREEPBX_REFERENCES={total}\n")
PY

{
  echo '=== CANDIDATE RUNTIME EXECUTABLES ==='
  for P in \
    usr/sbin/asterisk \
    usr/local/bin/fwconsole \
    usr/local/bin/pnp_server \
    usr/bin/ffmpeg \
    usr/bin/sox \
    usr/bin/mysql \
    usr/bin/mysqldump \
    usr/bin/sqlite3 \
    usr/bin/redis-cli; do
    if [ -e "$MNT/$P" ]; then
      printf '/%s\t' "$P"
      file -b "$MNT/$P" 2>/dev/null || true
    else
      printf '/%s\tMISSING\n' "$P"
    fi
  done
} > "$OUT/runtime-executables.txt"

{
  echo '=== SERVICE ORDER ==='
  for U in \
    "$MNT/etc/systemd/system/franzfon-wizard.service" \
    "$MNT/etc/systemd/system/franzfon-setup.service" \
    "$MNT/etc/systemd/system/asterisk.service" \
    "$MNT/lib/systemd/system/freepbx.service" \
    "$MNT/etc/systemd/system/sangoma-pnpd.service"; do
    [ -f "$U" ] || continue
    echo "--- ${U#$MNT} ---"
    grep -E '^(After|Before|Wants|Requires|ExecStart|WorkingDirectory|EnvironmentFile)=' "$U" \
      | sed -E 's#(EnvironmentFile=).*#\1[PATH]#' || true
  done
} > "$OUT/service-dependencies.txt"

{
  echo 'Runtime dependency audit completed.'
  find "$OUT" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort
} > "$OUT/summary.txt"

cleanup
trap - EXIT
