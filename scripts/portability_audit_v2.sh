#!/usr/bin/env bash
set -euo pipefail

URL='https://franzfon.de/updates/proxmox/vzdump-qemu-900-2026_08_04-01_09_26.vma.zst'
WORK="${GITHUB_WORKSPACE:-$PWD}"
EXTRACTED="$WORK/extracted-portability-v2"
OUT="$WORK/portability-report"
MNT="$WORK/franzfon-portability-root"
LOOP=''
MOUNTED=0

mkdir -p "$EXTRACTED" "$OUT" "$MNT"

cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then
    sudo umount "$MNT" 2>/dev/null || true
  fi
  if [ -n "$LOOP" ]; then
    sudo losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log() { printf '\n===== %s =====\n' "$1"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

log 'EXTRACT APPLIANCE'
python3 "$WORK/scripts/stream_vma_extract.py" "$URL" "$EXTRACTED"
RAW="$(find "$EXTRACTED" -maxdepth 1 -type f -size +16M -printf '%s\t%p\n' | sort -nr | head -n1 | cut -f2-)"
[ -n "$RAW" ] || fail 'No disk image found'

log 'MOUNT ROOT READ-ONLY'
LOOP="$(sudo losetup --find --show --partscan --read-only "$RAW")"
sudo udevadm settle 2>/dev/null || true
sleep 2

ROOT_LINE="$(sudo lsblk -bprno PATH,FSTYPE,SIZE "$LOOP" 2>/dev/null \
  | awk '$2 ~ /^(ext2|ext3|ext4|xfs|btrfs)$/ {print $3 "\t" $1 "\t" $2}' \
  | sort -nr | head -n1)"
ROOTDEV="$(printf '%s' "$ROOT_LINE" | cut -f2)"
ROOTFS="$(printf '%s' "$ROOT_LINE" | cut -f3)"
[ -n "$ROOTDEV" ] || fail 'No Linux root filesystem found'

case "$ROOTFS" in
  ext2|ext3|ext4)
    sudo mount -o ro,noload "$ROOTDEV" "$MNT" 2>/dev/null || sudo mount -o ro "$ROOTDEV" "$MNT"
    ;;
  xfs) sudo mount -o ro,norecovery "$ROOTDEV" "$MNT" ;;
  btrfs) sudo mount -o ro "$ROOTDEV" "$MNT" ;;
  *) fail "Unsupported filesystem: $ROOTFS" ;;
esac
MOUNTED=1
ROOT="$MNT"
[ -f "$ROOT/etc/os-release" ] || fail 'Mounted filesystem is not root'

log 'BASELINE'
{
  echo '=== OS ==='
  cat "$ROOT/etc/os-release" 2>/dev/null || true
  echo
  echo '=== ROOT FILESYSTEM ==='
  printf '%s\t%s\n' "$ROOTDEV" "$ROOTFS"
  echo
  echo '=== PACKAGE ARCHITECTURE COUNTS ==='
  awk '/^Architecture:/{count[$2]++} END{for (a in count) print a, count[a]}' \
    "$ROOT/var/lib/dpkg/status" 2>/dev/null | sort || true
  echo
  echo '=== IMPORTANT PACKAGE VERSIONS ==='
  awk '
    /^Package:/ {pkg=$2}
    /^Version:/ {ver=$2}
    /^Architecture:/ {arch=$2}
    /^$/ {
      if (pkg ~ /^(asterisk|asterisk22|nodejs|npm|mariadb|mysql|php8\.2|redis|haproxy|freepbx|sangoma|sqlite3)/)
        printf "%s\t%s\t%s\n", pkg, ver, arch;
      pkg=ver=arch=""
    }
  ' "$ROOT/var/lib/dpkg/status" 2>/dev/null | sort || true
} > "$OUT/baseline.txt"

log 'FRANZFON SERVICES'
{
  shopt -s nullglob
  UNITS=(
    "$ROOT"/etc/systemd/system/franzfon*.service
    "$ROOT"/etc/systemd/system/franzfon*.timer
    "$ROOT"/etc/systemd/system/asterisk.service
    "$ROOT"/etc/systemd/system/sangoma-pnpd.service
  )
  for UNIT in "${UNITS[@]}"; do
    [ -f "$UNIT" ] || continue
    echo "===== ${UNIT#$ROOT} ====="
    sed -E \
      -e 's#(Environment=.*(PASSWORD|PASS|TOKEN|SECRET|KEY)=).*#\1[REDACTED]#Ig' \
      -e 's#(Authorization: *(Bearer|Basic)) +[^ ]+#\1 [REDACTED]#Ig' \
      "$UNIT" || true
    echo
  done
} > "$OUT/franzfon-services.txt"

