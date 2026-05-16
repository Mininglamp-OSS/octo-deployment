#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# OCTO Deployment · Interactive Setup Script
# -----------------------------------------------------------------------------
# Generates docker/.env from docker/.env.example with rotated secrets,
# user-chosen domain/IP, and optional TLS / LLM summary toggles.
#
# Usage:
#   ./setup.sh                        # interactive mode
#   ./setup.sh --non-interactive      # all defaults + auto-detect
#   ./setup.sh --domain octo.example.com --ip 1.2.3.4 --https --summary
#
# Requires: bash ≥4, openssl, docker, docker compose
# -----------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
DOMAIN="octo.local"
EXTERNAL_IP=""
ENABLE_HTTPS=false
ENABLE_SUMMARY=false
NON_INTERACTIVE=false
FORCE_OVERWRITE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_EXAMPLE="${SCRIPT_DIR}/docker/.env.example"
ENV_OUT="${SCRIPT_DIR}/docker/.env"

# ── Colours / helpers ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; RESET=''
fi

info()  { printf '%s[setup]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn()  { printf '%s[setup]%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
err()   { printf '%s[setup]%s %s\n' "${RED}" "${RESET}" "$*" >&2; }
fatal() { err "$@"; exit 1; }

# Portable in-place sed (GNU + BSD/macOS compatible).
# GNU sed accepts `sed -i "..."`; BSD/macOS sed requires `-i ''` (an
# explicit, possibly empty, backup-extension argument). Without this
# shim, `sed -i "s|foo|bar|" file` on macOS errors out with
# "extra characters at the end of p command" because BSD sed treats
# the next argument as the backup suffix.
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    # GNU sed
    sed -i "$@"
  else
    # BSD/macOS sed needs an explicit (empty) backup extension
    sed -i '' "$@"
  fi
}

# ── Parse CLI arguments ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --force)   FORCE_OVERWRITE=true; shift ;;
    --domain)   DOMAIN="${2:?--domain requires a value}";   shift 2 ;;
    --ip)       EXTERNAL_IP="${2:?--ip requires a value}";  shift 2 ;;
    --https)    ENABLE_HTTPS=true;   shift ;;
    --summary)  ENABLE_SUMMARY=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--non-interactive] [--force] [--domain <d>] [--ip <ip>] [--https] [--summary]"
      exit 0
      ;;
    *) fatal "Unknown argument: $1" ;;
  esac
done

# ── Pre-flight checks ───────────────────────────────────────────────────────
info "Checking prerequisites…"

if ! command -v docker &>/dev/null; then
  fatal "docker is not installed. Install Docker first: https://docs.docker.com/get-docker/"
fi

DOCKER_VERSION="$(docker --version 2>/dev/null || true)"
info "Docker: ${DOCKER_VERSION}"

if docker compose version &>/dev/null; then
  COMPOSE_VERSION="$(docker compose version 2>/dev/null || true)"
  info "Compose: ${COMPOSE_VERSION}"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_VERSION="$(docker-compose --version 2>/dev/null || true)"
  info "Compose (standalone): ${COMPOSE_VERSION}"
else
  fatal "docker compose is not available. Install the Compose plugin: https://docs.docker.com/compose/install/"
fi

if ! command -v openssl &>/dev/null; then
  fatal "openssl is not installed. Install it before running setup."
fi

# curl is used only for external-IP auto-detection. Missing curl is not
# fatal — detect_ip falls back to 127.0.0.1 — but warn so the operator
# knows why EXTERNAL_IP came out as loopback.
if ! command -v curl &>/dev/null; then
  warn "curl is not installed; external IP auto-detection will fall back to 127.0.0.1."
  warn "Pass --ip <address> explicitly, or install curl, for a public IP."
fi

if [[ ! -f "${ENV_EXAMPLE}" ]]; then
  fatal "Cannot find ${ENV_EXAMPLE}. Run this script from the repository root."
fi

# ── Guard against overwriting an existing .env ─────────────────────────────
# Re-running setup.sh regenerates ALL secrets (MySQL root password, MinIO
# credentials, admin password, etc.). If the stack has already been started,
# the MySQL volume keeps the ORIGINAL passwords from the first `docker compose
# up`; overwriting .env makes every service fail to connect. The guard below
# prevents accidental overwrites; use --force to bypass.
if [[ -f "${ENV_OUT}" ]] && [[ "${FORCE_OVERWRITE}" != "true" ]]; then
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    fatal "docker/.env already exists. Use --force to overwrite."
  else
    warn "docker/.env already exists. Overwriting will regenerate ALL secrets."
    warn "If the stack has been started, this will break database connections."
    read -rp "Overwrite? [y/N]: " confirm
    case "${confirm}" in
      [yY]|[yY][eE][sS]) info "Overwriting..." ;;
      *) info "Aborted."; exit 0 ;;
    esac
  fi
