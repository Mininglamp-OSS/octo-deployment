#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# OCTO Deployment · Interactive Setup Script
# -----------------------------------------------------------------------------
# Generates docker/.env from docker/.env.example with rotated secrets,
# user-chosen domain/IP, and optional TLS / LLM summary toggles. Also
# offers post-deploy smoke test (`--verify`) and clean uninstall
# (`--uninstall`) subcommands.
#
# Usage:
#   ./setup.sh                        # interactive mode
#   ./setup.sh --non-interactive      # all defaults + auto-detect
#   ./setup.sh --domain octo.example.com --ip 1.2.3.4 --https --summary
#   ./setup.sh --verify               # smoke-test an already-up stack
#   ./setup.sh --uninstall            # tear down the stack (interactive)
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
RUN_UP=false
RUN_VERIFY=false
RUN_UNINSTALL=false

# Track which configuration values were supplied explicitly via CLI flags
# so the interactive prompts (when invoked without --non-interactive)
# don't silently overwrite them.
DOMAIN_SET_VIA_CLI=false
IP_SET_VIA_CLI=false
HTTPS_SET_VIA_CLI=false
SUMMARY_SET_VIA_CLI=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_EXAMPLE="${SCRIPT_DIR}/docker/.env.example"
ENV_OUT="${SCRIPT_DIR}/docker/.env"
DOCKER_DIR="${SCRIPT_DIR}/docker"

# ── Colours / helpers ────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; CYAN=''; RESET=''
fi

info()  { printf '%s[setup]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn()  { printf '%s[setup]%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
err()   { printf '%s[setup]%s %s\n' "${RED}" "${RESET}" "$*" >&2; }
fatal() { err "$@"; exit 1; }
step()  { printf '%s[verify]%s %s ... ' "${CYAN}" "${RESET}" "$*"; }
ok()    { printf '%sPASS%s\n' "${GREEN}" "${RESET}"; }
fail()  { printf '%sFAIL%s — %s\n' "${RED}" "${RESET}" "${1:-}"; }

# Portable in-place sed (GNU + BSD/macOS compatible).
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# Pick `docker compose` v2 or fall back to standalone `docker-compose`.
# Echoes the command tokens; callers wrap in `$(...)` and pass as a list.
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    fatal "docker compose is not available."
  fi
}

# Returns 0 if `docker compose up -d --wait` is supported (Compose v2.20+).
# Older Compose (v1, and v2 < 2.20) silently ignores `--wait` and returns 0
# even when services are still booting, so callers fall back to a manual
# health poll.
compose_supports_wait() {
  local cc="$1"
  local v="" major="" rest="" minor=""
  v="$(${cc} version --short 2>/dev/null || true)"
  v="${v#v}"
  [[ -z "${v}" ]] && return 1
  major="${v%%.*}"
  rest="${v#*.}"
  minor="${rest%%.*}"
  [[ ! "${major}" =~ ^[0-9]+$ ]] && return 1
  [[ ! "${minor}" =~ ^[0-9]+$ ]] && return 1
  if (( major > 2 )); then return 0; fi
  if (( major == 2 && minor >= 20 )); then return 0; fi
  return 1
}

# Poll `docker compose ps` until no container is `(unhealthy)` or
# `(health: starting)`. Used on Compose < 2.20 where `up --wait` is a no-op.
compose_poll_healthy() {
  local cc="$1" timeout="${2:-180}" elapsed=0 statuses=""
  while (( elapsed < timeout )); do
    statuses="$(cd "${DOCKER_DIR}" && ${cc} ps --format '{{.Status}}' 2>/dev/null || true)"
    if [[ -n "${statuses}" ]]; then
      if echo "${statuses}" | grep -q '(unhealthy)'; then
        return 1
      fi
      if ! echo "${statuses}" | grep -q '(health: starting)'; then
        return 0
      fi
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
  return 1
}

