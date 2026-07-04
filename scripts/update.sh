#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-discuz-forum}"
APP_ROOT="${APP_ROOT:-/var/www/${APP_NAME}}"
REPO_DIR="${REPO_DIR:-${APP_ROOT}/repo}"
BRANCH="${BRANCH:-main}"
WEB_USER="${WEB_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"

log() {
  printf '[update] %s\n' "$*"
}

fail() {
  printf '[update] ERROR: %s\n' "$*" >&2
  exit 1
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

update_code() {
  [ -d "${REPO_DIR}/.git" ] || fail "${REPO_DIR} is not a Git checkout."
  log "Pulling ${BRANCH}"
  git -C "${REPO_DIR}" fetch origin "${BRANCH}"
  git -C "${REPO_DIR}" checkout "${BRANCH}"
  git -C "${REPO_DIR}" reset --hard "origin/${BRANCH}"
}

lint_php() {
  if ! command -v php >/dev/null 2>&1; then
    log "PHP CLI is not installed; skipping php -l."
    return
  fi

  log "Checking PHP syntax"
  while IFS= read -r -d '' file; do
    php -l "${file}" >/dev/null
  done < <(find "${REPO_DIR}/upload" -name '*.php' -type f -print0)
}

fix_permissions() {
  local web_root
  web_root="${REPO_DIR}/upload"
  log "Fixing runtime permissions"
  as_root chown -R "${WEB_USER}:${WEB_GROUP}" "${web_root}/data" "${web_root}/config"
  as_root find "${web_root}" -type d -exec chmod 755 {} \;
  as_root find "${web_root}" -type f -exec chmod 644 {} \;
  as_root chmod -R u+rwX,g+rwX "${web_root}/data" "${web_root}/config"
}

reload_services() {
  log "Reloading services"
  if command -v nginx >/dev/null 2>&1; then
    as_root nginx -t
    as_root systemctl reload nginx
  fi
  systemctl list-units --type=service --all 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | while read -r svc; do
    [ -n "${svc}" ] && as_root systemctl reload "${svc}" || true
  done
}

main() {
  update_code
  lint_php
  fix_permissions
  reload_services
  log "Update complete."
}

main "$@"
