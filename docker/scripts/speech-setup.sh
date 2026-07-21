#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Set up the OCTO speech profile (octo-speech + octo-speech-admin) on an
# already-running stack. Idempotent: every step is safe to re-run.
# -----------------------------------------------------------------------------
# Flow:
#   (0) Validate required secrets; create octo_speech DB if absent
#   (1) Start speech services (docker compose --profile speech up -d)
#   (2) Wait for octo-speech-admin to be reachable via nginx
#   (3) Create an API key via octo-speech-admin
#   (4) Write SPEECH_API_KEY + SPEECH_SERVICE_URL + COMPOSE_PROFILES into .env
#   (5) Restart octo-server to pick up the key
#
# Usage:
#   docker/scripts/speech-setup.sh              # full setup
#   docker/scripts/speech-setup.sh --from 3     # resume at step N (0..5)
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
  grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" || true
}

# portable: rewrite via tmp file, no sed -i flavor issues (matches search-upgrade.sh)
persist_env() {
  local key="$1" val="$2"
  touch "$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$val" \
      'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' \
      "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

persist_profile() {
  local add="$1" current merged
  current="${COMPOSE_PROFILES:-$(env_get COMPOSE_PROFILES)}"
  merged="$(printf '%s' "$current" | tr ',' '\n' | sed '/^[[:space:]]*$/d' \
    | awk -v a="$add" '{print} $0==a{seen=1} END{if(!seen)print a}' \
    | paste -sd, -)"
  COMPOSE_PROFILES="$merged"
  persist_env COMPOSE_PROFILES "$merged"
}

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "FATAL: neither 'docker compose' nor 'docker-compose' is available" >&2
  exit 2
fi

# resolve vars from .env (env wins, like Compose)
: "${OCTO_HTTP_PORT:=$(env_get OCTO_HTTP_PORT)}"
: "${OCTO_SPEECH_ADMIN_PORT:=$(env_get OCTO_SPEECH_ADMIN_PORT)}"
: "${MYSQL_ROOT_PASSWORD:=$(env_get MYSQL_ROOT_PASSWORD)}"
: "${SPEECH_DB_PASSWORD:=$(env_get SPEECH_DB_PASSWORD)}"
: "${SPEECH_ADMIN_USERNAME:=$(env_get SPEECH_ADMIN_USERNAME)}"
: "${SPEECH_ADMIN_PASSWORD:=$(env_get SPEECH_ADMIN_PASSWORD)}"
: "${SPEECH_ADMIN_JWT_SECRET:=$(env_get SPEECH_ADMIN_JWT_SECRET)}"
: "${SPEECH_API_KEY:=$(env_get SPEECH_API_KEY)}"

HTTP_PORT="${OCTO_HTTP_PORT:-28080}"
ADMIN_PORT="${OCTO_SPEECH_ADMIN_PORT:-28088}"
ADMIN_USER="${SPEECH_ADMIN_USERNAME:-admin}"
# speech-admin is loopback-only (like MinIO console) — accessed directly by port,
# not exposed through nginx, to avoid a fail-open admin surface on the public listener.
BASE_URL="http://127.0.0.1:${ADMIN_PORT}"

# parse --from N
FROM_STEP=0
while (($#)); do
  case "$1" in
    --from) shift; FROM_STEP="${1:?'--from requires a step number'}"; shift ;;
    --from=*) FROM_STEP="${1#--from=}"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$FROM_STEP" in
  [0-5]) ;;
  *) echo "Invalid --from value '$FROM_STEP': must be an integer 0..5" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1m=== Step %s: %s ===\033[0m\n' "$1" "$2"; }
ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Secret validation — always run, regardless of --from N, so resuming a
# partial setup never brings up services with weak/placeholder credentials.
# ---------------------------------------------------------------------------
[ -n "${SPEECH_ADMIN_PASSWORD:-}" ] \
  || fail "SPEECH_ADMIN_PASSWORD is not set. Add it to docker/.env or export it before running this script."
case "$SPEECH_ADMIN_PASSWORD" in
  *[!A-Za-z0-9._-]*)
    fail "SPEECH_ADMIN_PASSWORD contains characters outside [A-Za-z0-9._-]. Use: openssl rand -hex 16" ;;
esac
case "$(printf %s "$SPEECH_ADMIN_PASSWORD" | tr 'A-Z' 'a-z')" in
  change_me_*|chg_me*)
    fail "SPEECH_ADMIN_PASSWORD is still a CHANGE_ME placeholder. Rotate it: openssl rand -hex 16" ;;
esac
case "$ADMIN_USER" in
  *[!A-Za-z0-9._-]*)
    fail "SPEECH_ADMIN_USERNAME contains characters outside [A-Za-z0-9._-]." ;;