# Run `up -d`, preferring `--wait` on Compose ≥ 2.20 and falling back to a
# manual health poll on older Compose so users on legacy installs do not
# see a hard failure. Returns the exit code of the compose call (or the
# poll) so callers can fail-fast.
compose_up_and_wait() {
  local cc="$1"
  if compose_supports_wait "${cc}"; then
    ( cd "${DOCKER_DIR}" && ${cc} up -d --wait )
    return $?
  fi
  warn "Detected Compose < v2.20 — \`up --wait\` is unavailable, falling back to manual health poll."
  if ! ( cd "${DOCKER_DIR}" && ${cc} up -d ); then
    return 1
  fi
  compose_poll_healthy "${cc}" 180
}

# Read a value from docker/.env (defaults if missing). Used by --verify
# / --uninstall / post-deploy admin-credentials echo.
env_get() {
  local key="$1" default="${2:-}"
  if [[ ! -f "${ENV_OUT}" ]]; then
    echo "${default}"; return 0
  fi
  local v
  v="$(grep -E "^${key}=" "${ENV_OUT}" | head -1 | cut -d= -f2-)" || true
  echo "${v:-${default}}"
}

# Resolve the project name the way Compose does — but for the script's own
# bookkeeping (uninstall volume scan, `--up` invocation, post-run admin URL).
# Precedence:
#   1. COMPOSE_PROJECT_NAME exported in the calling shell (matches Compose)
#   2. COMPOSE_PROJECT_NAME persisted in docker/.env (written by `setup.sh`
#      so the value survives the shell that invoked setup)
#   3. literal "octo" (compose YAML `name:` default)
project_name() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    echo "${COMPOSE_PROJECT_NAME}"
    return 0
  fi
  local from_env
  from_env="$(env_get COMPOSE_PROJECT_NAME "")"
  if [[ -n "${from_env}" ]]; then
    echo "${from_env}"
    return 0
  fi
  echo "octo"
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
    --up)        RUN_UP=true; shift ;;
    --verify)    RUN_VERIFY=true; shift ;;
    --uninstall) RUN_UNINSTALL=true; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: setup.sh [--non-interactive] [--force] [--domain <d>] [--ip <ip>]
                [--https] [--summary] [--up]
       setup.sh --verify
       setup.sh --uninstall

Generation:
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
  --up                After writing .env, run `docker compose up -d --wait`
                      and print healthy/unhealthy status for every service.

Smoke test / tear-down (work against an already-existing docker/.env):
  --verify            Probe nginx / octo-server / matter / object-store
                      paths end-to-end. Exits non-zero on any failure.
  --uninstall         Tear down the stack. Interactively offers three
                      granularity levels (full / data-only / containers-only).

When any of --domain / --ip / --https / --summary / --up is given without
--non-interactive, setup.sh treats the flags as your decisions and runs
non-interactively so the documented one-liner forms (see docker/README.md)
work as written.
USAGE
      exit 0
      ;;
    *) fatal "Unknown argument: $1" ;;
  esac
done