log 'NODE PROJECT MANIFESTS'
{
  if [ -d "$ROOT/opt/franzfon" ]; then
    { find "$ROOT/opt/franzfon" -path '*/node_modules' -prune -o -type f -name package.json -print0 2>/dev/null || true; } \
      | while IFS= read -r -d '' PKG; do
          echo "===== ${PKG#$ROOT} ====="
          jq '{name,version,type,main,scripts,engines,dependencies,optionalDependencies,devDependencies}' "$PKG" 2>/dev/null || cat "$PKG"
          echo
        done
  fi
} > "$OUT/node-project-manifests.txt"

log 'NODE NATIVE RISKS'
{
  echo '=== NATIVE NODE ADDONS (.node) ==='
  if [ -d "$ROOT/opt/franzfon" ]; then
    { find "$ROOT/opt/franzfon" -type f -name '*.node' -print0 2>/dev/null || true; } \
      | while IFS= read -r -d '' F; do
          printf '%s\t%s\t' "${F#$ROOT}" "$(file -b "$F" 2>/dev/null || true)"
          sha256sum "$F" | awk '{print "sha256=" $1}'
        done
  fi
  echo
  echo '=== BUILD MARKERS ==='
  if [ -d "$ROOT/opt/franzfon" ]; then
    { find "$ROOT/opt/franzfon" -type f \( -name binding.gyp -o -name '*.gypi' -o -name CMakeLists.txt \) \
        -printf '%p\t%s bytes\n' 2>/dev/null || true; } | sed "s#$ROOT##" | sort
  fi
  echo
  echo '=== PACKAGES DECLARING NATIVE INSTALL HOOKS ==='
  if [ -d "$ROOT/opt/franzfon" ]; then
    { find "$ROOT/opt/franzfon" -type f -name package.json -print0 2>/dev/null || true; } \
      | while IFS= read -r -d '' PKG; do
          if jq -e '(.gypfile == true) or (.scripts.install != null) or (.scripts.preinstall != null) or (.scripts.postinstall != null)' "$PKG" >/dev/null 2>&1; then
            printf '%s\t' "${PKG#$ROOT}"
            jq -c '{name,version,gypfile,scripts:{preinstall:.scripts.preinstall,install:.scripts.install,postinstall:.scripts.postinstall}}' "$PKG" 2>/dev/null || true
          fi
        done
  fi
} > "$OUT/node-native-risk.txt"

log 'NATIVE FRANZFON BINARIES'
{
  echo '=== ELF / PE / SHARED OBJECTS UNDER /opt/franzfon ==='
  if [ -d "$ROOT/opt/franzfon" ]; then
    { find "$ROOT/opt/franzfon" -type f \( -perm /111 -o -name '*.so' -o -name '*.node' \) \
        -size -300M -print0 2>/dev/null || true; } \
      | while IFS= read -r -d '' F; do
          DESC="$(file -b "$F" 2>/dev/null || true)"
          case "$DESC" in
            *ELF*|*PE32*|*shared\ object*)
              printf '%s\t%s\t' "${F#$ROOT}" "$DESC"
              sha256sum "$F" | awk '{print $1}'
              ;;
          esac
        done
  fi
} > "$OUT/franzfon-native-binaries.txt"

log 'ASTERISK PORTABILITY'
{
  echo '=== ASTERISK PACKAGES ==='
  awk '
    /^Package:/ {pkg=$2}
    /^Version:/ {ver=$2}
    /^Architecture:/ {arch=$2}
    /^$/ {if (pkg ~ /^asterisk/) printf "%s\t%s\t%s\n", pkg, ver, arch; pkg=ver=arch=""}
  ' "$ROOT/var/lib/dpkg/status" 2>/dev/null | sort || true
  echo
  echo '=== ASTERISK MODULE BINARIES ==='
  AST_ROOTS=()
  [ -d "$ROOT/usr/lib" ] && AST_ROOTS+=("$ROOT/usr/lib")
  [ -d "$ROOT/usr/lib64" ] && AST_ROOTS+=("$ROOT/usr/lib64")
  if [ "${#AST_ROOTS[@]}" -gt 0 ]; then
    { find "${AST_ROOTS[@]}" -path '*asterisk*' -type f \( -name '*.so' -o -perm /111 \) -print0 2>/dev/null || true; } \
      | while IFS= read -r -d '' F; do
          printf '%s\t%s\n' "${F#$ROOT}" "$(file -b "$F" 2>/dev/null || true)"
        done | sort
  fi
  echo
  echo '=== NONFREE / HARDWARE-SPECIFIC PACKAGE HINTS ==='
  grep -Ei 'g729|dahdi|digium|sangoma|ooh323|bluetooth|flite' "$OUT/baseline.txt" 2>/dev/null || true
} > "$OUT/asterisk-portability.txt"

