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

# Track which configuration values were supplied explicitly via CLI flags
# so the interactive prompts (when invoked without --non-interactive)
# don't silently overwrite them. See README.md examples like:
#   ./setup.sh --summary --domain octo.example.com --ip 1.2.3.4
# When any of these "decision" flags are set we auto-switch to
# non-interactive mode — the operator has already made the choice.
DOMAIN_SET_VIA_CLI=false
IP_SET_VIA_CLI=false
HTTPS_SET_VIA_CLI=false
SUMMARY_SET_VIA_CLI=false

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
    --domain)   DOMAIN="${2:?--domain requires a value}";   DOMAIN_SET_VIA_CLI=true;  shift 2 ;;
    --ip)       EXTERNAL_IP="${2:?--ip requires a value}";  IP_SET_VIA_CLI=true;      shift 2 ;;
    --https)    ENABLE_HTTPS=true;   HTTPS_SET_VIA_CLI=true;   shift ;;
    --summary)  ENABLE_SUMMARY=true; SUMMARY_SET_VIA_CLI=true; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: setup.sh [--non-interactive] [--force] [--domain <d>] [--ip <ip>] [--https] [--summary]

  --non-interactive   Skip prompts; use defaults + auto-detect for anything
                      not provided via flags.
  --force             Overwrite an existing docker/.env without prompting.
  --domain <d>        Set OCTO_DOMAIN (default: octo.local).
  --ip <ip>           Set OCTO_EXTERNAL_IP (skip auto-detect).
  --https             HTTPS preparation flag. Sets OCTO_TLS_ENABLED=true and
                      prints HTTPS activation instructions. This does NOT
                      fully enable HTTPS — you still need to install certs
                      and edit nginx + docker-compose manually. See
                      docker/certs/README.md for the full procedure.
  --summary           Enable the optional LLM summary services
                      (COMPOSE_PROFILES=summary).

When any of --domain / --ip / --https / --summary is given without
--non-interactive, setup.sh treats the flags as your decisions and runs
non-interactively so the documented one-liner forms (see docker/README.md)
work as written.
USAGE
      exit 0
      ;;
    *) fatal "Unknown argument: $1" ;;
  esac
done

# If the operator supplied any "decision" flag (--domain / --ip / --https
# / --summary) but did not pass --non-interactive, treat those flags as
# the decision and skip the prompts. Otherwise the interactive section
# would silently overwrite --ip with the auto-detected value, and would
# reset --https / --summary to false unless the user re-entered "y" at
# the prompt — exactly the breakage Jerry-Xin flagged in PR#18 R5.
if [[ "${NON_INTERACTIVE}" == "false" ]]; then
  if [[ "${DOMAIN_SET_VIA_CLI}" == "true" \
     || "${IP_SET_VIA_CLI}" == "true" \
     || "${HTTPS_SET_VIA_CLI}" == "true" \
     || "${SUMMARY_SET_VIA_CLI}" == "true" ]]; then
    info "CLI flags supplied; switching to non-interactive mode."
    info "(Pass no flags, or only --force, to get the interactive prompts.)"
    NON_INTERACTIVE=true
  fi
fi

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