# Subcommand short-circuits — run and exit before the generation path.
if [[ "${RUN_VERIFY}" == "true" ]]; then
  if [[ ! -f "${ENV_OUT}" ]]; then
    fatal "docker/.env not found. Run setup.sh first to generate it."
  fi
  CC="$(compose_cmd)"
  DOMAIN="$(env_get OCTO_DOMAIN octo.local)"
  HTTP_PORT="$(env_get OCTO_HTTP_PORT 28080)"
  BASE_URL="http://${DOMAIN}:${HTTP_PORT}"
  fails=0

  step "container health (${CC} ps)"
  if ! ( cd "${DOCKER_DIR}" && ${CC} ps --status running >/dev/null 2>&1 ); then
    fail "docker compose ps failed — is the stack up?"; ((fails++)) || true
  else
    unhealthy=$(cd "${DOCKER_DIR}" && ${CC} ps --format '{{.Name}}\t{{.Status}}' 2>/dev/null \
                | grep -E '\(unhealthy\)' || true)
    if [[ -n "${unhealthy}" ]]; then
      fail "unhealthy service(s):"; printf '%s\n' "${unhealthy}" | sed 's/^/    /'; ((fails++)) || true
    else
      ok
    fi
  fi

  step "nginx vhost up (GET ${BASE_URL}/_nginx_up)"
  if curl -fsS --max-time 5 "${BASE_URL}/_nginx_up" >/dev/null 2>&1; then
    ok
  else
    fail "no 200 from nginx"; ((fails++)) || true
  fi

  step "octo-server REST (GET ${BASE_URL}/api/v1/health)"
  if curl -fsS --max-time 5 "${BASE_URL}/api/v1/health" >/dev/null 2>&1; then
    ok
  else
    fail "no 200 from octo-server /api/v1/health"; ((fails++)) || true
  fi

  step "octo-matter (GET ${BASE_URL}/matter/health)"
  if curl -fsS --max-time 5 "${BASE_URL}/matter/health" >/dev/null 2>&1; then
    ok
  else
    # matter is part of the default stack (not profile-gated), so a failed
    # probe IS a deployment failure. Counted toward `fails` so `--verify`
    # surfaces it as a non-zero exit and CI / automation cannot mistake a
    # broken matter for a healthy one.
    fail "no 200 from matter — check 'docker compose logs matter'"
    ((fails++)) || true
  fi

  step "MinIO via nginx (GET ${BASE_URL}/minio/health/live)"
  # `/minio/` location is a passthrough — `proxy_pass http://octo_minio_api;`
  # has no trailing slash and no rewrite, so the request URI is forwarded
  # verbatim. MinIO's built-in liveness endpoint lives at `/minio/health/live`
  # (its first `/minio` is part of MinIO's path, NOT the nginx location).
  # A double `/minio/minio/...` would be parsed by MinIO as bucket=minio +
  # key=minio/health/live and return 404 every time.
  if curl -fsS --max-time 5 "${BASE_URL}/minio/health/live" >/dev/null 2>&1; then
    ok
  else
    fail "MinIO health probe through nginx failed — check nginx + minio logs"
    ((fails++)) || true
  fi

  step "admin SPA reachable (GET ${BASE_URL}/admin/)"
  if curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' "${BASE_URL}/admin/" 2>/dev/null | grep -qE '^(200|301|302)$'; then
    ok
  else
    fail "admin SPA not reachable"; ((fails++)) || true
  fi

  # -------------------------------------------------------------------------
  # End-to-end auth + presigned PUT (the real OOTB contract test).
  #
  # The plain HTTP reachability probes above only prove that nginx routes
  # are wired and the backing containers respond to unauthenticated GETs.
  # The single-port reverse proxy ALSO has to carry:
  #   1. POST /api/v1/manager/login (auth → token) — exercises
  #      octo-server + MySQL + bcrypt + cache (Redis), the chain that breaks
  #      first when a `.env` regeneration de-syncs OCTO_ADMIN_PWD.
  #   2. GET  /api/v1/file/upload/credentials (presign issuance) — exercises
  #      the MinIO IAM credential path (OCTO_MINIO_APP_*), the bucket-name
  #      regex location, and the host:port the URL is signed against.
  #   3. HTTP PUT to the signed URL with a 1-byte payload — exercises
  #      nginx forwarding the SigV4 path verbatim AND MinIO accepting the
  #      signature. This is the exact code path that silently dropped
  #      image messages on the dual-port form when port 29000 was closed
  #      (OOTB-BUG-2026-05-17-001).
  # All three must pass for `--verify` to exit 0.
  # -------------------------------------------------------------------------
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not available — skipping admin login + presign PUT end-to-end checks."
    warn "(install python3 for full --verify coverage)"
  else
    ADMIN_USER="$(env_get OCTO_ADMIN_NAME superAdmin)"
    ADMIN_PWD="$(env_get OCTO_ADMIN_PWD '')"
    TOKEN=""
    if [[ -z "${ADMIN_PWD}" ]]; then
      step "admin login (POST /api/v1/manager/login)"
      fail "OCTO_ADMIN_PWD is empty in docker/.env — cannot exercise admin auth"
      ((fails++)) || true
    else
      step "admin login (POST /api/v1/manager/login as ${ADMIN_USER})"
      LOGIN_BODY="$(printf '{"username":"%s","password":"%s"}' "${ADMIN_USER}" "${ADMIN_PWD}")"
      LOGIN_RESP="$(curl -sS --max-time 10 -X POST \
                    "${BASE_URL}/api/v1/manager/login" \
                    -H 'Content-Type: application/json' \
                    --data-raw "${LOGIN_BODY}" 2>/dev/null || true)"
      TOKEN="$(printf '%s' "${LOGIN_RESP}" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    print(d.get("token") or "")