esac
[ -n "${SPEECH_ADMIN_JWT_SECRET:-}" ] \
  || fail "SPEECH_ADMIN_JWT_SECRET is not set. Generate with: openssl rand -hex 32"
case "$SPEECH_ADMIN_JWT_SECRET" in
  *[!A-Za-z0-9._-]*)
    fail "SPEECH_ADMIN_JWT_SECRET contains characters outside [A-Za-z0-9._-]. Use: openssl rand -hex 32" ;;
esac
case "$(printf %s "$SPEECH_ADMIN_JWT_SECRET" | tr 'A-Z' 'a-z')" in
  change_me_*|chg_me*)
    fail "SPEECH_ADMIN_JWT_SECRET is still a CHANGE_ME placeholder. Rotate it: openssl rand -hex 32" ;;
esac
[ "${#SPEECH_ADMIN_JWT_SECRET}" -ge 32 ] \
  || fail "SPEECH_ADMIN_JWT_SECRET is too short (${#SPEECH_ADMIN_JWT_SECRET} chars, need ≥32). Use: openssl rand -hex 32"
[ -n "${MYSQL_ROOT_PASSWORD:-}" ] \
  || fail "MYSQL_ROOT_PASSWORD is not set."
[ -n "${SPEECH_DB_PASSWORD:-}" ] \
  || fail "SPEECH_DB_PASSWORD is not set. Generate with: openssl rand -hex 16"
case "$SPEECH_DB_PASSWORD" in
  *[!A-Za-z0-9._-]*)
    fail "SPEECH_DB_PASSWORD contains characters outside [A-Za-z0-9._-]. Use: openssl rand -hex 16" ;;
esac
case "$(printf %s "$SPEECH_DB_PASSWORD" | tr 'A-Z' 'a-z')" in
  change_me_*|chg_me*)
    fail "SPEECH_DB_PASSWORD is still a CHANGE_ME placeholder. Rotate it: openssl rand -hex 16" ;;
esac
ok "Secrets validated"

# ---------------------------------------------------------------------------
# Step 0: create octo_speech DB on existing stack
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 0 ]; then
  log 0 "Provision octo_speech database"

  # Create DB idempotently against the live MySQL — init-extra-dbs.sh only runs
  # on first volume init, so existing deployments need this explicit step.
  # Pass MYSQL_PWD via -e so the root credential stays out of ps/proc cmdline.
  "${DC[@]}" exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql \
    mysql -uroot \
    -e "CREATE DATABASE IF NOT EXISTS octo_speech CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" \
    || fail "Failed to create octo_speech database — check MYSQL_ROOT_PASSWORD and MySQL connectivity."
  ok "octo_speech database ready"

  # Create scoped speech DB user (least-privilege, matches matter/summary pattern).
  # SQL piped via stdin so the scoped password stays off the ps/proc cmdline.
  "${DC[@]}" exec -T -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql \
    mysql -uroot <<SQL || fail "Failed to provision speech DB user — check MYSQL_ROOT_PASSWORD and MySQL connectivity."
CREATE USER IF NOT EXISTS 'speech'@'%' IDENTIFIED BY '${SPEECH_DB_PASSWORD}';
ALTER USER IF EXISTS      'speech'@'%' IDENTIFIED BY '${SPEECH_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON octo_speech.* TO 'speech'@'%';
FLUSH PRIVILEGES;
SQL
  ok "speech DB user provisioned"
fi

# ---------------------------------------------------------------------------
# Step 1: start speech services
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 1 ]; then
  log 1 "Start speech services"
  "${DC[@]}" --profile speech up -d
  # Recreate nginx so its config reflects the updated template.
  # Compose does not recreate a running container just because a bind-mounted file changed.
  "${DC[@]}" up -d --force-recreate --no-deps nginx
  persist_profile "speech"
  ok "speech services started; nginx recreated; COMPOSE_PROFILES updated in .env"
fi

# ---------------------------------------------------------------------------
# Step 2: wait for octo-speech-admin reachable on loopback port
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 2 ]; then
  log 2 "Wait for octo-speech-admin to be reachable on loopback (port ${ADMIN_PORT})"
  RETRIES=30
  # Accept only HTTP codes that prove the login endpoint itself handled the
  # request (400 bad-request, 401 unauthorized, 422 validation error).
  # Intermediate failures (000 no-connection, 502/503) continue retrying.
  until HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST "${BASE_URL}/api/login" \
      -H "Content-Type: application/json" \
      -d '{}' 2>/dev/null)" \
    && case "$HTTP_CODE" in 400|401|422) true ;; *) false ;; esac; do
    RETRIES=$((RETRIES - 1))
    [ "$RETRIES" -le 0 ] && fail "octo-speech-admin did not become reachable in time (${BASE_URL}, last HTTP $HTTP_CODE)"
    info "waiting for admin console... ($RETRIES attempts left, HTTP $HTTP_CODE)"
    sleep 5
  done
  ok "octo-speech-admin is reachable (HTTP $HTTP_CODE)"