log 'APT AND RUNTIME SOURCES'
{
  shopt -s nullglob
  SOURCES=("$ROOT/etc/apt/sources.list" "$ROOT"/etc/apt/sources.list.d/*)
  for F in "${SOURCES[@]}"; do
    [ -f "$F" ] || continue
    echo "===== ${F#$ROOT} ====="
    sed -E \
      -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@ ]+:[^/@ ]+@#\1[REDACTED]@#g' \
      -e 's#(signed-by=)[^] ]+#\1[KEYRING]#g' "$F" || true
    echo
  done
} > "$OUT/apt-sources.txt"

log 'APPLICATION SHAPE'
{
  echo '=== FILE COUNTS BY EXTENSION, EXCLUDING node_modules ==='
  if [ -d "$ROOT/opt/franzfon" ]; then
    { find "$ROOT/opt/franzfon" -path '*/node_modules' -prune -o -type f -printf '%f\n' 2>/dev/null || true; } \
      | awk '
          function ext(name) {
            if (name !~ /\./) return "[no extension]";
            sub(/^.*\./,"",name); return tolower(name)
          }
          {c[ext($0)]++}
          END {for (e in c) printf "%s\t%d\n", e, c[e]}
        ' | sort -k2,2nr
  fi
  echo
  echo '=== TOP-LEVEL SIZE ==='
  du -h -d 3 "$ROOT/opt/franzfon" 2>/dev/null | sed "s#$ROOT##" | sort -h || true
  echo
  echo '=== FRANZFON FILE MANIFEST, EXCLUDING node_modules AND CONFIG SECRETS ==='
  if [ -d "$ROOT/opt/franzfon" ]; then
    { find "$ROOT/opt/franzfon" -path '*/node_modules' -prune -o -type f \
        ! -name '*.env' ! -iname '*secret*' ! -iname '*credential*' -printf '%s\t%p\n' 2>/dev/null || true; } \
      | sed "s#$ROOT##" | sort -k2
  fi
} > "$OUT/application-shape.txt"

log 'DATABASE LAYOUT WITHOUT CONTENTS'
{
  echo '=== DATABASE DIRECTORIES ==='
  DB_DIRS=()
  [ -d "$ROOT/var/lib/mysql" ] && DB_DIRS+=("$ROOT/var/lib/mysql")
  [ -d "$ROOT/var/lib/redis" ] && DB_DIRS+=("$ROOT/var/lib/redis")
  if [ "${#DB_DIRS[@]}" -gt 0 ]; then
    du -h -d 2 "${DB_DIRS[@]}" 2>/dev/null | sed "s#$ROOT##" | sort -h || true
  fi
  echo
  echo '=== FRANZFON DATABASE MARKERS ==='
  SEARCH_DIRS=()
  [ -d "$ROOT/opt/franzfon" ] && SEARCH_DIRS+=("$ROOT/opt/franzfon")
  [ -d "$ROOT/var/lib" ] && SEARCH_DIRS+=("$ROOT/var/lib")
  if [ "${#SEARCH_DIRS[@]}" -gt 0 ]; then
    { find "${SEARCH_DIRS[@]}" -maxdepth 6 -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' -o -name 'ibdata1' \) \
        -printf '%s\t%p\n' 2>/dev/null || true; } | sed "s#$ROOT##" | sort -nr | head -n 500
  fi
} > "$OUT/database-layout.txt"

log 'GENERATE PORTABILITY VERDICT INPUT'
{
  echo 'ARM64_PORTABILITY_AUDIT_VERSION=2'
  echo "FRANZFON_NODE_PROJECTS=$(grep -c '^===== /opt/franzfon.*package.json' "$OUT/node-project-manifests.txt" 2>/dev/null || true)"
  echo "NATIVE_NODE_ADDONS=$(grep -c '^/opt/franzfon.*\.node' "$OUT/node-native-risk.txt" 2>/dev/null || true)"
  echo "FRANZFON_NATIVE_BINARIES=$(grep -c '^/opt/franzfon' "$OUT/franzfon-native-binaries.txt" 2>/dev/null || true)"
  echo "ASTERISK_AMD64_PACKAGES=$(awk -F'\t' '$3=="amd64"{c++} END{print c+0}' "$OUT/asterisk-portability.txt")"
  echo
  echo 'Interpretation:'
  echo '- JavaScript, JSON, shell and static web files are architecture-independent.'
  echo '- Every x86-64 ELF, .node addon and proprietary codec needs an ARM64 build or replacement.'
  echo '- Asterisk distribution packages must be replaced by ARM64 Asterisk packages/builds.'
  echo '- Database data should be migrated logically rather than by copying raw MariaDB files.'
} > "$OUT/portability-verdict-input.txt"

log 'SANITIZE'
find "$OUT" -type f -name '*.txt' -print0 | while IFS= read -r -d '' F; do
  sed -ri \
    -e 's#([A-Za-z0-9_]*(PASSWORD|PASS|TOKEN|SECRET|PRIVATE_KEY|API_KEY)[A-Za-z0-9_]*[=:])[[:space:]]*[^[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#(Authorization:[[:space:]]*(Bearer|Basic))[[:space:]]+[^[:space:]]+#\1 [REDACTED]#Ig' \
    -e 's#([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@#\1[REDACTED]@#g' \
    "$F" || true
done

{
  echo 'Portability audit v2 completed successfully.'
  find "$OUT" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort
} | tee "$OUT/summary.txt"