' 2>/dev/null || true)"
      if [[ -z "${TOKEN}" ]]; then
        fail "no token in login response (body head: ${LOGIN_RESP:0:200})"
        ((fails++)) || true
      else
        ok
      fi
    fi

    if [[ -n "${TOKEN}" ]]; then
      step "issue presigned PUT (GET /api/v1/file/upload/credentials)"
      TEST_FILE="octo-verify-$(date +%s)-$$.txt"
      CRED_URL="${BASE_URL}/api/v1/file/upload/credentials?type=file&filename=${TEST_FILE}&fileSize=1"
      CRED_RESP="$(curl -sS --max-time 10 -H "token: ${TOKEN}" "${CRED_URL}" 2>/dev/null || true)"
      # Parse uploadUrl / contentType / contentDisposition out of the JSON.
      # Use a single python3 invocation so we can shell-eval the three
      # assignments without re-parsing.
      CRED_ENV="$(printf '%s' "${CRED_RESP}" | python3 -c '
import json, shlex, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
print("UPLOAD_URL=" + shlex.quote(d.get("uploadUrl") or ""))
print("UPLOAD_CT="  + shlex.quote(d.get("contentType") or ""))
print("UPLOAD_CD="  + shlex.quote(d.get("contentDisposition") or ""))
' 2>/dev/null || true)"
      UPLOAD_URL=""; UPLOAD_CT=""; UPLOAD_CD=""
      # shellcheck disable=SC2086
      eval "${CRED_ENV}"
      if [[ -z "${UPLOAD_URL}" ]]; then
        fail "no uploadUrl in credentials response (body head: ${CRED_RESP:0:200})"
        ((fails++)) || true
      else
        ok
        step "PUT 1-byte test object via presigned URL"
        # Build the curl invocation. The signed URL pins Content-Length;
        # if contentType / contentDisposition were signed, MinIO rejects
        # the PUT unless we forward the same header values.
        PUT_HEADERS=()
        [[ -n "${UPLOAD_CT}" ]] && PUT_HEADERS+=( -H "Content-Type: ${UPLOAD_CT}" )
        [[ -n "${UPLOAD_CD}" ]] && PUT_HEADERS+=( -H "Content-Disposition: ${UPLOAD_CD}" )
        PUT_CODE="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
                    -X PUT "${PUT_HEADERS[@]}" --data-binary 'x' \
                    "${UPLOAD_URL}" 2>/dev/null || echo 000)"
        case "${PUT_CODE}" in
          200|204) ok ;;
          *)
            fail "PUT failed with HTTP ${PUT_CODE} — single-port MinIO routing or signed-header mismatch"
            ((fails++)) || true
            ;;
        esac
        # NOTE: the test object (1 byte) is intentionally left on disk —
        # cleanup would require either an octo-server delete endpoint or
        # an `mc rm` exec, and the leftover is negligible. Operators can
        # `docker exec <project>-minio-1 mc rm local/file/${TEST_FILE}` if
        # they want a perfectly clean state after smoke-testing.
      fi
    fi
  fi

  echo ""
  if [[ "${fails}" -eq 0 ]]; then
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    printf '%s  setup.sh --verify: end-to-end smoke test PASSED ✅%s\n' "${GREEN}" "${RESET}"
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    exit 0
  else
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    printf '%s  setup.sh --verify: %d step(s) failed ❌%s\n' "${RED}" "${fails}" "${RESET}"
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    err "Tail logs with: cd docker && ${CC} logs --tail 100"
    exit 1
  fi