fi

# ── Detect external IP ──────────────────────────────────────────────────────
detect_ip() {
  local ip=""
  ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -s --max-time 5 icanhazip.com 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="127.0.0.1"
  fi
  echo "${ip}"
}

# ── Interactive prompts ─────────────────────────────────────────────────────
if [[ "${NON_INTERACTIVE}" == "false" ]]; then
  echo ""
  printf '%sOCTO Deployment Setup%s\n' "${BOLD}" "${RESET}"
  echo "This script generates docker/.env with secure random secrets."
  echo ""

  # Domain
  read -rp "Domain name [${DOMAIN}]: " user_domain
  DOMAIN="${user_domain:-${DOMAIN}}"

  # External IP
  info "Detecting external IP…"
  detected_ip="$(detect_ip)"
  read -rp "External IP [${detected_ip}]: " user_ip
  EXTERNAL_IP="${user_ip:-${detected_ip}}"

  # HTTPS
  read -rp "Enable HTTPS? [y/N]: " user_https
  case "${user_https}" in
    [yY]|[yY][eE][sS]) ENABLE_HTTPS=true ;;
    *) ENABLE_HTTPS=false ;;
  esac

  # Summary (LLM)
  read -rp "Enable LLM summary service? [y/N]: " user_summary
  case "${user_summary}" in
    [yY]|[yY][eE][sS]) ENABLE_SUMMARY=true ;;
    *) ENABLE_SUMMARY=false ;;
  esac
else
  # Non-interactive: auto-detect IP if not provided via --ip
  if [[ -z "${EXTERNAL_IP}" ]]; then
    info "Auto-detecting external IP…"
    EXTERNAL_IP="$(detect_ip)"
  fi
fi

info "Domain:     ${DOMAIN}"
info "External IP: ${EXTERNAL_IP}"
info "HTTPS:      ${ENABLE_HTTPS}"
info "Summary:    ${ENABLE_SUMMARY}"

# ── Generate secrets ────────────────────────────────────────────────────────
info "Generating random secrets…"

MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"
MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"
OCTO_MINIO_APP_PASSWORD="$(openssl rand -hex 24)"
OCTO_MATTER_DB_PASSWORD="$(openssl rand -hex 16)"
OCTO_SUMMARY_DB_PASSWORD="$(openssl rand -hex 16)"
OCTO_SUMMARY_READER_PASSWORD="$(openssl rand -hex 16)"
OCTO_MASTER_KEY="$(openssl rand -hex 16)"
OCTO_NOTIFY_INTERNAL_TOKEN="$(openssl rand -hex 32)"
OCTO_WUKONGIM_MANAGER_TOKEN="$(openssl rand -hex 32)"
OCTO_ADMIN_PWD="$(openssl rand -base64 18)"

# ── Build .env from template ────────────────────────────────────────────────
info "Generating docker/.env from template…"

cp "${ENV_EXAMPLE}" "${ENV_OUT}"
# The .env file holds DB passwords, admin password, MinIO root credentials
# and notify/manager tokens. `cp` honors the inherited umask (typically
# 022 → 0644 = world-readable), which would let any local user on the
# host read every secret in the stack. Lock the file down to the owner
# only before we write the generated values into it.
chmod 600 "${ENV_OUT}"

# Replace domain and IP
sed_inplace "s|^OCTO_DOMAIN=.*|OCTO_DOMAIN=${DOMAIN}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_EXTERNAL_IP=.*|OCTO_EXTERNAL_IP=${EXTERNAL_IP}|" "${ENV_OUT}"

