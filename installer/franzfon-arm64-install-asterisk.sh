#!/usr/bin/env bash
set -euo pipefail

ASTERISK_VERSION='22.7.0'
ASTERISK_SHA256='5b0e5d276aeb014bf8a08a94d1055a9e97b9dce3375846eea70da5221bf9efe7'
ASTERISK_URL="https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ASTERISK_VERSION}.tar.gz"
PREFIX='/opt/franzfon-arm64/asterisk'
WORK_DIR='/var/tmp/franzfon-arm64-asterisk-build'
FORCE=0
KEEP_WORK=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./installer/franzfon-arm64-install-asterisk.sh [options]

Options:
  --prefix PATH      Installation prefix. Default: /opt/franzfon-arm64/asterisk
  --workdir PATH     Temporary build directory.
  --force            Replace an existing managed installation at --prefix.
  --keep-work        Keep build files for debugging.
  -h, --help         Show this help.

The installer compiles Asterisk 22.7.0 natively on ARM64, verifies the official
source archive, validates the FRANZFON-required modules and installs a disabled
systemd service. It does not install FreePBX, import runtime data, activate
services or alter the original FRANZFON licensing mechanism.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || { echo 'Missing value for --prefix' >&2; exit 2; }
      PREFIX="$2"; shift 2 ;;
    --workdir)
      [ "$#" -ge 2 ] || { echo 'Missing value for --workdir' >&2; exit 2; }
      WORK_DIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --keep-work) KEEP_WORK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
  arm64|aarch64) ;;
  *) echo "Unsupported architecture: $ARCH. Native ARM64 is required." >&2; exit 1 ;;
esac

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|raspbian:*|*:debian*) ;;
    *) echo "Unsupported OS family: ${ID:-unknown}. Debian-compatible ARM64 is required." >&2; exit 1 ;;
  esac
fi

PREFIX="$(realpath -m "$PREFIX")"
WORK_DIR="$(realpath -m "$WORK_DIR")"
case "$PREFIX" in
  /|/usr|/usr/local|/etc|/var|/opt)
    echo "Refusing unsafe installation prefix: $PREFIX" >&2
    exit 1
    ;;
esac

MANAGED_MARKER="$PREFIX/.franzfon-arm64-asterisk"
if [ -e "$PREFIX" ]; then
  if [ "$FORCE" -ne 1 ]; then
    echo "Installation prefix already exists: $PREFIX" >&2
    echo 'Use --force only to replace a previous managed installation.' >&2
    exit 1
  fi
  [ -f "$MANAGED_MARKER" ] || {
    echo "Refusing to replace an unmanaged directory: $PREFIX" >&2
    exit 1
  }
fi

cleanup() {
  if [ "$KEEP_WORK" -eq 0 ]; then
    rm -rf "$WORK_DIR"
  else
    echo "Build files retained at: $WORK_DIR"
  fi
}
trap cleanup EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential ca-certificates wget file pkg-config patch perl bzip2 xz-utils \
  bison flex python3 rsync \
  libedit-dev libxml2-dev libsqlite3-dev uuid-dev libssl-dev \
  libcurl4-openssl-dev libspeex-dev libspeexdsp-dev libogg-dev \
  libvorbis-dev libopus-dev libnewt-dev libncurses-dev libspandsp-dev \
  unixodbc-dev liburiparser-dev libxslt1-dev

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/source" "$WORK_DIR/stage"
chmod 0700 "$WORK_DIR"

printf '\n[1/8] Downloading and verifying Asterisk %s\n' "$ASTERISK_VERSION"
cd "$WORK_DIR/source"
wget -O asterisk.tar.gz "$ASTERISK_URL"
printf '%s  %s\n' "$ASTERISK_SHA256" asterisk.tar.gz | sha256sum -c -
tar -xzf asterisk.tar.gz
cd "asterisk-${ASTERISK_VERSION}"

printf '\n[2/8] Configuring native ARM64 build\n'
./configure \
  --prefix="$PREFIX" \
  --sysconfdir=/etc \
  --localstatedir=/var \
  --with-jansson-bundled \
  --with-pjproject-bundled

make menuselect.makeopts
menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts
menuselect/menuselect \
  --enable chan_pjsip \
  --enable res_pjsip \
  --enable res_http_websocket \
  --enable res_ari \
  --enable app_voicemail \
  --enable func_odbc \
  --enable cdr_adaptive_odbc \
  --enable res_odbc \
  menuselect.makeopts

printf '\n[3/8] Compiling Asterisk\n'
JOBS="$(nproc 2>/dev/null || echo 2)"
if [ "$JOBS" -gt 4 ]; then JOBS=4; fi
make -j"$JOBS"

REQUIRED_MODULES=(
  channels/chan_pjsip.so
  res/res_pjsip.so
  res/res_http_websocket.so
  res/res_ari.so
  apps/app_voicemail.so
  funcs/func_odbc.so
  cdr/cdr_adaptive_odbc.so
  res/res_odbc.so
)

printf '\n[4/8] Validating required modules\n'
for module in "${REQUIRED_MODULES[@]}"; do
  [ -f "$module" ] || { echo "Required module missing: $module" >&2; exit 1; }
  DESCRIPTION="$(file -b "$module")"
  case "$DESCRIPTION" in
    *ARM\ aarch64*) ;;
    *) echo "Module is not ARM64: $module: $DESCRIPTION" >&2; exit 1 ;;
  esac
  printf 'PASS  %s\n' "$module"
