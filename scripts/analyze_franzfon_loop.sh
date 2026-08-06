#!/usr/bin/env bash
set -uo pipefail

URL='https://franzfon.de/updates/proxmox/vzdump-qemu-900-2026_08_04-01_09_26.vma.zst'
WORK="${GITHUB_WORKSPACE:-$PWD}"
EXTRACTED="$WORK/extracted"
OUT="$WORK/report"
MNT="$WORK/franzfon-root"
LOOP=''
MOUNTED=0
VGS=()

mkdir -p "$EXTRACTED" "$OUT" "$MNT"

stage() { printf '\n===== %s =====\n' "$1"; }
fail() { echo "ERROR: $*" | tee -a "$OUT/error.txt" >&2; exit 1; }

cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    sudo umount "$MNT" 2>/dev/null || true
  fi
  for VG in "${VGS[@]:-}"; do
    [ -n "$VG" ] && sudo vgchange -an "$VG" 2>/dev/null || true
  done
  if [ -n "$LOOP" ]; then
    sudo losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

stage 'ENVIRONMENT'
{
  uname -a
  df -hT
  python3 --version
  losetup --version | head -n1
  lvm version 2>/dev/null | head -n8 || true
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

stage 'PARTITION TABLE'
{
  echo '=== FDISK ==='
  sudo fdisk -l "$RAW" || true
  echo
  echo '=== PARTED ==='
  sudo parted -s "$RAW" unit B print || true
} | tee "$OUT/partition-table.txt"

stage 'ATTACH READ-ONLY LOOP DEVICE'
sudo modprobe loop 2>/dev/null || true
LOOP="$(sudo losetup --find --show --partscan --read-only "$RAW")" || fail 'Could not attach image to a loop device'
echo "$LOOP" > "$OUT/loop-device.txt"
sudo partprobe "$LOOP" 2>/dev/null || true
sudo udevadm settle 2>/dev/null || true
sleep 2

sudo lsblk -b -o NAME,PATH,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,RO,MOUNTPOINTS "$LOOP" \
  | tee "$OUT/lsblk-before-lvm.txt"

stage 'DISCOVER LVM IF PRESENT'
LVM_CFG='devices { filter = [ "a|/dev/loop.*|", "r|.*|" ] }'
while IFS= read -r PART; do
  [ -b "$PART" ] || continue
  TYPE="$(sudo blkid -o value -s TYPE "$PART" 2>/dev/null || true)"
  if [ "$TYPE" = 'LVM2_member' ]; then
    echo "Scanning LVM physical volume $PART"
    sudo pvscan --cache --config "$LVM_CFG" "$PART" || true
  fi
done < <(compgen -G "${LOOP}p*" || true)

mapfile -t VGS < <(
  sudo pvs --noheadings --config "$LVM_CFG" -o vg_name,pv_name 2>/dev/null \
    | awk -v loop="$LOOP" '$2 ~ loop && $1 != "" {print $1}' | sort -u
)

for VG in "${VGS[@]:-}"; do
  [ -n "$VG" ] || continue
  echo "Activating VG $VG"
  sudo vgchange -ay --activationmode partial --config "$LVM_CFG" "$VG" || true
done
sudo udevadm settle 2>/dev/null || true

{
  sudo lsblk -b -o NAME,PATH,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,RO,MOUNTPOINTS || true
  echo
  sudo pvs --config "$LVM_CFG" 2>/dev/null || true
  sudo vgs --config "$LVM_CFG" 2>/dev/null || true
  sudo lvs -a -o +devices --config "$LVM_CFG" 2>/dev/null || true
} | tee "$OUT/storage-after-lvm.txt"

stage 'FIND AND MOUNT LINUX ROOT READ-ONLY'
CANDIDATES="$OUT/root-candidates.tsv"
: > "$CANDIDATES"

sudo lsblk -bprno PATH,FSTYPE,SIZE "$LOOP" 2>/dev/null \
  | awk '$2 ~ /^(ext2|ext3|ext4|xfs|btrfs)$/ {print $3 "\t" $1 "\t" $2}' \
  >> "$CANDIDATES" || true

sudo lvs --noheadings --separator '|' --units b --nosuffix \
  -o lv_path,lv_size,devices --config "$LVM_CFG" 2>/dev/null \
  | while IFS='|' read -r LV SIZE DEVICES; do
      LV="$(echo "$LV" | xargs)"
      SIZE="$(echo "$SIZE" | xargs)"
      DEVICES="$(echo "$DEVICES" | xargs)"
      [ -n "$LV" ] || continue
      case "$DEVICES" in
        *"$(basename "$LOOP")"*) ;;
        *) continue ;;
      esac
      TYPE="$(sudo blkid -o value -s TYPE "$LV" 2>/dev/null || true)"
      case "$TYPE" in
        ext2|ext3|ext4|xfs|btrfs) printf '%s\t%s\t%s\n' "${SIZE%.*}" "$LV" "$TYPE" ;;
      esac
    done >> "$CANDIDATES"

sort -t $'\t' -k1,1nr "$CANDIDATES" | awk -F'\t' '!seen[$2]++' > "$CANDIDATES.sorted"
mv "$CANDIDATES.sorted" "$CANDIDATES"
cat "$CANDIDATES"