fi

# ---------------------------------------------------------------------------
# Step 3: create API key via speech-admin (idempotent: reuse existing app)
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 3 ]; then
  log 3 "Create (or reuse) API key via speech-admin"

  LOGIN_RESP=$(printf '{"username":"%s","password":"%s"}' "$ADMIN_USER" "$SPEECH_ADMIN_PASSWORD" \
    | curl -sf -X POST "${BASE_URL}/api/login" \
      -H "Content-Type: application/json" \
      -d @- 2>&1) \
    || fail "Login to speech-admin failed. Check SPEECH_ADMIN_USERNAME / SPEECH_ADMIN_PASSWORD."

  TOKEN=$(printf '%s' "$LOGIN_RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || true)
  [ -n "$TOKEN" ] || fail "Could not extract auth token from login response (unexpected response format)."

  # Try to reuse an existing 'octo-docker' app to stay idempotent
  LIST_RESP=$(curl -sf "${BASE_URL}/api/apps" \
    -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || true)
  EXISTING_KEY=$(printf '%s' "$LIST_RESP" | grep -o '"app_name":"octo-docker"[^}]*"api_key":"[^"]*"' \
    | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4 || true)

  if [ -n "$EXISTING_KEY" ]; then
    SPEECH_API_KEY="$EXISTING_KEY"
    # Persist immediately so --from 4 can recover if the script is interrupted
    persist_env "SPEECH_API_KEY" "$SPEECH_API_KEY"
    ok "Reusing existing 'octo-docker' app key: ${SPEECH_API_KEY:0:12}..."
  else
    # Check if an 'octo-docker' app exists but its key is no longer exposed
    HAS_APP=$(printf '%s' "$LIST_RESP" | grep -o '"app_name":"octo-docker"' || true)
    if [ -n "$HAS_APP" ]; then
      # App exists but key not recoverable — delete and recreate.
      # Treat a DELETE failure as fatal: if we can't remove the stale app,
      # the subsequent create will fail on a duplicate name.
      APP_ID=$(printf '%s' "$LIST_RESP" | grep -o '"app_name":"octo-docker"[^}]*"id":[0-9]*' \
        | grep -o '"id":[0-9]*' | cut -d: -f2 | head -n1 || true)
      [ -n "$APP_ID" ] \
        || fail "Found stale 'octo-docker' app but could not extract its ID to delete it."
      curl -sf -X DELETE "${BASE_URL}/api/apps/${APP_ID}" \
        -H "Authorization: Bearer ${TOKEN}" >/dev/null \
        || fail "Failed to delete stale 'octo-docker' app (id=${APP_ID}). Cannot recreate."
      info "Deleted stale 'octo-docker' app (key not recoverable), recreating..."
    fi
    APP_RESP=$(curl -sf -X POST "${BASE_URL}/api/apps" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${TOKEN}" \
      -d '{"app_name":"octo-docker"}' 2>&1) \
      || fail "Failed to create speech API key."
    SPEECH_API_KEY=$(printf '%s' "$APP_RESP" | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4 | head -n1 || true)
    [ -n "$SPEECH_API_KEY" ] || fail "Could not extract API key from app creation response (unexpected response format)."
    # Persist immediately so --from 4 can recover if the script is interrupted
    persist_env "SPEECH_API_KEY" "$SPEECH_API_KEY"
    ok "API key created and persisted: ${SPEECH_API_KEY:0:12}..."
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: write key + service URL into .env
# ---------------------------------------------------------------------------
if [ "$FROM_STEP" -le 4 ]; then
  log 4 "Write SPEECH_API_KEY and SPEECH_SERVICE_URL into docker/.env"

  # When resuming at step 4, load key from .env if not already set by step 3
  : "${SPEECH_API_KEY:=$(env_get SPEECH_API_KEY)}"
  [ -n "${SPEECH_API_KEY:-}" ] \
    || fail "SPEECH_API_KEY is not set and could not be read from .env. Re-run from step 3."

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
printf '  Admin console : %s/ (loopback — SSH-forward to access remotely)\n' "$BASE_URL"
printf '  SSH forward   : ssh -L %s:127.0.0.1:%s user@host\n' "$ADMIN_PORT" "$ADMIN_PORT"
