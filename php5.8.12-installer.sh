#!/usr/bin/env bash
#
# install-php-8.5.12.sh
# Fresh install of PHP 8.5.12 (built from official source) on Ubuntu 24.04 / 26.04.
# Removes any previously installed PHP (apt packages, PPA, old source builds).
#
# Usage:   sudo bash install-php-8.5.12.sh [-y]
#   -y     skip the confirmation prompt
#
# Optional env vars:
#   PHP_SHA256=<hash>   verify the tarball checksum (hash is on php.net/downloads)
#   JOBS=<n>            parallel compile jobs (default: all CPU cores)

set -Eeuo pipefail

PHP_VERSION="8.5.12"
PHP_PREFIX="/usr/local/php-${PHP_VERSION}"
PHP_LINK="/usr/local/php"
PHP_CONF_DIR="/usr/local/etc/php"
PHP_URL_MAIN="https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz"
PHP_URL_MIRROR="https://github.com/php/php-src/archive/refs/tags/php-${PHP_VERSION}.tar.gz"
BUILD_DIR="/usr/local/src/php-build"
BACKUP_DIR="/root/php-backup-$(date +%Y%m%d-%H%M%S)"
JOBS="${JOBS:-$(nproc)}"
ASSUME_YES=0
[[ "${1:-}" == "-y" ]] && ASSUME_YES=1

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Failed at line $LINENO"' ERR

# ---------- checks ----------
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
. /etc/os-release
[[ "${ID}" == "ubuntu" ]] || die "This script supports Ubuntu only."
case "${VERSION_ID}" in
  24.04|26.04) ;;
  *) die "Unsupported Ubuntu ${VERSION_ID} (supported: 24.04, 26.04)." ;;
esac
log "Detected Ubuntu ${VERSION_ID}"

if [[ $ASSUME_YES -eq 0 ]]; then
  echo "This will REMOVE all existing PHP installations (apt packages, PPAs, /usr/local/php*)"
  echo "and install PHP ${PHP_VERSION} fresh. Configs are backed up to ${BACKUP_DIR}."
  read -r -p "Continue? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || die "Aborted."
fi

export DEBIAN_FRONTEND=noninteractive

# ---------- backup + remove previous PHP ----------
log "Backing up existing PHP configs"
mkdir -p "${BACKUP_DIR}"
for d in /etc/php "${PHP_CONF_DIR}" /usr/local/php /usr/local/lib/php.ini; do
  [[ -e "$d" ]] && cp -a "$d" "${BACKUP_DIR}/" 2>/dev/null || true
done

log "Stopping existing PHP-FPM services"
systemctl list-units --type=service --all --no-legend 'php*-fpm.service' 2>/dev/null \
  | awk '{print $1}' | while read -r svc; do
      [[ -n "$svc" ]] || continue
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
    done
systemctl stop php-fpm 2>/dev/null || true
systemctl disable php-fpm 2>/dev/null || true

log "Purging apt-installed PHP packages"
mapfile -t OLD_PKGS < <(dpkg-query -W -f='${Package}\n' 2>/dev/null \
  | grep -E '^(php[0-9.]*(-.*)?|libapache2-mod-php[0-9.]*|libphp[0-9.]*-embed)$' || true)
