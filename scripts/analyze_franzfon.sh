#!/usr/bin/env bash
set -uo pipefail

URL='https://franzfon.de/updates/proxmox/vzdump-qemu-900-2026_08_04-01_09_26.vma.zst'
WORK="${GITHUB_WORKSPACE:-$PWD}"
EXTRACTED="$WORK/extracted"
OUT="$WORK/report"
MNT="$WORK/franzfon-root"

mkdir -p "$EXTRACTED" "$OUT" "$MNT"

stage() {
  printf '\n===== %s =====\n' "$1"
}

fail() {
  echo "ERROR: $*" | tee -a "$OUT/error.txt" >&2
  exit 1
}

stage 'ENVIRONMENT'
{
  uname -a
  df -hT
  python3 --version
  guestfish --version || true
  virt-filesystems --version || true
} | tee "$OUT/runner-environment.txt"

stage 'STREAM EXTRACT VMA'
python3 "$WORK/scripts/stream_vma_extract.py" "$URL" "$EXTRACTED" || fail 'VMA extraction failed'

{
  echo '=== EXTRACTED FILES ==='
  find "$EXTRACTED" -maxdepth 1 -type f -printf '%s bytes\t%p\n' | sort -nr
  echo
  echo '=== PHYSICAL / APPARENT DISK USAGE ==='
  du -h "$EXTRACTED"/* 2>/dev/null || true
  du -h --apparent-size "$EXTRACTED"/* 2>/dev/null || true
  echo
  df -hT
} | tee "$OUT/extraction.txt"

RAW="$(find "$EXTRACTED" -maxdepth 1 -type f -size +16M -printf '%s\t%p\n' \
  | sort -nr | head -n1 | cut -f2-)"
[ -n "$RAW" ] || fail 'No extracted virtual disk candidate found'

echo "$RAW" > "$OUT/selected-disk.txt"
{
  echo "Selected virtual disk: $RAW"
  file "$RAW" || true
  stat "$RAW" || true
} | tee "$OUT/disk-file.txt"

stage 'LIBGUESTFS INVENTORY'
export LIBGUESTFS_BACKEND=direct
export LIBGUESTFS_DEBUG=0
export LIBGUESTFS_TRACE=0

virt-filesystems -a "$RAW" --all --long --uuid -h > "$OUT/virt-filesystems.txt" 2>&1 || true
virt-inspector -a "$RAW" > "$OUT/virt-inspector.xml" 2> "$OUT/virt-inspector-error.txt" || true
cat "$OUT/virt-filesystems.txt"

stage 'MOUNT GUEST READ-ONLY'
MOUNTED=0
if guestmount --ro -a "$RAW" -i "$MNT" > "$OUT/guestmount.txt" 2>&1; then
  MOUNTED=1
else
  echo 'Automatic inspection mount failed. Trying candidate filesystems.' | tee -a "$OUT/guestmount.txt"

  mapfile -t FILESYSTEMS < <(guestfish --ro -a "$RAW" run : list-filesystems 2>> "$OUT/guestmount.txt" \
    | awk -F': ' '$2 ~ /^(ext2|ext3|ext4|xfs|btrfs)$/ {print $1}')

  for FS in "${FILESYSTEMS[@]:-}"; do
    [ -n "$FS" ] || continue
    echo "Trying filesystem $FS" | tee -a "$OUT/guestmount.txt"
    if guestmount --ro -a "$RAW" -m "$FS" "$MNT" >> "$OUT/guestmount.txt" 2>&1; then
      if [ -f "$MNT/etc/os-release" ]; then
        MOUNTED=1
        echo "Mounted root candidate $FS" | tee -a "$OUT/guestmount.txt"
        break
      fi
      guestunmount "$MNT" 2>/dev/null || fusermount3 -u "$MNT" 2>/dev/null || true
    fi
  done
fi

[ "$MOUNTED" -eq 1 ] || fail 'Could not mount a Linux root filesystem with libguestfs'
[ -f "$MNT/etc/os-release" ] || fail 'Mounted filesystem is not the Linux root'

cleanup() {
  guestunmount "$MNT" 2>/dev/null || fusermount3 -u "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

ROOT="$MNT"

stage 'SYSTEM INVENTORY'
{
  echo '=== OS RELEASE ==='
  cat "$ROOT/etc/os-release" 2>/dev/null || true
  echo
  echo '=== DPKG ARCHITECTURES ==='
  cat "$ROOT/var/lib/dpkg/arch" 2>/dev/null || true
  echo
  echo '=== HOSTNAME / MACHINE INFO ==='
  sed -n '1,20p' "$ROOT/etc/hostname" 2>/dev/null || true
  echo
  echo '=== BOOT FILES ==='
  find "$ROOT/boot" -maxdepth 2 -type f -printf '%P\t%s bytes\n' 2>/dev/null | sort | head -n 2000
} > "$OUT/system.txt"

if [ -f "$ROOT/var/lib/dpkg/status" ]; then
  awk '/^Package:|^Version:|^Architecture:/{printf "%s ",$0} /^$/{print ""}' \
    "$ROOT/var/lib/dpkg/status" > "$OUT/packages.txt"
fi

{
  echo '=== IMPORTANT PACKAGES ==='
  grep -Ei 'Package: (asterisk|nodejs|npm|python|php|mariadb|mysql|postgresql|sqlite|nginx|apache|docker|dotnet|mono|openjdk)' \
    "$OUT/packages.txt" 2>/dev/null || true
  echo
  echo '=== RUNTIME EXECUTABLES ==='
  for p in usr/sbin/asterisk usr/bin/node usr/bin/npm usr/bin/python3 usr/bin/php usr/bin/java usr/bin/dotnet usr/sbin/nginx usr/sbin/apache2; do
    [ -e "$ROOT/$p" ] && file "$ROOT/$p"
  done
} > "$OUT/important-packages-runtimes.txt"

stage 'SERVICE INVENTORY'
{
  echo '=== SERVICE FILE PATHS ==='
  find "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system" -type f \
    \( -name '*.service' -o -name '*.timer' -o -name '*.socket' \) -print 2>/dev/null | sort
  echo
  echo '=== FRANZFON / ASTERISK / WEB / DATABASE DIRECTIVES ==='
  grep -RHIEn --include='*.service' --include='*.timer' --include='*.socket' \
    'franz|wizard|asterisk|node|nginx|apache|maria|mysql|postgres|ExecStart|ExecStartPre|ExecStartPost|WorkingDirectory|User=|Group=|EnvironmentFile=' \
    "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system" 2>/dev/null || true
} > "$OUT/services.txt"

stage 'APPLICATION TREE AND ARCHITECTURES'
{
  echo '=== FRANZFON-NAMED PATHS ==='
  find "$ROOT" -xdev \( -iname '*franzfon*' -o -iname '*franz*fon*' \) -printf '%y\t%p\t%s\n' 2>/dev/null | head -n 10000
  echo
  echo '=== RELEVANT TREES ==='
  for d in opt srv usr/local var/www etc/asterisk var/lib/asterisk var/spool/asterisk; do
    [ -e "$ROOT/$d" ] || continue
    echo "--- /$d ---"
    find "$ROOT/$d" -maxdepth 6 -printf '%y\t%p\t%s\n' 2>/dev/null | head -n 20000
  done
} > "$OUT/relevant-tree.txt"

{
  echo '=== NATIVE BINARIES AND SCRIPTS IN APPLICATION LOCATIONS ==='
  find "$ROOT/opt" "$ROOT/srv" "$ROOT/usr/local" "$ROOT/var/www" \
    -xdev -type f -size -250M -print0 2>/dev/null \
    | xargs -0 -r file 2>/dev/null \
    | grep -Ei 'ELF|script|Java|Mono|\.NET|WebAssembly|Mach-O|PE32' \
    | head -n 30000 || true
} > "$OUT/binaries.txt"

{
  echo '=== RUNTIME / BUILD MARKERS ==='
  find "$ROOT/opt" "$ROOT/srv" "$ROOT/usr/local" "$ROOT/var/www" \
    -type f \( -name package.json -o -name yarn.lock -o -name pnpm-lock.yaml \
    -o -name package-lock.json -o -name requirements.txt -o -name pyproject.toml \
    -o -name composer.json -o -name '*.jar' -o -name '*.dll' \
    -o -name '*.runtimeconfig.json' -o -name go.mod -o -name Cargo.toml \) \
    -printf '%p\t%s\n' 2>/dev/null | sort | head -n 10000
} > "$OUT/runtimes.txt"

stage 'DATABASE / ASTERISK / UPDATE INVENTORY'
{
  echo '=== DATABASE FILE MARKERS ==='
  find "$ROOT/opt" "$ROOT/srv" "$ROOT/usr/local" "$ROOT/var/www" "$ROOT/var/lib" \
    -maxdepth 6 -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \
    -o -name 'PG_VERSION' -o -name 'ibdata1' \) -printf '%p\t%s\n' 2>/dev/null \
    | sort | head -n 10000
  echo
  echo '=== DATABASE CONFIG / SERVICE REFERENCES ==='
  grep -RIlE 'sqlite|postgres|mariadb|mysql' \
    "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system" "$ROOT/etc" 2>/dev/null \
    | head -n 5000 || true
} > "$OUT/databases.txt"

{
  echo '=== ASTERISK CONFIGURATION FILE LIST ==='
  find "$ROOT/etc/asterisk" -maxdepth 3 -type f -printf '%P\t%s\n' 2>/dev/null | sort | head -n 10000
  echo
  echo '=== ASTERISK MODULE FILE LIST ==='
  find "$ROOT/usr/lib" "$ROOT/usr/lib64" -path '*asterisk*' -type f -printf '%p\t%s\n' 2>/dev/null \
    | sort | head -n 20000
  echo
  echo '=== ASTERISK EXECUTABLE ==='
  [ -e "$ROOT/usr/sbin/asterisk" ] && file "$ROOT/usr/sbin/asterisk" || true
} > "$OUT/asterisk.txt"

{
  echo '=== UPDATE / BACKUP PATH REFERENCES ==='
  grep -RIlE 'franzfon\.de|update|upgrade|backup|restore' \
    "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system" "$ROOT/etc/cron.d" \
    "$ROOT/opt" "$ROOT/srv" "$ROOT/usr/local" 2>/dev/null | head -n 10000 || true
} > "$OUT/update-backup.txt"

stage 'SANITIZE REPORT'
# Redact common inline secret assignments and local machine identifiers.
find "$OUT" -type f -name '*.txt' -print0 | while IFS= read -r -d '' F; do
  sed -ri \
    -e 's#([A-Za-z0-9_]*(PASSWORD|PASS|TOKEN|SECRET|PRIVATE_KEY|API_KEY)[A-Za-z0-9_]*[=:])[[:space:]]*[^[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#(Authorization:[[:space:]]*(Bearer|Basic))[[:space:]]+[^[:space:]]+#\1 [REDACTED]#Ig' \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    "$F" || true
done

rm -f "$OUT/virt-inspector.xml"

{
  echo '=== REPORT FILES ==='
  find "$OUT" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort
  echo
  echo 'Analysis completed successfully.'
} | tee "$OUT/summary.txt"

cleanup
trap - EXIT
