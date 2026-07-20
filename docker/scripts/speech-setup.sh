#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Set up the OCTO speech profile (octo-speech + octo-speech-admin) on an
# already-running stack. Idempotent: every step is safe to re-run.
# -----------------------------------------------------------------------------
# Flow:
#   (1) Start speech services (docker compose --profile speech up -d)
#   (2) Wait for octo-speech to be healthy
#   (3) Create an API key via octo-speech-admin
#   (4) Write SPEECH_API_KEY into docker/.env
#   (5) Restart octo-server to pick up the key
#
# Usage:
#   docker/scripts/speech-setup.sh                  # full setup
#   docker/scripts/speech-setup.sh --from 3         # resume at step N (1..5)
#   SPEECH_ADMIN_PASSWORD=mypass docker/scripts/speech-setup.sh
#
# Requires: curl, docker (compose v2 plugin or docker-compose binary).
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
cd "$DOCKER_DIR"

ENV_FILE="${ENV_FILE:-$DOCKER_DIR/.env}"
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "FATAL: neither 'docker compose' nor 'docker-compose' is available" >&2
  exit 2
fi

: "${OCTO_HTTP_PORT:=$(env_get OCTO_HTTP_PORT)}"
: "${SPEECH_ADMIN_USERNAME:=$(env_get SPEECH_ADMIN_USERNAME)}"
: "${SPEECH_ADMIN_PASSWORD:=$(env_get SPEECH_ADMIN_PASSWORD)}"

HTTP_PORT="${OCTO_HTTP_PORT:-80}"
ADMIN_USER="${SPEECH_ADMIN_USERNAME:-admin}"
BASE_URL="http://127.0.0.1:${HTTP_PORT}/speech-admin"

FROM_STEP=1
for arg in "$@"; do
  case "$arg" in
    --from) shift; FROM_STEP="${1:-1}"; shift ;;
    --from=*) FROM_STEP="${arg#--from=}" ;;
  esac
done

log()     { printf '\n\033[1m=== Step %s: %s ===\033[0m\n' "$1" "$2"; }
ok()      { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
info()    { printf '    %s\n' "$*"; }
fail()    { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

persist_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Step 1: start speech services
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 1 ]; then
  log 1 "Start speech services"
  "${DC[@]}" --profile speech up -d
  ok "speech services started"
fi

# ---------------------------------------------------------------------------
# Step 2: wait for octo-speech healthy
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 2 ]; then
  log 2 "Wait for octo-speech to be healthy"
  RETRIES=20
  until "${DC[@]}" exec -T octo-speech bash -c 'echo > /dev/tcp/localhost/8780' 2>/dev/null; do
    RETRIES=$((RETRIES - 1))
    [ "$RETRIES" -le 0 ] && fail "octo-speech did not become ready in time"
    info "waiting... ($RETRIES attempts left)"
    sleep 5
  done
  ok "octo-speech is ready"
fi

# ---------------------------------------------------------------------------
# Step 3: create API key via speech-admin
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 3 ]; then
  log 3 "Create API key via speech-admin"

  if [ -z "${SPEECH_ADMIN_PASSWORD:-}" ]; then
    fail "SPEECH_ADMIN_PASSWORD is not set. Add it to docker/.env or export it before running this script."
  fi

  # Login and grab token
  LOGIN_RESP=$(curl -sf -X POST "${BASE_URL}/api/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${SPEECH_ADMIN_PASSWORD}\"}" 2>&1) \
    || fail "Login to speech-admin failed. Is the speech profile running and nginx healthy?"

  TOKEN=$(printf '%s' "$LOGIN_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
  [ -n "$TOKEN" ] || fail "Could not extract auth token from login response: $LOGIN_RESP"

  # Create application
  APP_RESP=$(curl -sf -X POST "${BASE_URL}/api/apps" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"app_name":"octo-docker"}' 2>&1) \
    || fail "Failed to create speech API key: $APP_RESP"

  SPEECH_API_KEY=$(printf '%s' "$APP_RESP" | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)
  [ -n "$SPEECH_API_KEY" ] || fail "Could not extract API key from response: $APP_RESP"

  ok "API key created: ${SPEECH_API_KEY:0:12}..."
fi

# ---------------------------------------------------------------------------
# Step 4: write key into .env
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 4 ]; then
  log 4 "Write SPEECH_API_KEY into docker/.env"
  persist_env "SPEECH_SERVICE_URL" "http://octo-speech:8780"
  persist_env "SPEECH_API_KEY" "$SPEECH_API_KEY"
  ok "docker/.env updated"
fi

# ---------------------------------------------------------------------------
# Step 5: restart octo-server
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 5 ]; then
  log 5 "Restart octo-server to activate speech"
  "${DC[@]}" up -d --no-deps octo-server
  ok "octo-server restarted"
fi

printf '\n\033[32m[DONE]\033[0m Speech profile is live.\n'
printf '  Admin console : %s/\n' "$BASE_URL"
printf '  API key       : %s\n' "${SPEECH_API_KEY:-<set in .env>}"