if [[ ${#OLD_PKGS[@]} -gt 0 ]]; then
  apt-get purge -y "${OLD_PKGS[@]}"
fi
apt-get autoremove -y

log "Removing Ondrej PHP PPA (if present)"
rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list \
      /etc/apt/sources.list.d/ondrej-ubuntu-php-*.sources \
      /etc/apt/sources.list.d/ondrej-*php*.list \
      /etc/apt/sources.list.d/ondrej-*php*.sources \
      /etc/apt/trusted.gpg.d/ondrej*.gpg \
      /etc/apt/trusted.gpg.d/*php*.gpg 2>/dev/null || true

log "Removing leftovers from previous source builds / alternatives"
rm -rf /usr/local/php /usr/local/php-* "${PHP_CONF_DIR}" /etc/php /var/lib/php/sessions.bak
rm -f /usr/local/bin/php /usr/local/bin/phpize /usr/local/bin/php-config \
      /usr/local/bin/phpdbg /usr/local/bin/php-cgi /usr/local/sbin/php-fpm \
      /etc/systemd/system/php-fpm.service /etc/systemd/system/php*-fpm.service
for tool in php phpize php-config phpdbg php-cgi php-fpm; do
  update-alternatives --remove-all "$tool" 2>/dev/null || true
done
hash -r

# ---------- build dependencies ----------
log "Installing build dependencies"
apt-get update
apt-get install -y --no-install-recommends \
  build-essential autoconf automake libtool bison re2c pkg-config make gcc g++ \
  curl ca-certificates xz-utils tar gnupg \
  libxml2-dev libssl-dev libcurl4-openssl-dev libsqlite3-dev libonig-dev \
  libzip-dev zlib1g-dev libbz2-dev libpng-dev libjpeg-dev libwebp-dev \
  libfreetype-dev libicu-dev libsodium-dev libargon2-dev libreadline-dev \
  libxslt1-dev libgmp-dev libpq-dev libffi-dev libsystemd-dev \
  libavif-dev

# ---------- download ----------
log "Downloading PHP ${PHP_VERSION}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if curl -fL --retry 3 -o php.tar.xz "${PHP_URL_MAIN}"; then
  TARBALL="php.tar.xz"
else
  warn "php.net unreachable, falling back to GitHub tag archive"
  curl -fL --retry 3 -o php.tar.gz "${PHP_URL_MIRROR}"
  TARBALL="php.tar.gz"
fi

if [[ -n "${PHP_SHA256:-}" ]]; then
  echo "${PHP_SHA256}  ${TARBALL}" | sha256sum -c - || die "Checksum mismatch!"
else
  warn "PHP_SHA256 not set - skipping checksum verification."
  warn "Get the hash from https://www.php.net/downloads and re-run with PHP_SHA256=... to verify."
fi

tar -xf "${TARBALL}"
cd "$(find . -maxdepth 1 -type d -name 'php-*' | head -n1)"
[[ -x ./configure ]] || ./buildconf --force

# ---------- configure / build / install ----------
log "Configuring"
./configure \
  --prefix="${PHP_PREFIX}" \
  --with-config-file-path="${PHP_CONF_DIR}" \
  --with-config-file-scan-dir="${PHP_CONF_DIR}/conf.d" \
  --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --with-fpm-systemd \
  --enable-cli \
  --enable-mbstring --enable-intl --enable-bcmath --enable-calendar \
  --enable-exif --enable-ftp --enable-pcntl --enable-soap --enable-sockets \
  --enable-sysvmsg --enable-sysvsem --enable-sysvshm --enable-opcache \
  --enable-gd --with-jpeg --with-webp --with-freetype --with-avif \
  --with-openssl --with-curl --with-zlib --with-bz2 --with-zip \
  --with-sodium --with-password-argon2 --with-readline \
  --with-xsl --with-gmp --with-ffi --with-sqlite3 \
  --with-pdo-sqlite --with-pdo-mysql=mysqlnd --with-mysqli=mysqlnd \
  --with-pgsql --with-pdo-pgsql 2>&1 | tail -n 30

log "Compiling with ${JOBS} jobs (this takes a while)"
make -j"${JOBS}"

log "Installing"
make install

# ---------- post install ----------
log "Creating symlinks and config"
ln -sfn "${PHP_PREFIX}" "${PHP_LINK}"
for bin in php phpize php-config phpdbg; do
  [[ -x "${PHP_LINK}/bin/${bin}" ]] && ln -sfn "${PHP_LINK}/bin/${bin}" "/usr/local/bin/${bin}"
done
ln -sfn "${PHP_LINK}/sbin/php-fpm" /usr/local/sbin/php-fpm

mkdir -p "${PHP_CONF_DIR}/conf.d" /var/log/php /run/php
SRC_DIR="$(pwd)"
cp "${SRC_DIR}/php.ini-production" "${PHP_CONF_DIR}/php.ini"
cp "${SRC_DIR}/php.ini-development" "${PHP_CONF_DIR}/php.ini-development"

# Opcache (zend_extension is not auto-loaded)
cat > "${PHP_CONF_DIR}/conf.d/10-opcache.ini" <<EOF
zend_extension=opcache
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
EOF

# PHP-FPM config
cp "${PHP_PREFIX}/etc/php-fpm.conf.default" "${PHP_PREFIX}/etc/php-fpm.conf"
cp "${PHP_PREFIX}/etc/php-fpm.d/www.conf.default" "${PHP_PREFIX}/etc/php-fpm.d/www.conf"
sed -i "s|^;pid = .*|pid = /run/php/php-fpm.pid|; s|^;error_log = .*|error_log = /var/log/php/php-fpm.log|" \
  "${PHP_PREFIX}/etc/php-fpm.conf"
sed -i "s|^listen = .*|listen = /run/php/php-fpm.sock|; \
        s|^;listen.owner = .*|listen.owner = www-data|; \
        s|^;listen.group = .*|listen.group = www-data|; \
        s|^;listen.mode = .*|listen.mode = 0660|" \
  "${PHP_PREFIX}/etc/php-fpm.d/www.conf"

# systemd unit
cat > /etc/systemd/system/php-fpm.service <<EOF
[Unit]
Description=PHP ${PHP_VERSION} FastCGI Process Manager
After=network.target

[Service]
Type=notify
PIDFile=/run/php/php-fpm.pid
RuntimeDirectory=php
RuntimeDirectoryPreserve=yes
ExecStart=${PHP_PREFIX}/sbin/php-fpm --nodaemonize --fpm-config ${PHP_PREFIX}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
PrivateTmp=true
ProtectSystem=full
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
"${PHP_PREFIX}/sbin/php-fpm" -t --fpm-config "${PHP_PREFIX}/etc/php-fpm.conf"
systemctl enable --now php-fpm

# ---------- verify ----------
log "Verifying"
INSTALLED="$(php -r 'echo PHP_VERSION;')"
[[ "${INSTALLED}" == "${PHP_VERSION}" ]] || die "Version mismatch: got ${INSTALLED}"
php -v
echo
echo "PHP-FPM status: $(systemctl is-active php-fpm)"
echo "FPM socket:     /run/php/php-fpm.sock"
echo "php.ini:        ${PHP_CONF_DIR}/php.ini"
echo "Config backup:  ${BACKUP_DIR}"

rm -rf "${BUILD_DIR}"
log "PHP ${PHP_VERSION} installed successfully."