fi

if [[ "${RUN_UNINSTALL}" == "true" ]]; then
  CC="$(compose_cmd)"
  # Prefer the project name persisted in docker/.env over the calling
  # shell's COMPOSE_PROJECT_NAME — the setup-time choice is the source
  # of truth, so an operator who later runs `./setup.sh --uninstall` in
  # a fresh shell still scopes teardown to the right stack instead of
  # accidentally falling back to the literal "octo" default.
  project="$(project_name)"
  # Volume name format is `<project>_<vol>` (underscore separator — see
  # docker-compose.yaml `volumes:` block). Match strictly on `^<project>_`
  # so a stack named `octo` does NOT chew through volumes belonging to
  # `octo-fz` / `octo-prod` / `octo-staging` on the same host.
  vol_regex="^${project}_"
  echo ""
  printf '%sOCTO Uninstall%s\n' "${BOLD}" "${RESET}"
  echo "Project: ${project}"
  echo ""
  echo "Pick teardown granularity:"
  echo "  1) Full uninstall — stop containers AND remove named volumes (DATA LOSS)"
  echo "  2) Data-only reset — remove named volumes only (containers will be recreated next up)"
  echo "  3) Containers only — stop + remove containers, keep volumes (safe restart prep)"
  echo "  q) Quit"
  echo ""
  warn "Before option 1 or 2, confirm the volumes about to be removed are YOURS:"
  echo "    docker volume ls | grep -E '${vol_regex}'"
  read -rp "Choice [1/2/3/q]: " choice
  # Ensure compose picks up the same project name (in case the env file
  # is missing the var or the calling shell has a stale value).
  export COMPOSE_PROJECT_NAME="${project}"
  case "${choice}" in
    1)
      warn "About to: cd docker && ${CC} down -v   (removes ALL named volumes for project '${project}')"
      read -rp "Type 'YES' to confirm: " confirm
      [[ "${confirm}" == "YES" ]] || { info "Aborted."; exit 0; }
      ( cd "${DOCKER_DIR}" && ${CC} down -v --remove-orphans )
      info "Full uninstall done. docker/.env preserved on disk; remove manually if desired."
      ;;
    2)
      ( cd "${DOCKER_DIR}" && ${CC} down )
      while IFS= read -r v; do
        [[ -z "${v}" ]] && continue
        info "removing volume ${v}"
        docker volume rm "${v}" >/dev/null 2>&1 || warn "could not remove ${v}"
      done < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "${vol_regex}" || true)
      info "Data reset complete. Run \`docker compose up -d\` to start fresh."
      ;;
    3)
      ( cd "${DOCKER_DIR}" && ${CC} down --remove-orphans )
      info "Containers stopped. Volumes preserved."
      ;;
    q|Q) info "Aborted."; exit 0 ;;
    *)   fatal "Unknown choice: ${choice}" ;;
  esac
  exit 0
fi

# If the operator supplied any "decision" flag (--domain / --ip / --https
# / --summary / --up) but did not pass --non-interactive, treat those
# flags as the decision and skip the prompts.
if [[ "${NON_INTERACTIVE}" == "false" ]]; then
  if [[ "${DOMAIN_SET_VIA_CLI}" == "true" \
     || "${IP_SET_VIA_CLI}" == "true" \
     || "${HTTPS_SET_VIA_CLI}" == "true" \
     || "${SUMMARY_SET_VIA_CLI}" == "true" \
     || "${RUN_UP}" == "true" ]]; then
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

if ! command -v curl &>/dev/null; then
  warn "curl is not installed; external IP auto-detection will fall back to 127.0.0.1."
  warn "Pass --ip <address> explicitly, or install curl, for a public IP."
fi

if [[ ! -f "${ENV_EXAMPLE}" ]]; then
  fatal "Cannot find ${ENV_EXAMPLE}. Run this script from the repository root."
