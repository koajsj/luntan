#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-discuz-forum}"
APP_ROOT="${APP_ROOT:-/var/www/${APP_NAME}}"
REPO_DIR="${REPO_DIR:-${APP_ROOT}/repo}"
REPO_URL="${REPO_URL:-}"
BRANCH="${BRANCH:-main}"
SERVER_NAME="${SERVER_NAME:-_}"
DB_NAME="${DB_NAME:-discuz}"
DB_USER="${DB_USER:-discuz}"
TABLE_PREFIX="${TABLE_PREFIX:-pre_}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-qwer@1234}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ENABLE_HTTPS="${ENABLE_HTTPS:-0}"
WEB_USER="${WEB_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
SECRETS_DIR="${SECRETS_DIR:-${APP_ROOT}/.secrets}"
DB_PASS_FILE="${DB_PASS_FILE:-${SECRETS_DIR}/db_password}"
AUTHKEY_FILE="${AUTHKEY_FILE:-${SECRETS_DIR}/authkey}"

log() {
  printf '[deploy] %s\n' "$*"
}

fail() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

validate_deploy_inputs() {
  [[ "${APP_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "APP_NAME contains unsupported characters."
  [[ "${BRANCH}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "BRANCH contains unsupported characters."
  [[ "${SERVER_NAME}" = "_" || "${SERVER_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "SERVER_NAME must be a hostname, IP address, or _."
  [[ "${DB_NAME}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "DB_NAME must be a SQL identifier."
  [[ "${DB_USER}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "DB_USER must be a SQL identifier."
  [[ "${TABLE_PREFIX}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "TABLE_PREFIX must be a SQL identifier prefix."
  [[ "${WEB_USER}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || fail "WEB_USER contains unsupported characters."
  [[ "${WEB_GROUP}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || fail "WEB_GROUP contains unsupported characters."
  [[ "${APP_ROOT}" =~ ^/[A-Za-z0-9_./-]*$ ]] || fail "APP_ROOT must be an absolute path without spaces."
  [[ "${REPO_DIR}" =~ ^/[A-Za-z0-9_./-]*$ ]] || fail "REPO_DIR must be an absolute path without spaces."
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '\n'
  else
    tr -dc 'A-Za-z0-9_@%+=' </dev/urandom | head -c 48
  fi
}

detect_repo_url() {
  local script_dir source_dir detected
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source_dir="$(cd "${script_dir}/.." && pwd)"
  detected="$(git -C "${source_dir}" remote get-url origin 2>/dev/null || true)"
  printf '%s' "${detected}"
}

source_checkout_dir() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "${script_dir}/.." && pwd
}

install_packages() {
  command -v apt-get >/dev/null 2>&1 || fail "This script currently supports Debian/Ubuntu apt-based VPS images."
  export DEBIAN_FRONTEND=noninteractive
  log "Installing system packages"
  as_root apt-get update
  as_root apt-get install -y nginx mariadb-server git rsync curl ca-certificates openssl \
    php-fpm php-cli php-mysql php-gd php-curl php-mbstring php-xml php-zip php-intl
}

ensure_services() {
  as_root systemctl enable --now mariadb >/dev/null 2>&1 || as_root systemctl enable --now mysql >/dev/null 2>&1 || true
  as_root systemctl enable --now nginx >/dev/null 2>&1 || true
}

ensure_code() {
  local source_dir
  source_dir="$(source_checkout_dir)"
  if [ -z "${REPO_URL}" ]; then
    REPO_URL="$(detect_repo_url)"
  fi

  as_root mkdir -p "${APP_ROOT}"
  as_root chown -R "$(id -un):$(id -gn)" "${APP_ROOT}"

  if [ -d "${REPO_DIR}/.git" ]; then
    log "Updating existing checkout"
    git -C "${REPO_DIR}" fetch origin "${BRANCH}"
    git -C "${REPO_DIR}" checkout "${BRANCH}"
    git -C "${REPO_DIR}" reset --hard "origin/${BRANCH}"
  else
    if [ -d "${source_dir}/.git" ] && [ "${source_dir}" != "${REPO_DIR}" ]; then
      log "Bootstrapping deployment checkout from ${source_dir}"
      mkdir -p "${REPO_DIR}"
      rsync -a --delete "${source_dir}/" "${REPO_DIR}/"
      git -C "${REPO_DIR}" checkout "${BRANCH}" >/dev/null 2>&1 || true
    else
      [ -n "${REPO_URL}" ] || fail "REPO_URL is empty and no Git origin could be detected. Run from a cloned repo or set REPO_URL."
      log "Cloning ${REPO_URL}"
      git clone --branch "${BRANCH}" "${REPO_URL}" "${REPO_DIR}"
    fi
  fi

  [ -d "${REPO_DIR}/upload" ] || fail "Expected ${REPO_DIR}/upload to exist."
}

ensure_secrets() {
  as_root mkdir -p "${SECRETS_DIR}"
  as_root chown -R "$(id -un):$(id -gn)" "${SECRETS_DIR}"
  as_root chmod 700 "${SECRETS_DIR}"

  if [ ! -f "${DB_PASS_FILE}" ]; then
    random_secret >"${DB_PASS_FILE}"
    chmod 600 "${DB_PASS_FILE}"
  fi
  if [ ! -f "${AUTHKEY_FILE}" ]; then
    random_secret >"${AUTHKEY_FILE}"
    chmod 600 "${AUTHKEY_FILE}"
  fi
}

ensure_database() {
  local db_pass
  db_pass="$(cat "${DB_PASS_FILE}")"
  [[ "${db_pass}" != *"'"* && "${db_pass}" != *$'\n'* && "${db_pass}" != *$'\r'* ]] || fail "Database password file contains unsupported characters."
  log "Creating database and application user when needed"
  as_root mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${db_pass}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

write_config() {
  local web_root db_pass authkey scheme forcehttps
  web_root="${REPO_DIR}/upload"
  db_pass="$(cat "${DB_PASS_FILE}")"
  authkey="$(cat "${AUTHKEY_FILE}")"
  scheme="http"
  forcehttps="0"
  if [ "${ENABLE_HTTPS}" = "1" ]; then
    scheme="https"
    forcehttps="1"
  fi

  log "Writing Discuz config files when missing"
  mkdir -p "${web_root}/config" "${web_root}/data" "${web_root}/data/log"

  if [ ! -f "${web_root}/config/config_global.php" ]; then
    (cd "${REPO_DIR}" && DB_HOST="127.0.0.1" DB_USER="${DB_USER}" DB_PASS="${db_pass}" DB_NAME="${DB_NAME}" TABLE_PREFIX="${TABLE_PREFIX}" AUTHKEY="${authkey}" FORCEHTTPS="${forcehttps}" \
      php -r '
        $path = getenv("PWD")."/upload/config/config_global_default.php";
        include $path;
        $_config["db"][1]["dbhost"] = getenv("DB_HOST");
        $_config["db"][1]["dbuser"] = getenv("DB_USER");
        $_config["db"][1]["dbpw"] = getenv("DB_PASS");
        $_config["db"][1]["dbname"] = getenv("DB_NAME");
        $_config["db"][1]["dbcharset"] = "utf8mb4";
        $_config["db"][1]["tablepre"] = getenv("TABLE_PREFIX");
        $_config["security"]["authkey"] = getenv("AUTHKEY");
        $_config["security"]["error"]["showerror"] = "0";
        $_config["security"]["error"]["guessplugin"] = "0";
        $_config["output"]["forcehttps"] = intval(getenv("FORCEHTTPS"));
        $_config["cookie"]["samesite"] = "Lax";
        $_config["admincp"]["mustlogin"] = 1;
        $out = "<?php\n\n\$_config = ".var_export($_config, true).";\n";
        file_put_contents(getenv("PWD")."/upload/config/config_global.php", $out);
      ')
  fi

  if [ ! -f "${web_root}/config/config_ucenter.php" ]; then
    cat >"${web_root}/config/config_ucenter.php" <<PHP
<?php
require __DIR__.'/config_global.php';
define('UC_CONNECT', 'mysql');
define('UC_STANDALONE', 1);
define('UC_DBHOST', \$_config['db'][1]['dbhost']);
define('UC_DBUSER', \$_config['db'][1]['dbuser']);
define('UC_DBPW', \$_config['db'][1]['dbpw']);
define('UC_DBNAME', \$_config['db'][1]['dbname']);
define('UC_DBCHARSET', 'utf8mb4');
define('UC_DBTABLEPRE', '`'.\$_config['db'][1]['dbname'].'`.'.\$_config['db'][1]['tablepre'].'ucenter_');
define('UC_DBCONNECT', '0');
define('UC_AVTURL', '');
define('UC_AVTPATH', '');
define('UC_KEY', \$_config['security']['authkey']);
define('UC_API', '${scheme}://${SERVER_NAME}');
define('UC_CHARSET', 'utf-8');
define('UC_IP', '127.0.0.1');
define('UC_APPID', '1');
define('UC_PPP', '20');
?>
PHP
  fi
}

run_auto_install() {
  local db_pass authkey site_url
  db_pass="$(cat "${DB_PASS_FILE}")"
  authkey="$(cat "${AUTHKEY_FILE}")"
  site_url="http://${SERVER_NAME}"
  if [ "${SERVER_NAME}" = "_" ]; then
    site_url="http://127.0.0.1"
  fi
  if [ "${ENABLE_HTTPS}" = "1" ] && [ "${SERVER_NAME}" != "_" ]; then
    site_url="https://${SERVER_NAME}"
  fi

  if [ -f "${REPO_DIR}/upload/data/install.lock" ]; then
    log "Discuz install.lock exists; skipping first-time installer"
    return
  fi

  log "Running non-interactive Discuz first-time installer"
  (cd "${REPO_DIR}" && \
    DB_HOST="127.0.0.1" DB_USER="${DB_USER}" DB_PASS="${db_pass}" DB_NAME="${DB_NAME}" TABLE_PREFIX="${TABLE_PREFIX}" \
    AUTHKEY="${authkey}" ADMIN_USER="${ADMIN_USER}" ADMIN_PASS="${ADMIN_PASS}" ADMIN_EMAIL="${ADMIN_EMAIL}" \
    SERVER_NAME="${SERVER_NAME}" SITE_URL="${site_url}" php scripts/auto_install.php)
}

detect_php_fpm() {
  local sock service
  sock="$(find /run/php -maxdepth 1 -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n 1 || true)"
  if [ -n "${sock}" ]; then
    printf 'unix:%s' "${sock}"
    return
  fi
  service="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | sort -V | tail -n 1 || true)"
  [ -n "${service}" ] && as_root systemctl enable --now "${service}" >/dev/null 2>&1 || true
  sock="$(find /run/php -maxdepth 1 -name 'php*-fpm.sock' 2>/dev/null | sort -V | tail -n 1 || true)"
  [ -n "${sock}" ] || fail "Could not detect PHP-FPM socket."
  printf 'unix:%s' "${sock}"
}

write_nginx() {
  local fpm_pass conf
  fpm_pass="$(detect_php_fpm)"
  conf="/etc/nginx/sites-available/${APP_NAME}.conf"
  log "Writing Nginx site ${conf}"
  as_root tee "${conf}" >/dev/null <<NGINX
server {
    listen 80;
    server_name ${SERVER_NAME};
    root ${REPO_DIR}/upload;
    index index.php index.html index.htm;

    client_max_body_size 64m;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ^~ /install/ {
        if (-f \$document_root/data/install.lock) { return 403; }
        try_files \$uri \$uri/ =404;
    }

    location ^~ /config/ {
        deny all;
    }

    location ^~ /data/log/ {
        deny all;
    }

    location ^~ /data/backup/ {
        deny all;
    }

    location ~ ^/data/backup_[^/]+/ {
        deny all;
    }

    location ~ /\. {
        deny all;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass ${fpm_pass};
    }
}
NGINX
  as_root ln -sfn "${conf}" "/etc/nginx/sites-enabled/${APP_NAME}.conf"
  if [ -e /etc/nginx/sites-enabled/default ]; then
    as_root rm -f /etc/nginx/sites-enabled/default
  fi
  as_root nginx -t
}

fix_permissions() {
  local web_root
  web_root="${REPO_DIR}/upload"
  log "Fixing filesystem permissions"
  as_root chown -R "${WEB_USER}:${WEB_GROUP}" "${web_root}/data" "${web_root}/config"
  as_root find "${web_root}" -type d -exec chmod 755 {} \;
  as_root find "${web_root}" -type f -exec chmod 644 {} \;
  as_root chmod -R u+rwX,g+rwX "${web_root}/data" "${web_root}/config"
}

reload_services() {
  log "Reloading services"
  as_root systemctl reload nginx
  systemctl list-units --type=service --all 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | while read -r svc; do
    [ -n "${svc}" ] && as_root systemctl reload "${svc}" || true
  done
}

main() {
  validate_deploy_inputs
  install_packages
  ensure_services
  ensure_code
  ensure_secrets
  ensure_database
  write_config
  run_auto_install
  write_nginx
  fix_permissions
  reload_services

  log "Deployment prepared."
  log "Web root: ${REPO_DIR}/upload"
  log "Database: ${DB_NAME}, user: ${DB_USER}, password file: ${DB_PASS_FILE}"
  log "Admin: ${ADMIN_USER} / ${ADMIN_PASS}"
}

main "$@"