# ── Pre-flight: warn on overlapping OCTO deployments ───────────────────────
# INCIDENT-2026-05-16-001 root cause: docker-compose.yaml pins `name: octo`,
# so a fresh clone in (e.g.) /tmp shares the SAME named volumes / container
# namespace as a production stack already running on the host. A routine
# `docker compose down -v` from the new clone then wipes the production
# volumes. We rotated all named volumes onto `${COMPOSE_PROJECT_NAME:-octo}-*`
# in docker-compose.yaml so an explicit `COMPOSE_PROJECT_NAME=octo-<suffix>`
# fully isolates a second stack — but operators only get that isolation if
# they remember to set the env var. This check looks for existing OCTO
# state on the host and (without blocking the run) tells the operator how
# to isolate before they `up -d` and collide.
preflight_existing_octo() {
  command -v docker &>/dev/null || return 0
  docker info >/dev/null 2>&1 || return 0

  local existing_volumes existing_containers
  existing_volumes="$(docker volume ls --format '{{.Name}}' 2>/dev/null \
                       | grep -E '(^|-)octo(-|$)' || true)"
  existing_containers="$(docker ps -a --filter 'name=octo' --format '{{.Names}}' 2>/dev/null \
                       | grep -E '(^|-)octo(-|$)' || true)"

  if [[ -z "${existing_volumes}" && -z "${existing_containers}" ]]; then
    return 0
  fi

  warn ""
  warn "⚠  Detected EXISTING OCTO state on this host:"
  if [[ -n "${existing_volumes}" ]]; then
    warn "    Docker volumes:"
    while IFS= read -r v; do warn "      - ${v}"; done <<< "${existing_volumes}"
  fi
  if [[ -n "${existing_containers}" ]]; then
    warn "    Docker containers:"
    while IFS= read -r c; do warn "      - ${c}"; done <<< "${existing_containers}"
  fi
  warn ""
  warn "Bringing this stack up with the default project name (\"octo\")"
  warn "will SHARE volumes with the deployment above. A later"
  warn "\`docker compose down -v\` from EITHER clone will wipe ALL OCTO"
  warn "data on this host — exactly the failure mode that destroyed"
  warn "im-test on 2026-05-16."
  warn ""
  warn "To isolate this stack:"
  warn "    export COMPOSE_PROJECT_NAME=octo-\$(your-suffix)"
  warn "    ./setup.sh ...   # writes docker/.env"
  warn "    cd docker && docker compose up -d"
  warn ""
  warn "The named volumes in docker-compose.yaml interpolate"
  warn "COMPOSE_PROJECT_NAME so volumes / networks for the two stacks"
  warn "will stay fully separate."
  warn ""

  if [[ "${NON_INTERACTIVE}" == "false" ]]; then
    read -rp "Continue with project name \"${COMPOSE_PROJECT_NAME:-octo}\"? [y/N]: " confirm
    case "${confirm}" in
      [yY]|[yY][eE][sS]) info "Continuing — make sure you understand the implications above." ;;
      *) info "Aborted. Re-run with COMPOSE_PROJECT_NAME=octo-<suffix> exported."; exit 0 ;;
    esac
  else
    warn "(non-interactive mode: not prompting — proceeding with"
    warn " COMPOSE_PROJECT_NAME=\"${COMPOSE_PROJECT_NAME:-octo}\")"
  fi
}

preflight_existing_octo

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

# The .env file holds DB passwords, admin password, MinIO root credentials
# and notify/manager tokens. A naive `cp` honors the inherited umask
# (typically 022 → 0644 = world-readable), and `cp` followed by a
# separate `chmod 600` leaves a brief window during which any local user
# can read every secret in the stack. Prefer `install -m 600` because it
# creates the destination with the target mode in a single step. Fall
# back to a `umask`-scoped `cp` for environments without GNU/BSD
# coreutils (e.g. some Alpine/busybox base images) — that path is still
# atomic with respect to the permissions race because the umask is
# applied before the file is created.
if command -v install &>/dev/null; then
  install -m 600 "${ENV_EXAMPLE}" "${ENV_OUT}"
else
  ( umask 077 && cp "${ENV_EXAMPLE}" "${ENV_OUT}" )
fi

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
# COMPOSE_PROFILES is the single source of truth for whether the summary
# services run (see docker-compose.yaml — summary-api/summary-worker are
# gated by the `summary` profile). --summary just flips that switch.
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
  warn "HTTPS preparation flag set (OCTO_TLS_ENABLED=true)."
  warn "HTTPS is NOT yet active — --https only flips one env var. To actually"
  warn "serve HTTPS you still need the following manual steps:"
  echo "  1. Place certificates in docker/certs/:"
  echo "       - docker/certs/fullchain.pem"
  echo "       - docker/certs/privkey.pem"
  echo "  2. Uncomment the HTTPS server block in"
  echo "       docker/nginx/conf.d/octo.conf.template"
  echo "  3. Uncomment the 443 port mapping + certs volume in"
  echo "       docker/docker-compose.yaml"
  echo "  4. Restart: cd docker && docker compose up -d"
  echo ""
  warn "Full procedure: docker/certs/README.md"
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