done

BINARY_DESCRIPTION="$(file -b main/asterisk)"
case "$BINARY_DESCRIPTION" in
  *ARM\ aarch64*) ;;
  *) echo "Asterisk binary is not ARM64: $BINARY_DESCRIPTION" >&2; exit 1 ;;
esac

printf '\n[5/8] Staging installation\n'
make DESTDIR="$WORK_DIR/stage" install
STAGED_BINARY="$WORK_DIR/stage$PREFIX/sbin/asterisk"
[ -x "$STAGED_BINARY" ] || { echo "Staged Asterisk binary missing: $STAGED_BINARY" >&2; exit 1; }

STAGED_DATA="$WORK_DIR/stage/var/lib/asterisk"
STAGED_CORE_XML="$(find "$STAGED_DATA/documentation" -maxdepth 1 -type f -name 'core-*.xml' -print -quit 2>/dev/null || true)"
[ -n "$STAGED_CORE_XML" ] || {
  echo 'Staged Asterisk XML documentation is missing.' >&2
  exit 1
}

printf '\n[6/8] Publishing managed installation\n'
if [ -e "$PREFIX" ]; then
  BACKUP="${PREFIX}.backup.$(date +%Y%m%d%H%M%S)"
  mv "$PREFIX" "$BACKUP"
  echo "Previous managed installation moved to: $BACKUP"
fi
mkdir -p "$(dirname "$PREFIX")"
rsync -a "$WORK_DIR/stage$PREFIX/" "$PREFIX/"

cat > "$MANAGED_MARKER" <<EOF
FRANZFON_ARM64_ASTERISK=1
ASTERISK_VERSION=$ASTERISK_VERSION
SOURCE_SHA256=$ASTERISK_SHA256
ARCHITECTURE=$(uname -m)
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0644 "$MANAGED_MARKER"

printf '\n[7/8] Registering managed shared libraries\n'
ASTERISK_SSL_LIBRARY="$(find "$PREFIX" -type f -name 'libasteriskssl.so.1' -print -quit)"
[ -n "$ASTERISK_SSL_LIBRARY" ] || {
  echo 'Managed libasteriskssl.so.1 was not installed.' >&2
  exit 1
}
ASTERISK_LIBRARY_DIR="$(dirname "$ASTERISK_SSL_LIBRARY")"
printf '%s\n' "$ASTERISK_LIBRARY_DIR" > /etc/ld.so.conf.d/franzfon-asterisk.conf
chmod 0644 /etc/ld.so.conf.d/franzfon-asterisk.conf
ldconfig
ldconfig -p | grep -F 'libasteriskssl.so.1' >/dev/null

if ! getent group asterisk >/dev/null; then
  groupadd --system asterisk
fi
if ! id asterisk >/dev/null 2>&1; then
  useradd --system --gid asterisk --home-dir /var/lib/asterisk \
    --shell /usr/sbin/nologin asterisk
fi

install -d -o asterisk -g asterisk -m 0750 \
  /var/lib/asterisk \
  /var/log/asterisk \
  /var/spool/asterisk \
  /var/spool/asterisk/voicemail \
  /var/run/asterisk
install -d -o root -g asterisk -m 0750 /etc/asterisk

rsync -a "$STAGED_DATA/" /var/lib/asterisk/
chown -R asterisk:asterisk /var/lib/asterisk
find /var/lib/asterisk/documentation -type d -exec chmod 0755 {} +
find /var/lib/asterisk/documentation -type f -exec chmod 0644 {} +
RUNTIME_CORE_XML="$(find /var/lib/asterisk/documentation -maxdepth 1 -type f -name 'core-*.xml' -print -quit)"
[ -s "$RUNTIME_CORE_XML" ] || {
  echo 'Published Asterisk XML documentation is missing.' >&2
  exit 1
}

cat > /etc/systemd/system/asterisk.service <<EOF
# FRANZFON-NATIVE-UNIT-v1
# Managed by the FRANZFON ARM64 port. Keep the marker above so the original
# FRANZFON first-boot migration does not replace this native ARM64 unit.
[Unit]
Description=Asterisk PBX for FRANZFON ARM64
After=network-online.target mariadb.service
Wants=network-online.target
ConditionPathExists=$PREFIX/sbin/asterisk

[Service]
Type=simple
User=asterisk
Group=asterisk
WorkingDirectory=/var/lib/asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0750
ExecStart=$PREFIX/sbin/asterisk -f -U asterisk -G asterisk
ExecReload=$PREFIX/sbin/asterisk -rx 'core reload'
ExecStop=$PREFIX/sbin/asterisk -rx 'core stop now'
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable asterisk.service >/dev/null 2>&1 || true
systemctl stop asterisk.service >/dev/null 2>&1 || true

printf '\n[8/8] Final native validation\n'
"$PREFIX/sbin/asterisk" -V
file "$PREFIX/sbin/asterisk"

printf '\nAsterisk ARM64 installation completed.\n'
printf 'Prefix:  %s\n' "$PREFIX"
printf 'Library: %s\n' "$ASTERISK_LIBRARY_DIR"
printf 'Service: asterisk.service (disabled and stopped)\n'
printf 'Next: install the sanitized FRANZFON configuration and run the bootstrap validation.\n'
