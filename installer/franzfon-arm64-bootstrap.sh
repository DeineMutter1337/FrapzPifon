#!/usr/bin/env bash
set -euo pipefail

APP_ROOT='/opt/franzfon'
ASTERISK_PREFIX='/opt/franzfon-arm64/asterisk'
ENV_FILE='/opt/franzfon/config/database.env'
STATE_DIR='/etc/franzfon-arm64'
ACTIVATE=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./installer/franzfon-arm64-bootstrap.sh [--activate]

Options:
  --activate   Enable and start MariaDB, Redis, Asterisk and the FRANZFON wizard
               after all local validation checks pass.
  -h, --help   Show this help.

This bootstrap creates fresh local database and session secrets, initializes the
empty CDR database, writes a minimal native Asterisk configuration and leaves all
services disabled unless --activate is supplied. It does not import an existing
license, machine identity, passwords or customer data and does not alter the
original FRANZFON license checks.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --activate) ACTIVATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in arm64|aarch64) ;; *) echo "ARM64 required, found: $ARCH" >&2; exit 1 ;; esac

[ -f "$APP_ROOT/wizard/backend/package.json" ] || {
  echo 'FRANZFON application stage is not installed.' >&2
  exit 1
}
[ -x "$ASTERISK_PREFIX/sbin/asterisk" ] || {
  echo 'Managed native Asterisk installation is missing.' >&2
  exit 1
}
[ -f "$ASTERISK_PREFIX/.franzfon-arm64-asterisk" ] || {
  echo 'Asterisk installation is not marked as managed by this port.' >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  mariadb-server mariadb-client redis-server sqlite3 unixodbc odbc-mariadb \
  openssl curl file iproute2 binutils

install -d -m 0700 "$STATE_DIR"
install -d -o root -g root -m 0750 "$APP_ROOT/config"
install -d -o root -g root -m 0750 "$APP_ROOT/wizard/backend/data"

printf '\n[1/8] Creating fresh local secrets\n'
if [ ! -f "$ENV_FILE" ]; then
  SESSION_SECRET="$(openssl rand -hex 48)"
  CDR_DB_PASSWORD="$(openssl rand -hex 32)"
  umask 077
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
SESSION_SECRET=$SESSION_SECRET
CDR_DB_PASSWORD=$CDR_DB_PASSWORD
FF_WEBHOOK_TIMEOUT_MS=10000
FF_WEBHOOK_RETRY_DELAY_MS=5000
EOF
  chmod 0600 "$ENV_FILE"
else
  echo "Keeping existing environment file: $ENV_FILE"
fi

# shellcheck disable=SC1090
. "$ENV_FILE"
: "${SESSION_SECRET:?SESSION_SECRET is missing from $ENV_FILE}"
: "${CDR_DB_PASSWORD:?CDR_DB_PASSWORD is missing from $ENV_FILE}"
case "$CDR_DB_PASSWORD" in
  *[!A-Fa-f0-9]*)
    echo 'CDR_DB_PASSWORD must contain only hexadecimal characters for safe bootstrap use.' >&2
    exit 1
    ;;
esac

