#!/usr/bin/env bash
set -euo pipefail

ASTERISK_VERSION='22.7.0'
RELEASE_TAG='asterisk-22.7.0-arm64-v1'
ASSET="franzfon-asterisk-${ASTERISK_VERSION}-linux-arm64.tar.zst"
BASE_URL="https://github.com/DeineMutter1337/FrapzPifon/releases/download/${RELEASE_TAG}"
BUNDLE_URL="$BASE_URL/$ASSET"
SHA256_URL="$BASE_URL/$ASSET.sha256"
PREFIX='/opt/franzfon-arm64/asterisk'
FORCE=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./installer/franzfon-arm64-install-asterisk-bundle.sh [options]

Options:
  --bundle-url URL   Override the release bundle URL.
  --sha256-url URL   Override the SHA-256 file URL.
  --prefix PATH      Installation prefix. Default: /opt/franzfon-arm64/asterisk
  --force            Replace a previous managed installation.
  -h, --help         Show help.

Downloads a native AArch64 Asterisk 22.7.0 bundle produced by the repository's
native GitHub ARM64 runner. The SHA-256 digest, ELF architecture, required
modules and runtime documentation are validated before installation.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle-url) [ "$#" -ge 2 ] || exit 2; BUNDLE_URL="$2"; shift 2 ;;
    --sha256-url) [ "$#" -ge 2 ] || exit 2; SHA256_URL="$2"; shift 2 ;;
    --prefix) [ "$#" -ge 2 ] || exit 2; PREFIX="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in arm64|aarch64) ;; *) echo "Native ARM64 required, found: $ARCH" >&2; exit 1 ;; esac

PREFIX="$(realpath -m "$PREFIX")"
MANAGED_MARKER="$PREFIX/.franzfon-arm64-asterisk"
if [ -e "$PREFIX" ]; then
  if [ "$FORCE" -ne 1 ]; then
    echo "Installation prefix already exists: $PREFIX" >&2
    echo 'Use --force only for a previous managed installation.' >&2
    exit 1
  fi
  [ -f "$MANAGED_MARKER" ] || { echo "Refusing unmanaged prefix: $PREFIX" >&2; exit 1; }
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl zstd tar file binutils rsync \
  libedit2 libxml2 libsqlite3-0 libuuid1 libssl3 libcurl4 \
  libspeex1 libspeexdsp1 libogg0 libvorbis0a libopus0 \
  libnewt0.52 libncurses6 libspandsp2 unixodbc \
  liburiparser1 libxslt1.1

TMP="$(mktemp -d /var/tmp/franzfon-asterisk-bundle.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

printf '\n[1/6] Downloading verified native ARM64 bundle\n'
curl --fail --location --retry 4 "$BUNDLE_URL" --output "$ASSET"
curl --fail --location --retry 4 "$SHA256_URL" --output "$ASSET.sha256"
sha256sum -c "$ASSET.sha256"

printf '\n[2/6] Extracting and validating bundle\n'
mkdir stage
tar --zstd -xf "$ASSET" -C stage
STAGED_PREFIX="$TMP/stage$PREFIX"
STAGED_DATA="$TMP/stage/var/lib/asterisk"
BINARY="$STAGED_PREFIX/sbin/asterisk"
[ -x "$BINARY" ] || { echo 'Bundle Asterisk binary missing.' >&2; exit 1; }
[ -f "$STAGED_PREFIX/.franzfon-arm64-asterisk" ] || { echo 'Managed bundle marker missing.' >&2; exit 1; }
MACHINE="$(readelf -h "$BINARY" | awk '$1 == "Machine:" {print $2}')"
[ "$MACHINE" = AArch64 ] || { echo "Bundle binary is not AArch64: $MACHINE" >&2; exit 1; }

REQUIRED=(chan_pjsip.so res_pjsip.so res_http_websocket.so res_ari.so app_voicemail.so func_odbc.so cdr_adaptive_odbc.so res_odbc.so)
for module in "${REQUIRED[@]}"; do
  target="$STAGED_PREFIX/lib/asterisk/modules/$module"
  [ -f "$target" ] || { echo "Required module missing: $module" >&2; exit 1; }
  machine="$(readelf -h "$target" | awk '$1 == "Machine:" {print $2}')"
  [ "$machine" = AArch64 ] || { echo "Module is not AArch64: $module" >&2; exit 1; }
done
find "$STAGED_DATA/documentation" -maxdepth 1 -type f -name 'core-*.xml' -print -quit | grep -q . || {
  echo 'Asterisk XML documentation missing from bundle.' >&2
  exit 1
}

printf '\n[3/6] Publishing managed Asterisk runtime\n'
if [ -e "$PREFIX" ]; then
  BACKUP="${PREFIX}.backup.$(date +%Y%m%d%H%M%S)"
  mv "$PREFIX" "$BACKUP"
  echo "Previous installation moved to: $BACKUP"
fi
mkdir -p "$(dirname "$PREFIX")"
rsync -a "$STAGED_PREFIX/" "$PREFIX/"

printf '\n[4/6] Installing runtime data and service account\n'
getent group asterisk >/dev/null || groupadd --system asterisk
id asterisk >/dev/null 2>&1 || useradd --system --gid asterisk --home-dir /var/lib/asterisk --shell /usr/sbin/nologin asterisk
install -d -o asterisk -g asterisk -m 0750 \
  /var/lib/asterisk /var/log/asterisk /var/spool/asterisk \
  /var/spool/asterisk/voicemail /var/run/asterisk
install -d -o root -g asterisk -m 0750 /etc/asterisk
rsync -a "$STAGED_DATA/" /var/lib/asterisk/
chown -R asterisk:asterisk /var/lib/asterisk
find /var/lib/asterisk/documentation -type d -exec chmod 0755 {} +
find /var/lib/asterisk/documentation -type f -exec chmod 0644 {} +

printf '\n[5/6] Registering libraries and disabled systemd service\n'
SSL_LIBRARY="$(find "$PREFIX" -type f -name 'libasteriskssl.so.1' -print -quit)"
[ -n "$SSL_LIBRARY" ] || { echo 'libasteriskssl.so.1 missing.' >&2; exit 1; }
printf '%s\n' "$(dirname "$SSL_LIBRARY")" > /etc/ld.so.conf.d/franzfon-asterisk.conf
ldconfig

cat > /etc/systemd/system/asterisk.service <<EOF
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

printf '\n[6/6] Final native validation\n'
"$PREFIX/sbin/asterisk" -V
[ "$(readelf -h "$PREFIX/sbin/asterisk" | awk '$1 == "Machine:" {print $2}')" = AArch64 ]
systemctl is-enabled asterisk.service >/dev/null 2>&1 && { echo 'Asterisk service unexpectedly enabled.' >&2; exit 1; }

echo 'Verified Asterisk ARM64 bundle installed successfully and remains disabled.'
