#!/usr/bin/env bash
set -uo pipefail

APP_ROOT='/opt/franzfon'
ASTERISK_PREFIX='/opt/franzfon-arm64/asterisk'
STATE_FILE='/etc/franzfon-arm64/install-state'
HTTP_URL='http://127.0.0.1:3000/'
ASTERISK_UNIT='/etc/systemd/system/asterisk.service'
ASTERISK_UNIT_SIG='# FRANZFON-NATIVE-UNIT-v1'
ASTERISK_LEGACY_BIN='/usr/sbin/asterisk'
FAILURES=0
PASSES=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./installer/franzfon-arm64-selftest.sh

Runs a read-only post-install validation of the native FRANZFON ARM64 stack.
No passwords, database contents or license data are printed or modified.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }

pass() {
  printf 'PASS  %s\n' "$1"
  PASSES=$((PASSES + 1))
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

check_command() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

check_output() {
  local label="$1"
  local expected="$2"
  shift 2
  local output
  output="$("$@" 2>/dev/null || true)"
  if grep -Fq -- "$expected" <<<"$output"; then pass "$label"; else fail "$label"; fi
}

printf 'FRANZFON ARM64 self-test\n\n'

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
  arm64|aarch64) pass "Host architecture is ARM64 ($ARCH)" ;;
  *) fail "Host architecture is not ARM64 ($ARCH)" ;;
esac

if [ -x /usr/local/bin/node ]; then
  NODE_ARCH="$(/usr/local/bin/node -p process.arch 2>/dev/null || true)"
  [ "$NODE_ARCH" = arm64 ] && pass 'Node.js runtime is ARM64' || fail "Node.js runtime is not ARM64 (${NODE_ARCH:-unknown})"
else
  fail 'Node.js runtime is installed'
fi

ASTERISK="$ASTERISK_PREFIX/sbin/asterisk"
if [ -x "$ASTERISK" ]; then
  ASTERISK_MACHINE="$(readelf -h "$ASTERISK" 2>/dev/null | awk '$1 == "Machine:" {print $2}')"
  [ "$ASTERISK_MACHINE" = AArch64 ] && pass 'Asterisk binary is AArch64' || fail "Asterisk binary is not AArch64 (${ASTERISK_MACHINE:-unknown})"
else
  fail 'Asterisk binary exists'
fi

if [ -f "$ASTERISK_UNIT" ]; then
  check_output 'Asterisk systemd unit carries FRANZFON native marker' \
    "$ASTERISK_UNIT_SIG" head -n 5 "$ASTERISK_UNIT"
  check_output 'Asterisk systemd unit uses managed ARM64 binary' \
    "$ASTERISK" cat "$ASTERISK_UNIT"
  if grep -Fq "$ASTERISK_LEGACY_BIN" "$ASTERISK_UNIT"; then
    fail 'Asterisk systemd unit does not reference legacy /usr/sbin/asterisk'
  else
    pass 'Asterisk systemd unit does not reference legacy /usr/sbin/asterisk'
  fi
else
  fail 'Asterisk native systemd unit exists'
fi

for source in \
  "$APP_ROOT/wizard/backend/src/services/pbx.js" \
  "$APP_ROOT/scripts/apply-update.sh"; do
  [ -f "$source" ] || continue
  if grep -Fq "$ASTERISK_LEGACY_BIN" "$source"; then
    fail "FRANZFON Asterisk template still references legacy path: $source"
  else
    pass "FRANZFON Asterisk template is ARM64-adapted: $source"
  fi
done

NATIVE_ADDONS=0
NATIVE_ADDON_FAILURES=0
if [ -d "$APP_ROOT/wizard/backend/node_modules" ]; then
  while IFS= read -r -d '' addon; do
    NATIVE_ADDONS=$((NATIVE_ADDONS + 1))
    machine="$(readelf -h "$addon" 2>/dev/null | awk '$1 == "Machine:" {print $2}')"
    if [ "$machine" != AArch64 ]; then
      printf 'FAIL  Native addon is not AArch64: %s (%s)\n' "$addon" "${machine:-unknown}" >&2
      NATIVE_ADDON_FAILURES=$((NATIVE_ADDON_FAILURES + 1))
    fi
  done < <(find -L "$APP_ROOT/wizard/backend/node_modules" -type f -name '*.node' -print0)