printf '\n[2/8] Initializing MariaDB CDR database\n'
systemctl start mariadb.service
mariadb --protocol=socket --user=root <<SQL
CREATE DATABASE IF NOT EXISTS asteriskcdrdb
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'asterisk'@'localhost' IDENTIFIED BY '${CDR_DB_PASSWORD}';
ALTER USER 'asterisk'@'localhost' IDENTIFIED BY '${CDR_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON asteriskcdrdb.* TO 'asterisk'@'localhost';
FLUSH PRIVILEGES;
USE asteriskcdrdb;
CREATE TABLE IF NOT EXISTS cdr (
  calldate datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  clid varchar(80) NOT NULL DEFAULT '',
  src varchar(80) NOT NULL DEFAULT '',
  dst varchar(80) NOT NULL DEFAULT '',
  dcontext varchar(80) NOT NULL DEFAULT '',
  channel varchar(80) NOT NULL DEFAULT '',
  dstchannel varchar(80) NOT NULL DEFAULT '',
  lastapp varchar(80) NOT NULL DEFAULT '',
  lastdata varchar(255) NOT NULL DEFAULT '',
  duration int unsigned NOT NULL DEFAULT 0,
  billsec int unsigned NOT NULL DEFAULT 0,
  disposition varchar(45) NOT NULL DEFAULT '',
  amaflags int unsigned NOT NULL DEFAULT 0,
  accountcode varchar(20) NOT NULL DEFAULT '',
  uniqueid varchar(150) NOT NULL DEFAULT '',
  userfield varchar(255) NOT NULL DEFAULT '',
  did varchar(50) NOT NULL DEFAULT '',
  recordingfile varchar(255) NOT NULL DEFAULT '',
  cnum varchar(80) NOT NULL DEFAULT '',
  cnam varchar(80) NOT NULL DEFAULT '',
  outbound_cnum varchar(80) NOT NULL DEFAULT '',
  outbound_cnam varchar(80) NOT NULL DEFAULT '',
  dst_cnam varchar(80) NOT NULL DEFAULT '',
  linkedid varchar(150) NOT NULL DEFAULT '',
  peeraccount varchar(80) NOT NULL DEFAULT '',
  sequence int unsigned NOT NULL DEFAULT 0,
  KEY calldate (calldate),
  KEY dst (dst),
  KEY accountcode (accountcode),
  KEY uniqueid (uniqueid),
  KEY linkedid (linkedid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL

mariadb --protocol=socket --user=asterisk --password="$CDR_DB_PASSWORD" \
  --database=asteriskcdrdb --execute='SELECT 1' >/dev/null

printf '\n[3/8] Configuring ODBC for Asterisk CDR\n'
MARIADB_ODBC_DRIVER="$(odbcinst -q -d 2>/dev/null | tr -d '[]' | grep -i 'maria' | head -n1 || true)"
[ -n "$MARIADB_ODBC_DRIVER" ] || {
  echo 'MariaDB ODBC driver was not registered.' >&2
  exit 1
}

cat > /etc/odbc.ini <<EOF
[asteriskcdrdb]
Description=FRANZFON Asterisk CDR database
Driver=$MARIADB_ODBC_DRIVER
Server=localhost
Database=asteriskcdrdb
User=asterisk
Password=$CDR_DB_PASSWORD
Port=3306
Socket=/run/mysqld/mysqld.sock
Option=3
EOF
chown root:asterisk /etc/odbc.ini
chmod 0640 /etc/odbc.ini

printf '\n[4/8] Writing minimal native Asterisk configuration\n'
install -d -o root -g asterisk -m 0750 /etc/asterisk
install -d -o asterisk -g asterisk -m 0750 \
  /var/lib/asterisk \
  /var/lib/asterisk/agi-bin \
  /var/lib/asterisk/moh \
  /var/log/asterisk \
  /var/spool/asterisk \
  /var/spool/asterisk/monitor \
  /var/spool/asterisk/voicemail \
  /var/run/asterisk

cat > /etc/asterisk/asterisk.conf <<EOF
[directories]
astetcdir => /etc/asterisk
astmoddir => $ASTERISK_PREFIX/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
astsbindir => $ASTERISK_PREFIX/sbin

[options]
runuser = asterisk
rungroup = asterisk
defaultlanguage = de
languageprefix = yes
live_dangerously = no
EOF

cat > /etc/asterisk/modules.conf <<'EOF'
[modules]
autoload=yes
noload=chan_dahdi.so
noload=codec_g729a.so
noload=res_digium_phone.so
noload=chan_console.so
noload=chan_alsa.so
EOF

cat > /etc/asterisk/logger.conf <<'EOF'
[general]
dateformat=%F %T

[logfiles]
console => notice,warning,error
messages => notice,warning,error
full => notice,warning,error,verbose,debug
EOF

cat > /etc/asterisk/rtp.conf <<'EOF'
[general]
rtpstart=10000
rtpend=10200
strictrtp=yes
icesupport=yes
EOF

cat > /etc/asterisk/http.conf <<'EOF'
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
sessionlimit=100
websocket_enabled=yes
EOF

cat > /etc/asterisk/manager.conf <<'EOF'
[general]
enabled=yes
webenabled=no
port=5038
bindaddr=127.0.0.1
displayconnects=no
EOF

cat > /etc/asterisk/pjsip.conf <<'EOF'
[global]
type=global
user_agent=FRANZFON ARM64
endpoint_identifier_order=ip,username,anonymous

#include pjsip_franzfon.conf
EOF
: > /etc/asterisk/pjsip_franzfon.conf

cat > /etc/asterisk/extensions.conf <<'EOF'
[general]
static=yes
writeprotect=no
clearglobalvars=no

[globals]

#include extensions_franzfon.conf
EOF
cat > /etc/asterisk/extensions_franzfon.conf <<'EOF'
[franzfon-internal]
exten => _X.,1,NoOp(FRANZFON ARM64 placeholder dialplan)
 same => n,Hangup()
EOF

cat > /etc/asterisk/voicemail.conf <<'EOF'
[general]
format=wav49|gsm|wav
serveremail=asterisk
attach=yes
maxmsg=100
maxsecs=300
minsecs=2
EOF

cat > /etc/asterisk/queues.conf <<'EOF'
[general]
persistentmembers=yes
autofill=yes
monitor-type=MixMonitor
EOF

cat > /etc/asterisk/res_odbc.conf <<EOF
[asteriskcdrdb]
enabled => yes
dsn => asteriskcdrdb
username => asterisk
password => $CDR_DB_PASSWORD
pre-connect => yes
sanitysql => select 1
EOF
chmod 0640 /etc/asterisk/res_odbc.conf

cat > /etc/asterisk/cdr_adaptive_odbc.conf <<'EOF'
[first]
connection=asteriskcdrdb
table=cdr
alias start => calldate
EOF

cat > /etc/asterisk/cdr.conf <<'EOF'
[general]
enable=yes
unanswered=yes
congestion=yes
endbeforehexten=no
initiatedseconds=no
EOF

cat > /etc/asterisk/ari.conf <<'EOF'
[general]
enabled=yes
pretty=yes
allowed_origins=*
EOF

chown -R root:asterisk /etc/asterisk
find /etc/asterisk -type d -exec chmod 0750 {} +
find /etc/asterisk -type f -exec chmod 0640 {} +
chmod 0640 /etc/asterisk/res_odbc.conf

printf '\n[5/8] Validating native binaries and configuration files\n'
assert_aarch64_elf() {
  local target="$1"
  local machine
  [ -e "$target" ] || { echo "ARM64 validation target missing: $target" >&2; exit 1; }
  machine="$(readelf -h "$target" | awk '$1 == "Machine:" {print $2}')"
  [ "$machine" = AArch64 ] || {
    echo "Expected AArch64 ELF, found '${machine:-unknown}': $target" >&2
    exit 1
  }
}

assert_aarch64_elf "$ASTERISK_PREFIX/sbin/asterisk"
assert_aarch64_elf "$APP_ROOT/wizard/backend/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
"$ASTERISK_PREFIX/sbin/asterisk" -V
/usr/local/bin/node --check "$APP_ROOT/wizard/backend/src/index.js"

printf '\n[6/8] Installing final service ordering\n'
cat > /etc/systemd/system/franzfon-wizard.service <<'EOF'
[Unit]
Description=FRANZFON Wizard ARM64
After=network-online.target mariadb.service redis-server.service asterisk.service
Wants=network-online.target mariadb.service redis-server.service asterisk.service
ConditionPathExists=/opt/franzfon/config/database.env
ConditionPathExists=/opt/franzfon/wizard/backend/src/index.js

[Service]
Type=simple
User=root
WorkingDirectory=/opt/franzfon/wizard/backend
EnvironmentFile=/opt/franzfon/config/database.env
ExecStartPre=/bin/bash -c '! ss -H -ltn sport = :3000 | grep -q .'
ExecStart=/usr/local/bin/node src/index.js
Restart=on-failure
RestartSec=3
TimeoutStartSec=45
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl disable asterisk.service franzfon-wizard.service >/dev/null 2>&1 || true
systemctl stop asterisk.service franzfon-wizard.service >/dev/null 2>&1 || true

printf '\n[7/8] Recording bootstrap state\n'
cat > "$STATE_DIR/install-state" <<EOF
APPLICATION_INSTALLED=yes
APPLICATION_ARCH=arm64
ASTERISK_INSTALLED=yes
ASTERISK_VERSION=22.7.0
ASTERISK_PREFIX=$ASTERISK_PREFIX
FREEPBX_REQUIRED=no
DATABASE_CONFIGURED=yes
CDR_DATABASE=asteriskcdrdb
LICENSE_STATE_IMPORTED=no
STACK_ENABLED=no
BOOTSTRAPPED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "$STATE_DIR/install-state"

printf '\n[8/8] Final service action\n'
if [ "$ACTIVATE" -eq 1 ]; then
  systemctl enable mariadb.service redis-server.service asterisk.service franzfon-wizard.service
  systemctl restart mariadb.service redis-server.service
  systemctl start asterisk.service

  for _ in $(seq 1 30); do
    if "$ASTERISK_PREFIX/sbin/asterisk" -rx 'core show version' >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  "$ASTERISK_PREFIX/sbin/asterisk" -rx 'core show version'
  "$ASTERISK_PREFIX/sbin/asterisk" -rx 'module show like res_pjsip.so'

  systemctl start franzfon-wizard.service
  for _ in $(seq 1 45); do
    if curl --fail --location --silent --max-time 2 http://127.0.0.1:3000/ >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  curl --fail --location --silent --show-error --max-time 5 http://127.0.0.1:3000/ >/dev/null
  sed -i 's/^STACK_ENABLED=no$/STACK_ENABLED=yes/' "$STATE_DIR/install-state"
  systemctl --no-pager --full status asterisk.service franzfon-wizard.service
  echo 'FRANZFON ARM64 stack activated successfully.'
else
  echo 'Bootstrap completed. Services remain disabled and stopped.'
  echo 'Run this script again with --activate after reviewing the configuration.'
fi