# Replace all CHANGE_ME / placeholder passwords
sed_inplace "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_MINIO_APP_PASSWORD=.*|OCTO_MINIO_APP_PASSWORD=${OCTO_MINIO_APP_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_MATTER_DB_PASSWORD=.*|OCTO_MATTER_DB_PASSWORD=${OCTO_MATTER_DB_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_SUMMARY_DB_PASSWORD=.*|OCTO_SUMMARY_DB_PASSWORD=${OCTO_SUMMARY_DB_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_SUMMARY_READER_PASSWORD=.*|OCTO_SUMMARY_READER_PASSWORD=${OCTO_SUMMARY_READER_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_MASTER_KEY=.*|OCTO_MASTER_KEY=${OCTO_MASTER_KEY}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_NOTIFY_INTERNAL_TOKEN=.*|OCTO_NOTIFY_INTERNAL_TOKEN=${OCTO_NOTIFY_INTERNAL_TOKEN}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_WUKONGIM_MANAGER_TOKEN=.*|OCTO_WUKONGIM_MANAGER_TOKEN=${OCTO_WUKONGIM_MANAGER_TOKEN}|" "${ENV_OUT}"

# Set WK_MODE to release
sed_inplace "s|^WK_MODE=.*|WK_MODE=release|" "${ENV_OUT}"

# Replace admin password
sed_inplace "s|^OCTO_ADMIN_PWD=.*|OCTO_ADMIN_PWD=${OCTO_ADMIN_PWD}|" "${ENV_OUT}"
# If the line was commented, uncomment it
sed_inplace "s|^# *OCTO_ADMIN_PWD=.*|OCTO_ADMIN_PWD=${OCTO_ADMIN_PWD}|" "${ENV_OUT}"

# TLS setting
if [[ "${ENABLE_HTTPS}" == "true" ]]; then
  sed_inplace "s|^OCTO_TLS_ENABLED=.*|OCTO_TLS_ENABLED=true|" "${ENV_OUT}"
else
  sed_inplace "s|^OCTO_TLS_ENABLED=.*|OCTO_TLS_ENABLED=false|" "${ENV_OUT}"
fi

# Summary setting
# OCTO_ENABLE_SUMMARY itself is just an informational comment in
# .env.example (Compose profiles are the real on/off switch), so we
# only flip COMPOSE_PROFILES below — no sed against OCTO_ENABLE_SUMMARY
# is needed (and any such sed would be a no-op against the commented
# template line).
if [[ "${ENABLE_SUMMARY}" == "true" ]]; then
  # Activate the summary Docker Compose profile so that
  # `docker compose up -d` (without --profile) starts summary services.
  if grep -q '^COMPOSE_PROFILES=' "${ENV_OUT}"; then
    sed_inplace "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=summary|" "${ENV_OUT}"
  elif grep -q '^# *COMPOSE_PROFILES=' "${ENV_OUT}"; then
    sed_inplace "s|^# *COMPOSE_PROFILES=.*|COMPOSE_PROFILES=summary|" "${ENV_OUT}"
  else
    printf '\n# Activate summary services (summary-api + summary-worker)\nCOMPOSE_PROFILES=summary\n' >> "${ENV_OUT}"
  fi
fi

# ── Print summary ───────────────────────────────────────────────────────────
echo ""
printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
printf '%s  docker/.env generated successfully!%s\n' "${GREEN}" "${RESET}"
printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
echo ""
printf '  Domain:         %s%s%s\n' "${BOLD}" "${DOMAIN}" "${RESET}"
printf '  External IP:    %s%s%s\n' "${BOLD}" "${EXTERNAL_IP}" "${RESET}"
printf '  Admin user:     %ssuperAdmin%s\n' "${BOLD}" "${RESET}"
printf '  Admin password: %s%s%s\n' "${BOLD}" "${OCTO_ADMIN_PWD}" "${RESET}"
echo ""

if [[ "${ENABLE_HTTPS}" == "true" ]]; then
  warn "HTTPS enabled. Place your certificates in docker/certs/:"
  echo "  - docker/certs/fullchain.pem"
  echo "  - docker/certs/privkey.pem"
  echo ""
  warn "Then uncomment the HTTPS server block in docker/nginx/conf.d/octo.conf.template"
  warn "and the 443 port + certs volume in docker/docker-compose.yaml."
  echo ""
fi

if [[ "${ENABLE_SUMMARY}" == "true" ]]; then
  info "Summary service enabled. Set LLM_API_KEY in docker/.env before using."
  echo "  Start with: cd docker && docker compose up -d"
else
  info "Summary service disabled. Start without LLM:"
  echo "  cd docker && docker compose up -d"
fi

echo ""
info "Next steps:"
echo "  1. Review docker/.env and adjust as needed"
echo "  2. cd docker && docker compose up -d"

echo "  3. Visit http://${DOMAIN}:28080"
echo ""
printf '%s  ⚠  Save the admin password above — it is NOT stored elsewhere.%s\n' "${YELLOW}" "${RESET}"
echo ""