fi

# ── Pre-flight: COMPOSE_PROJECT_NAME against existing OCTO state ────────────
# INCIDENT-2026-05-16-001 root cause + safeguard. If existing OCTO state
# is on the host AND COMPOSE_PROJECT_NAME is left at the default `octo`,
# force the operator to either confirm explicitly or pick a unique
# project name. Non-interactive mode now requires the env var to be set
# explicitly when collision risk is detected.
preflight_existing_octo() {
  command -v docker &>/dev/null || return 0
  docker info >/dev/null 2>&1 || return 0

  local existing_volumes existing_containers
  existing_volumes="$(docker volume ls --format '{{.Name}}' 2>/dev/null \
                       | grep -E '^octo([-_]|$)' || true)"
  existing_containers="$(docker ps -a --filter 'name=octo' --format '{{.Names}}' 2>/dev/null \
                       | grep -E '^octo([-_]|$)' || true)"

  if [[ -z "${existing_volumes}" && -z "${existing_containers}" ]]; then
    return 0
  fi

  local project="${COMPOSE_PROJECT_NAME:-octo}"
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

  if [[ "${NON_INTERACTIVE}" == "false" ]]; then
    if [[ "${project}" == "octo" ]]; then
      # Forced prompt — operator MUST either pick a unique project name
      # or confirm the default "octo" with eyes-open.
      read -rp "Set a custom COMPOSE_PROJECT_NAME now? (recommended) [y/N]: " want_project
      case "${want_project}" in
        [yY]|[yY][eE][sS])
          read -rp "  New COMPOSE_PROJECT_NAME (e.g. octo-fz): " new_project
          if [[ -z "${new_project}" || "${new_project}" == "octo" ]]; then
            warn "Project name unchanged. Re-run with an exported COMPOSE_PROJECT_NAME if you change your mind."
          else
            export COMPOSE_PROJECT_NAME="${new_project}"
            info "COMPOSE_PROJECT_NAME exported as '${new_project}' for this run."
          fi
          ;;
        *)
          read -rp "Confirm: continue with project name \"octo\" (RISK of volume collision)? Type 'YES' to proceed: " confirm
          [[ "${confirm}" == "YES" ]] || { info "Aborted. Re-run with COMPOSE_PROJECT_NAME=octo-<suffix> exported."; exit 0; }
          info "Continuing — make sure you understand the implications above."
          ;;
      esac
    else
      info "COMPOSE_PROJECT_NAME='${project}' set; volumes will be ${project}_* (isolated from existing octo_* state)."
    fi
  else
    if [[ "${project}" == "octo" ]]; then
      fatal "Existing OCTO state detected and COMPOSE_PROJECT_NAME is unset (defaults to 'octo'). \
Refusing to silently share volumes in non-interactive mode. \
Export COMPOSE_PROJECT_NAME=octo-<suffix> before re-running, or run interactively."
    fi
    warn "(non-interactive mode: proceeding with COMPOSE_PROJECT_NAME=\"${project}\")"
  fi
}

preflight_existing_octo

# ── Guard against overwriting an existing .env ─────────────────────────────
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
  detected_ip="$(detect_ip)"
  if [[ "${DOMAIN}" == "octo.local" || -z "${DOMAIN}" ]] \
     && [[ "${detected_ip}" != "127.0.0.1" ]]; then
    info "Detected public IP: ${detected_ip}"
    info "For a deployment reachable from outside this host, set OCTO_DOMAIN to a name"
    info "your clients can resolve (or use the detected IP directly)."
    read -rp "Domain name [${detected_ip}] (Enter to use detected IP, type 'octo.local' for local-only): " user_domain
    DOMAIN="${user_domain:-${detected_ip}}"
  else
    read -rp "Domain name [${DOMAIN}]: " user_domain
    DOMAIN="${user_domain:-${DOMAIN}}"
  fi

  # External IP
  read -rp "External IP [${detected_ip}]: " user_ip
  EXTERNAL_IP="${user_ip:-${detected_ip}}"

  # HTTPS
  read -rp "Enable HTTPS preparation flag? [y/N]: " user_https
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
sed_inplace "s|^# *OCTO_ADMIN_PWD=.*|OCTO_ADMIN_PWD=${OCTO_ADMIN_PWD}|" "${ENV_OUT}"

