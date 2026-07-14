#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-discuz-forum}"
APP_ROOT="${APP_ROOT:-/var/www/${APP_NAME}}"
REPO_DIR="${REPO_DIR:-${APP_ROOT}/repo}"
BRANCH="${BRANCH:-main}"
WEB_USER="${WEB_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
PREFLIGHT_DIR=""

log() {
  printf '[update] %s\n' "$*"
}

fail() {
  printf '[update] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [ -z "${PREFLIGHT_DIR}" ] || rm -rf "${PREFLIGHT_DIR}"
}

trap cleanup EXIT

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

update_code() {
  local target
  [ -d "${REPO_DIR}/.git" ] || fail "${REPO_DIR} is not a Git checkout."
  log "Pulling ${BRANCH}"
  git -C "${REPO_DIR}" fetch origin "${BRANCH}"
  target="$(git -C "${REPO_DIR}" rev-parse "origin/${BRANCH}")"
  preflight_php "${target}"
  git -C "${REPO_DIR}" checkout "${BRANCH}"
  git -C "${REPO_DIR}" reset --hard "${target}"
}

lint_php_tree() {
  local php_root="$1"
  if ! command -v php >/dev/null 2>&1; then
    log "PHP CLI is not installed; skipping php -l."
    return
  fi

  log "Checking PHP syntax"
  while IFS= read -r -d '' file; do
    php -l "${file}" >/dev/null
  done < <(find "${php_root}" -name '*.php' -type f -print0)
}

preflight_php() {
  local target="$1"
  if ! command -v php >/dev/null 2>&1; then
    log "PHP CLI is not installed; skipping preflight php -l."
    return
  fi

  PREFLIGHT_DIR="$(mktemp -d)"
  log "Checking PHP syntax before updating"
  git -C "${REPO_DIR}" archive "${target}" | tar -x -C "${PREFLIGHT_DIR}"
  lint_php_tree "${PREFLIGHT_DIR}/upload"
  rm -rf "${PREFLIGHT_DIR}"
  PREFLIGHT_DIR=""
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
  fix_permissions
  reload_services
  log "Update complete."
}

main "$@"