fi
if [ "$NATIVE_ADDONS" -gt 0 ] && [ "$NATIVE_ADDON_FAILURES" -eq 0 ]; then
  pass "All native Node.js addons are AArch64 ($NATIVE_ADDONS found)"
else
  fail "Native Node.js addon validation ($NATIVE_ADDONS found, $NATIVE_ADDON_FAILURES invalid)"
fi

for service in mariadb.service redis-server.service asterisk.service franzfon-wizard.service; do
  check_command "$service is active" systemctl is-active --quiet "$service"
done

check_command 'FRANZFON web interface responds on port 3000' \
  curl --fail --location --silent --show-error --max-time 10 "$HTTP_URL"

if [ -x "$ASTERISK" ]; then
  check_command 'Asterisk CLI responds' "$ASTERISK" -rx 'core show version'
  check_output 'PJSIP channel driver is loaded' 'chan_pjsip.so' "$ASTERISK" -rx 'module show like chan_pjsip.so'
  check_output 'HTTP WebSocket module is loaded' 'res_http_websocket.so' "$ASTERISK" -rx 'module show like res_http_websocket.so'
  check_output 'ODBC module is loaded' 'res_odbc.so' "$ASTERISK" -rx 'module show like res_odbc.so'
  check_output 'Asterisk CDR ODBC connection exists' 'asteriskcdrdb' "$ASTERISK" -rx 'odbc show'
fi

check_command 'Asterisk XML runtime documentation exists' \
  test -s /var/lib/asterisk/documentation/core-en_US.xml
check_command 'FRANZFON custom PJSIP file exists' \
  test -f /etc/asterisk/pjsip_custom.conf

if [ -f "$STATE_FILE" ]; then
  check_output 'Installation state records ARM64 application' 'APPLICATION_ARCH=arm64' cat "$STATE_FILE"
  check_output 'Installation state records active stack' 'STACK_ENABLED=yes' cat "$STATE_FILE"
  check_output 'No legacy license state was imported' 'LICENSE_STATE_IMPORTED=no' cat "$STATE_FILE"
  check_output 'FreePBX is not required' 'FREEPBX_REQUIRED=no' cat "$STATE_FILE"
else
  fail 'Installation state file exists'
fi

DB_USER_COUNT="$(mariadb --protocol=socket --user=root --batch --skip-column-names \
  --execute="SELECT COUNT(*) FROM mysql.user WHERE User IN ('asterisk','franzfon')" 2>/dev/null || true)"
[ "$DB_USER_COUNT" = 2 ] && pass 'MariaDB users asterisk and franzfon exist' || fail "Expected two FRANZFON database users, found ${DB_USER_COUNT:-unknown}"

X86_FOUND=0
while IFS= read -r -d '' path; do
  description="$(file -b "$path" 2>/dev/null || true)"
  case "$description" in
    *x86-64*|*Intel\ 80386*|*PE32*)
      printf 'FAIL  Unexpected x86 executable: %s (%s)\n' "$path" "$description" >&2
      X86_FOUND=$((X86_FOUND + 1))
      ;;
  esac
done < <(find -L "$APP_ROOT" "$ASTERISK_PREFIX" -type f -print0 2>/dev/null)
[ "$X86_FOUND" -eq 0 ] && pass 'No x86 executable exists in the managed installation' || fail "$X86_FOUND unexpected x86 executable(s) found"

printf '\nResult: %s passed, %s failed\n' "$PASSES" "$FAILURES"
if [ "$FAILURES" -eq 0 ]; then
  printf 'VERDICT=PASS\n'
  exit 0
fi

printf 'VERDICT=FAIL\n' >&2
exit 1