# TLS setting
if [[ "${ENABLE_HTTPS}" == "true" ]]; then
  sed_inplace "s|^OCTO_TLS_ENABLED=.*|OCTO_TLS_ENABLED=true|" "${ENV_OUT}"
else
  sed_inplace "s|^OCTO_TLS_ENABLED=.*|OCTO_TLS_ENABLED=false|" "${ENV_OUT}"
fi

# Summary setting
if [[ "${ENABLE_SUMMARY}" == "true" ]]; then
  if grep -q '^COMPOSE_PROFILES=' "${ENV_OUT}"; then
    sed_inplace "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=summary|" "${ENV_OUT}"
  elif grep -q '^# *COMPOSE_PROFILES=' "${ENV_OUT}"; then
    sed_inplace "s|^# *COMPOSE_PROFILES=.*|COMPOSE_PROFILES=summary|" "${ENV_OUT}"
  else
    printf '\n# Activate summary services (summary-api + summary-worker)\nCOMPOSE_PROFILES=summary\n' >> "${ENV_OUT}"
  fi
fi

# ── Persist COMPOSE_PROJECT_NAME into .env ─────────────────────────────────
# INCIDENT-2026-05-16-001 follow-up: the interactive preflight may
# `export COMPOSE_PROJECT_NAME=octo-<suffix>` so the rest of THIS shell
# scopes correctly, but that export vanishes the moment the operator
# exits setup.sh. A later `cd docker && docker compose up -d --wait`
# in a fresh shell would then silently fall back to the YAML `name: octo`
# default, mount the `octo_*` volume set, and (because the project name
# now mismatches) a subsequent `setup.sh --uninstall` grep would happily
# scoop up volumes from OTHER `octo-*` stacks on the same host.
#
# Writing the value into `docker/.env` is the documented, Compose-native
# way to make project-name selection durable: Compose auto-loads `.env`
# from its project directory before reading either `name:` or the
# COMPOSE_PROJECT_NAME shell env var, so the `up -d` from a vanilla
# shell ends up scoped to the same project this setup chose.
PROJECT_NAME_VALUE="${COMPOSE_PROJECT_NAME:-octo}"
if grep -q '^COMPOSE_PROJECT_NAME=' "${ENV_OUT}"; then
  sed_inplace "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=${PROJECT_NAME_VALUE}|" "${ENV_OUT}"
elif grep -q '^# *COMPOSE_PROJECT_NAME=' "${ENV_OUT}"; then
  sed_inplace "s|^# *COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=${PROJECT_NAME_VALUE}|" "${ENV_OUT}"
else
  # Insert as the very first line so it is impossible to miss when an
  # operator opens .env by hand.
  TMP_ENV="${ENV_OUT}.tmp.$$"
  {
    printf '# Compose project name — pins this stack to a dedicated set of\n'
    printf '# Docker volumes, networks, and container names (see docker-compose.yaml\n'
    printf '# `volumes:` block). Persisted here by setup.sh so it survives the\n'
    printf '# shell that ran setup; Compose auto-loads docker/.env before falling\n'
    printf '# back to the YAML `name:` default. Change ONLY if you understand\n'
    printf '# how it interacts with on-disk volumes.\n'
    printf 'COMPOSE_PROJECT_NAME=%s\n' "${PROJECT_NAME_VALUE}"
    cat "${ENV_OUT}"
  } > "${TMP_ENV}"
  chmod --reference="${ENV_OUT}" "${TMP_ENV}" 2>/dev/null || chmod 600 "${TMP_ENV}"
  mv "${TMP_ENV}" "${ENV_OUT}"
fi

