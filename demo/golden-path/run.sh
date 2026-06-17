#!/usr/bin/env bash
# =============================================================================
# OCTO golden-path demo — one command brings up the reference stack and (when a
# bot token is supplied) wires a streaming channel bot.
#
#   ./run.sh                       # bring up the reference stack only
#   OCTO_BOT_TOKEN=bf_xxx ./run.sh # stack + provision a demo group + launch bot
#
# Reference stack (subset of ../../docker/docker-compose.yaml — the canonical
# compose is the single source of truth; this script only selects services and
# generates a local .env):
#   mysql · redis · minio · minio-init · wukongim · octo-server · nginx · web
# (preflight runs automatically as a dependency; admin / matter / summary-* are
#  intentionally left out of the golden path.)
#
# See README.md for the full walkthrough, how to get a bot token from BotFather,
# and the QA end-to-end validation plan (OCT-12).
# =============================================================================
set -euo pipefail

# --- paths -------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/../../docker" && pwd)"
COMPOSE_FILE="$DOCKER_DIR/docker-compose.yaml"
ENV_FILE="$HERE/.env"                 # generated; gitignored
PROJECT="octo-golden"                 # isolated compose project name

# Reference-stack services (preflight is pulled in via depends_on).
REF_SERVICES=(mysql redis minio minio-init wukongim octo-server nginx web)

# --- host-reachable endpoints (loopback binds from the canonical compose) -----
HTTP_PORT="${OCTO_HTTP_PORT:-28080}"          # nginx ingress (API + web + ws)
SERVER_PORT="${OCTO_SERVER_PORT:-28081}"      # octo-server direct REST (smoke)
WEB_PORT="${OCTO_WEB_PORT:-28083}"            # octo-web direct (diagnostics)
API_BASE="http://localhost:${HTTP_PORT}"      # what clients + the bot dial

log()  { printf '\033[1;36m[golden-path]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[golden-path]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[golden-path] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# -----------------------------------------------------------------------------
# 0. preconditions
# -----------------------------------------------------------------------------
need docker
need openssl
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
[ -f "$COMPOSE_FILE" ] || die "canonical compose not found at $COMPOSE_FILE"

compose() {
  # `down`/`logs`/`ps` must work even before an .env is generated; the project
  # name alone is enough for compose to find the running services.
  if [ -f "$ENV_FILE" ]; then
    docker compose -p "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"
  fi
}

# --- lifecycle subcommands ----------------------------------------------------
case "${1:-up}" in
  down)  log "tearing down the golden-path stack (volumes preserved; add -v to wipe)"; compose down "${@:2}"; exit 0 ;;
  nuke)  warn "removing the golden-path stack AND its data volumes"; compose down -v; rm -f "$ENV_FILE"; exit 0 ;;
  logs)  compose logs "${@:2}"; exit 0 ;;
  ps)    compose ps; exit 0 ;;
  up|"") ;;  # fall through to bring-up
  *)     die "unknown subcommand: $1 (use: up | down | nuke | logs | ps)" ;;
esac

# -----------------------------------------------------------------------------
# 1. generate a local .env with fresh secrets (idempotent)
# -----------------------------------------------------------------------------
gen() { openssl rand -hex "$1"; }

if [ ! -f "$ENV_FILE" ]; then
  log "generating $ENV_FILE from .env.example with fresh secrets"
  cp "$DOCKER_DIR/.env.example" "$ENV_FILE"

  # Each secret below has no compose default (or is preflight-gated), so it must
  # be a real, non-placeholder value. OCTO_MASTER_KEY is a 32-byte key.
  set_kv() { # key value  — replace `key=...` in place (BSD/GNU sed compatible)
    local k="$1" v="$2"
    if grep -qE "^#?\s*${k}=" "$ENV_FILE"; then
      sed -i.bak -E "s|^#?[[:space:]]*${k}=.*|${k}=${v}|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    else
      printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
    fi
  }
  set_kv MYSQL_ROOT_PASSWORD        "$(gen 16)"
  set_kv MINIO_ROOT_PASSWORD        "$(gen 16)"
  set_kv OCTO_MINIO_APP_PASSWORD    "$(gen 16)"
  set_kv OCTO_MASTER_KEY            "$(gen 16)"   # 32 hex chars = 32 bytes
  set_kv OCTO_NOTIFY_INTERNAL_TOKEN "$(gen 32)"
  set_kv OCTO_WUKONGIM_MANAGER_TOKEN "$(gen 32)"
  # Bootstrap a first superAdmin so the demo is reachable in octo-web.
  set_kv OCTO_ADMIN_PWD             "$(gen 12)"
  chmod 600 "$ENV_FILE"
  log "secrets written (kept out of git — see .gitignore). superAdmin password:"
  grep -E '^OCTO_ADMIN_PWD=' "$ENV_FILE" | sed 's/^/    /'
else
  log "reusing existing $ENV_FILE (delete it to regenerate secrets)"
fi

# -----------------------------------------------------------------------------
# 2. bring up the reference stack
# -----------------------------------------------------------------------------
log "pulling + starting reference stack (project: $PROJECT)…"
compose up -d "${REF_SERVICES[@]}"

# -----------------------------------------------------------------------------
# 3. wait for octo-server health (the gate the whole demo depends on)
# -----------------------------------------------------------------------------
log "waiting for octo-server to become healthy at $API_BASE …"
deadline=$(( $(date +%s) + 240 ))
until curl -fsS "http://localhost:${SERVER_PORT}/v1/ping" >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$deadline" ] || { compose ps; die "octo-server did not become healthy in time"; }
  sleep 3
done
log "octo-server is up. ingress: $API_BASE  ·  web: http://localhost:${WEB_PORT}  ·  direct REST: http://localhost:${SERVER_PORT}"

# -----------------------------------------------------------------------------
# 4. wire the channel bot (only if a token was provided)
# -----------------------------------------------------------------------------
if [ -z "${OCTO_BOT_TOKEN:-}" ]; then
  cat <<EOF

$(printf '\033[1;32m✓ Reference stack is up.\033[0m')

Next: create a bot and re-run this script with its token.

  1. Open octo-web:   http://localhost:${WEB_PORT}   (login: superAdmin / see OCTO_ADMIN_PWD above)
  2. DM @BotFather:    send  /newbot  then a name; copy the bf_… token it returns.
     (BotFather's onboarding doc is also served at: ${API_BASE}/v1/bot/setup-quickstart.md)
  3. Re-run wired:     OCTO_BOT_TOKEN=bf_xxxxx ./run.sh

To tear everything down:  ./run.sh down
EOF
  exit 0
fi

log "wiring channel bot with supplied token…"
"$HERE/wire-bot.sh" "$API_BASE" "$OCTO_BOT_TOKEN"