ROOTDEV=''
ROOTFS=''
while IFS=$'\t' read -r SIZE DEV TYPE; do
  [ -n "$DEV" ] || continue
  echo "Trying $DEV ($TYPE, $SIZE bytes)"
  sudo umount "$MNT" 2>/dev/null || true

  case "$TYPE" in
    ext2|ext3|ext4)
      sudo mount -o ro,noload "$DEV" "$MNT" 2>/dev/null || sudo mount -o ro "$DEV" "$MNT" 2>/dev/null || continue
      ;;
    xfs)
      sudo mount -o ro,norecovery "$DEV" "$MNT" 2>/dev/null || continue
      ;;
    btrfs)
      sudo mount -o ro "$DEV" "$MNT" 2>/dev/null || continue
      ;;
    *) continue ;;
  esac

  if [ -f "$MNT/etc/os-release" ] && [ -d "$MNT/etc/asterisk" ]; then
    ROOTDEV="$DEV"
    ROOTFS="$TYPE"
    MOUNTED=1
    break
  fi
  sudo umount "$MNT" 2>/dev/null || true
done < "$CANDIDATES"

[ "$MOUNTED" -eq 1 ] || fail 'Could not identify and mount the FRANZFON Linux root filesystem'
echo -e "$ROOTDEV\t$ROOTFS" | tee "$OUT/mounted-root.txt"
ROOT="$MNT"

stage 'SYSTEM AND PACKAGE INVENTORY'
{
  echo '=== OS RELEASE ==='
  cat "$ROOT/etc/os-release" 2>/dev/null || true
  echo
  echo '=== DPKG ARCHITECTURES ==='
  cat "$ROOT/var/lib/dpkg/arch" 2>/dev/null || true
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
  for P in usr/sbin/asterisk usr/bin/node usr/bin/npm usr/bin/python3 usr/bin/php usr/bin/java usr/bin/dotnet usr/sbin/nginx usr/sbin/apache2; do
    [ -e "$ROOT/$P" ] && file "$ROOT/$P"
  done
} > "$OUT/important-packages-runtimes.txt"

stage 'SERVICE INVENTORY'
{
  echo '=== SERVICE FILE PATHS ==='
  find "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system" -type f \
    \( -name '*.service' -o -name '*.timer' -o -name '*.socket' \) -print 2>/dev/null | sort
  echo
  echo '=== RELEVANT SERVICE DIRECTIVES ==='
  grep -RHIEn --include='*.service' --include='*.timer' --include='*.socket' \
    'franz|wizard|asterisk|node|nginx|apache|maria|mysql|postgres|ExecStart|ExecStartPre|ExecStartPost|WorkingDirectory|User=|Group=|EnvironmentFile=' \
    "$ROOT/etc/systemd/system" "$ROOT/lib/systemd/system" 2>/dev/null || true
} > "$OUT/services.txt"

stage 'APPLICATION TREE AND BINARY ARCHITECTURES'
{
  echo '=== FRANZFON-NAMED PATHS ==='
  find "$ROOT" -xdev \( -iname '*franzfon*' -o -iname '*franz*fon*' \) \
    -printf '%y\t%p\t%s\n' 2>/dev/null | head -n 10000
  echo
  echo '=== RELEVANT TREES ==='
  for D in opt srv usr/local var/www etc/asterisk var/lib/asterisk var/spool/asterisk; do
    [ -e "$ROOT/$D" ] || continue
    echo "--- /$D ---"
    find "$ROOT/$D" -maxdepth 6 -printf '%y\t%p\t%s\n' 2>/dev/null | head -n 20000
  done
} > "$OUT/relevant-tree.txt"

{
  echo '=== NATIVE BINARIES AND SCRIPTS ==='
  find "$ROOT/opt" "$ROOT/srv" "$ROOT/usr/local" "$ROOT/var/www" \
    -xdev -type f -size -250M -print0 2>/dev/null \
    | xargs -0 -r file 2>/dev/null \
    | grep -Ei 'ELF|script|Java|Mono|\.NET|WebAssembly|PE32' \
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

stage 'DATABASE, ASTERISK, UPDATE INVENTORY'
{
  echo '=== DATABASE FILE MARKERS ==='
  find "$ROOT/opt" "$ROOT/srv" "$ROOT/usr/local" "$ROOT/var/www" "$ROOT/var/lib" \
    -maxdepth 6 -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' \
    -o -name 'PG_VERSION' -o -name 'ibdata1' \) -printf '%p\t%s\n' 2>/dev/null \
    | sort | head -n 10000
  echo
  echo '=== DATABASE REFERENCES ==='
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
find "$OUT" -type f \( -name '*.txt' -o -name '*.log' \) -print0 | while IFS= read -r -d '' F; do
  sed -ri \
    -e 's#([A-Za-z0-9_]*(PASSWORD|PASS|TOKEN|SECRET|PRIVATE_KEY|API_KEY)[A-Za-z0-9_]*[=:])[[:space:]]*[^[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#(Authorization:[[:space:]]*(Bearer|Basic))[[:space:]]+[^[:space:]]+#\1 [REDACTED]#Ig' \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    "$F" || true
done

{
  echo '=== REPORT FILES ==='
  find "$OUT" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort
  echo
  echo 'Analysis completed successfully.'
} | tee "$OUT/summary.txt"

cleanup
trap - EXIT