# ── Optional: bring the stack up + wait for healthy ────────────────────────
HTTP_PORT="$(env_get OCTO_HTTP_PORT 28080)"
ADMIN_URL="http://${DOMAIN}:${HTTP_PORT}/admin/"

if [[ "${RUN_UP}" == "true" ]]; then
  CC="$(compose_cmd)"
  # Export the persisted project name so the child `docker compose`
  # process sees it even if the calling shell never did.
  export COMPOSE_PROJECT_NAME="${PROJECT_NAME_VALUE}"
  echo ""
  info "Starting stack (project: ${PROJECT_NAME_VALUE}) — first boot can take 60-120s…"
  if compose_up_and_wait "${CC}"; then
    info "All services reached healthy."
  else
    # FAIL-FAST: a compose-up failure means the stack is NOT running.
    # Previously this was just a warning and the success banner below
    # printed anyway, which (a) misled the operator and (b) let CI /
    # automation see exit 0 when nothing was actually up.
    err "${CC} up failed — stack is NOT running."
    err "Run:"
    err "    cd docker && ${CC} ps"
    err "    cd docker && ${CC} logs --tail 100"
    err "Fix the root cause and rerun ./setup.sh --up (or ./setup.sh --verify"
    err "once the stack is healthy)."
    err "docker/.env has been written — re-running setup.sh is NOT required."
    exit 1
  fi
fi

# ── Print summary ───────────────────────────────────────────────────────────
echo ""
printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
if [[ "${RUN_UP}" == "true" ]]; then
  printf '%s  docker/.env generated AND stack started successfully!%s\n' "${GREEN}" "${RESET}"
else
  printf '%s  docker/.env generated successfully — stack NOT started yet.%s\n' "${GREEN}" "${RESET}"
fi
printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
echo ""
printf '  Project:        %s%s%s\n' "${BOLD}" "${PROJECT_NAME_VALUE}" "${RESET}"
printf '  Domain:         %s%s%s\n' "${BOLD}" "${DOMAIN}" "${RESET}"
printf '  External IP:    %s%s%s\n' "${BOLD}" "${EXTERNAL_IP}" "${RESET}"
printf '  HTTP port:      %s%s%s\n' "${BOLD}" "${HTTP_PORT}" "${RESET}"
printf '  Admin URL:      %s%s%s\n' "${BOLD}" "${ADMIN_URL}" "${RESET}"
printf '  Admin user:     %ssuperAdmin%s\n' "${BOLD}" "${RESET}"
printf '  Admin password: %s%s%s\n' "${BOLD}" "${OCTO_ADMIN_PWD}" "${RESET}"
echo ""

# Firewall guidance — single-port deployment only needs OCTO_HTTP_PORT.
if [[ "${EXTERNAL_IP}" != "127.0.0.1" ]] || [[ "${DOMAIN}" != "octo.local" ]]; then
  printf '%s  Firewall:%s\n' "${BOLD}" "${RESET}"
  printf '    The OOTB stack is single-port — only open TCP %s%s%s to clients.\n' "${BOLD}" "${HTTP_PORT}" "${RESET}"
  printf '    All other services (MinIO API/console, MySQL, Redis, WuKongIM monitor,\n'
  printf '    octo-server / matter / summary direct ports) default to loopback.\n'
  printf '    Example (ufw):  sudo ufw allow %s/tcp\n' "${HTTP_PORT}"
  echo ""
fi

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
fi

if [[ "${RUN_UP}" != "true" ]]; then
  echo ""
  info "Next steps:"
  echo "  1. Review docker/.env and adjust as needed"
  echo "  2. (cd docker && docker compose up -d --wait)   # subshell — keeps you in repo root"
  echo "  3. ./setup.sh --verify    # admin login + presign PUT end-to-end check"
  echo "  4. Visit ${ADMIN_URL}"
else
  echo ""
  info "Smoke test:"
  echo "  ./setup.sh --verify    # admin login + presign PUT end-to-end check"
fi
echo ""
printf '%s  ⚠  Save the admin password above — it is NOT stored elsewhere.%s\n' "${YELLOW}" "${RESET}"
echo ""
