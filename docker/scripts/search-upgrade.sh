#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Hot-upgrade an already-running OCTO stack from "search off" to "search on"
# WITHOUT downtime for the core IM service. Idempotent and re-entrant: every
# step is safe to re-run, and each ends with an exit-code gate (G1..G5) so the
# whole flow is mechanically verifiable in CI or by an operator.
# -----------------------------------------------------------------------------
# State machine (producer-first + high-watermark cursor-seed ordering):
#
#   no search
#     -> (1) docker compose --profile search up -d   (Kafka + OpenSearch + indexer)
#     -> (2) seed searchetl cursor to each shard's MAX(id)        [G1]
#     -> (3) turn the real-time producer on (octo-server restart) [G2]
#     -> (4) one-shot backfill of history + inline reconcile gate [G3]
#     -> (5) bind read alias -> physical octo-message index       [G4]
#     -> (6) switch octo-server reader to es + restart            [G5]
#   search live
#
# Why this order: the producer is turned on (step 3) BEFORE backfill (step 4)
# so no live message written during the historical load is missed — the cursor
# was seeded to the high-watermark first (step 2) so the producer only streams
# messages newer than the cut-over, never the full history. Backfill and the
# live stream overlap safely because the ES doc _id = message_id makes every
# write an idempotent upsert.
#
# Usage:
#   docker/scripts/search-upgrade.sh            # run all steps from the start
#   docker/scripts/search-upgrade.sh --from 3   # resume at step N (1..6)
#   docker/scripts/search-upgrade.sh --check     # run only the verification
#                                                # gates against current state
#
# All `docker compose` calls run from docker/ with the repo's compose file.
# Override OCTO_SEARCH_* in docker/.env exactly as the compose file documents.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$HERE/.." && pwd)"
cd "$DOCKER_DIR"

# Pull the index / alias / shard settings from docker/.env (the same file
# Compose reads) so this script resolves them from the SAME source of truth the
# running stack uses. Without this, a documented OCTO_SEARCH_* override in .env
# would steer octo-server / the compose jobs one way while the script bound or
# checked another (wrong alias, wrong shards, a G5 that passes against an alias
# octo-server is not configured to read).
#
# We do NOT `source` the whole file (it holds passwords / DSNs that are not safe
# to eval as shell); we read only the three keys this script needs, and only
# when not already set in the environment (shell env wins, matching Compose).
ENV_FILE="${ENV_FILE:-$DOCKER_DIR/.env}"
env_get() {
  # last uncommented KEY=VALUE wins (Compose semantics); strip surrounding quotes.
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
: "${OCTO_SEARCH_ES_INDEX:=$(env_get OCTO_SEARCH_ES_INDEX)}"
: "${OCTO_SEARCH_OS_READ_ALIAS:=$(env_get OCTO_SEARCH_OS_READ_ALIAS)}"
: "${OCTO_SEARCH_SHARD_TABLES:=$(env_get OCTO_SEARCH_SHARD_TABLES)}"

# Resolve the docker compose CLI (v2 plugin or legacy binary).
if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  echo "FATAL: neither 'docker compose' nor 'docker-compose' is available" >&2
  exit 2
fi

ES_INDEX="${OCTO_SEARCH_ES_INDEX:-octo-message}"
READ_ALIAS="${OCTO_SEARCH_OS_READ_ALIAS:-wukongim-messages-read}"
SHARDS="${OCTO_SEARCH_SHARD_TABLES:-message,message1,message2,message3,message4}"

log()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
ok()   { printf '\033[32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# persist_env durably writes KEY=VALUE into docker/.env so the live state set by
# a step survives the NEXT ordinary `docker compose up -d` (otherwise a recreate
# before the operator hand-edits .env would silently revert search to off). It
# replaces an existing uncommented assignment in place, else appends. Compose
# auto-loads docker/.env from this directory, so this is the single source of
# truth the running stack reads (and the file this script sourced on startup).
persist_env() {
  local key="$1" val="$2"
  touch "$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # in-place replace (portable: rewrite via tmp file, no sed -i flavor issues)
    awk -v k="$key" -v v="$val" \
      'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' \
      "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
  echo "  persisted ${key}=${val} -> ${ENV_FILE}"
}

# persist_profile adds a profile to COMPOSE_PROFILES in docker/.env WITHOUT
# clobbering profiles already enabled (e.g. `summary`). It reads the current
# value (env wins over .env, like Compose), unions in the new profile, and
# writes the comma-joined, de-duplicated result back.
persist_profile() {
  local add="$1" current merged
  current="${COMPOSE_PROFILES:-$(env_get COMPOSE_PROFILES)}"
  # union: keep existing order, append `add` only if not already present.
  merged="$(printf '%s' "$current" | tr ',' '\n' | sed '/^[[:space:]]*$/d' \
    | awk -v a="$add" '{print} $0==a{seen=1} END{if(!seen)print a}' \
    | paste -sd, -)"
  COMPOSE_PROFILES="$merged"
  persist_env COMPOSE_PROFILES "$merged"
}

# os_curl runs a curl INSIDE the search-opensearch container so we do not depend
# on the host being able to reach the loopback-bound OpenSearch port, and it
# works regardless of OCTO_SEARCH_OPENSEARCH_BIND. First arg is the URL path;
# any further args pass through to curl (e.g. -XPOST -d '{...}').
os_curl() {
  local path="$1"; shift
  "${DC[@]}" exec -T search-opensearch \
    curl -sS -H 'Content-Type: application/json' "$@" "http://localhost:9200${path}"
}

# --------------------------------------------------------------------------
# Steps
# --------------------------------------------------------------------------

step1_infra_up() {
  log "Step 1/6: bring the search infrastructure up (Kafka + OpenSearch + indexer)"
  # Persist the profile so a future `docker compose up -d` keeps the search
  # infrastructure running (and so the search-tools jobs below resolve). Merges
  # into any existing COMPOSE_PROFILES (e.g. summary) rather than replacing it.
  persist_profile search
  COMPOSE_PROFILES=search "${DC[@]}" up -d --build \
    search-opensearch search-kafka search-kafka-init es-indexer
  echo "Waiting for OpenSearch to report a non-red cluster status..."
  for _ in $(seq 1 40); do
    status="$(os_curl "/_cluster/health" 2>/dev/null | grep -o '"status":"[a-z]*"' || true)"
    case "$status" in
      *green*|*yellow*) ok "OpenSearch cluster is up ($status)"; return 0 ;;
    esac
    sleep 3
  done
  fail "OpenSearch did not become ready in time"
}

step2_seed_cursor() {
  log "Step 2/6: seed the searchetl extraction cursor to each shard's high-watermark"
  # One-shot job; --abort-on-container-exit surfaces its exit code as ours.
  COMPOSE_PROFILES=search-tools "${DC[@]}" run --rm search-cursor-seed
  gate_G1
}

step3_producer_on() {
  log "Step 3/6: turn the real-time producer on (octo-server restart, TS_KAFKA_ON=true)"
  # Persist BEFORE recreating so the live state and docker/.env never diverge —
  # a later ordinary `docker compose up -d` will not silently revert the flip.
  persist_env OCTO_SEARCH_PRODUCER_ON true
  "${DC[@]}" up -d octo-server
  gate_G2
}

step4_backfill() {
  log "Step 4/6: one-shot historical backfill + inline reconcile gate"
  gate_opensearch_reachable
  COMPOSE_PROFILES=search-tools "${DC[@]}" run --rm search-backfill
  gate_G3
}

step5_bind_alias() {
  log "Step 5/6: bind the read alias -> physical index (atomic, single-pointing)"
  # remove the alias from ANY index it currently points at (must_exist:false so
  # the first bind does not error), then add it to the physical index — one
  # atomic _aliases call, no half-new/half-old window.
  os_curl "/_aliases" -XPOST -d "{
    \"actions\": [
      { \"remove\": { \"index\": \"*\", \"alias\": \"${READ_ALIAS}\", \"must_exist\": false } },
      { \"add\":    { \"index\": \"${ES_INDEX}\", \"alias\": \"${READ_ALIAS}\" } }
    ]
  }" | grep -q '"acknowledged":true' || fail "alias bind call was not acknowledged"
  gate_G4
}

step6_reader_es() {
  log "Step 6/6: switch the octo-server reader to es + restart"
  # Persist BEFORE recreating so docker/.env reflects the live reader backend.
  persist_env OCTO_SEARCH_BACKEND es
  "${DC[@]}" up -d octo-server
  gate_G5
}

# --------------------------------------------------------------------------
# Gates (each is exit-code decisive)
# --------------------------------------------------------------------------

gate_opensearch_reachable() {
  os_curl "/_cluster/health" >/dev/null 2>&1 \
    || fail "OpenSearch is not reachable — run step 1 first"
}

# G1: every present shard's cursor >= that shard's MAX(id) (seeded, not zero).
gate_G1() {
  log "Gate G1: searchetl cursor seeded to high-watermark"
  local bad=0
  # Split the comma-separated shard list without disturbing the default IFS the
  # `read` below relies on for tab-splitting MySQL's -B output.
  local shard_list
  shard_list="$(echo "$SHARDS" | tr ',' ' ')"
  for t in $shard_list; do
    t="$(echo "$t" | tr -d ' ')"; [ -z "$t" ] && continue
    # Reject anything that is not a strict SQL identifier before interpolating.
    case "$t" in
      *[!A-Za-z0-9_]*) fail "G1: invalid shard table name '$t' (allowed: A-Za-z0-9_)" ;;
    esac
    exists="$("${DC[@]}" exec -T mysql sh -lc \
      "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -N -B \"\${MYSQL_DATABASE:-octo}\" -e \"SHOW TABLES LIKE '$t';\"" 2>/dev/null | wc -l)"
    [ "$exists" -eq 0 ] && { echo "  $t: absent (skipped)"; continue; }
    read -r maxid cur <<EOF2
$("${DC[@]}" exec -T mysql sh -lc \
  "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysql -N -B \"\${MYSQL_DATABASE:-octo}\" -e \"SELECT COALESCE(MAX(id),0), COALESCE((SELECT last_id FROM octo_etl_es_cursor WHERE shard_table='$t'),-1) FROM \\\`$t\\\`;\"" 2>/dev/null)
EOF2
    if [ "${cur:--1}" -ge "${maxid:-0}" ] && [ "${cur:--1}" -ge 0 ]; then
      echo "  $t: cursor=$cur >= max=$maxid"
    else
      echo "  $t: cursor=$cur < max=$maxid  <-- NOT seeded"; bad=1
    fi
  done
  if [ "$bad" -eq 0 ]; then
    ok "all shard cursors at/above high-watermark"
  else
    fail "G1: a shard cursor is below its MAX(id) — producer would double-ingest history"
  fi
}

# G2: the producer is running (octo-server up with TS_KAFKA_ON=true).
gate_G2() {
  log "Gate G2: real-time producer is on"
  local on
  # shellcheck disable=SC2016  # ${TS_KAFKA_ON} must expand INSIDE the container, not here.
  on="$("${DC[@]}" exec -T octo-server sh -lc 'echo "${TS_KAFKA_ON:-}"' 2>/dev/null | tr -d '\r')"
  [ "$on" = "true" ] || fail "G2: octo-server TS_KAFKA_ON is '$on', expected 'true'"
  # The searchetl scheduler logs a start line when Kafka.On gates it through.
  ok "octo-server is running with TS_KAFKA_ON=true (producer scheduler active)"
}

# G3: when run right after step 4, the backfill job exited 0 — which means its
# INLINE reconcile gate passed (the job fails non-zero on any count/sample
# mismatch). This gate then re-asserts the index is readable. In --check mode it
# CANNOT re-derive the historical reconcile (the backfill is not re-run), so it
# only verifies the index is readable and says so honestly.
gate_G3() {
  if [ "${CHECK_MODE:-0}" = "1" ]; then
    log "Gate G3: index readable (--check: reconcile NOT re-verified here)"
  else
    log "Gate G3: backfill exited 0 (inline reconcile passed) + index readable"
  fi
  local count
  count="$(os_curl "/${ES_INDEX}/_count" 2>/dev/null | grep -o '"count":[0-9]*' | head -1 | cut -d: -f2)"
  [ -n "${count:-}" ] || fail "G3: could not read ${ES_INDEX} doc count"
  echo "  ${ES_INDEX} doc count = $count"
  if [ "${CHECK_MODE:-0}" = "1" ]; then
    echo "  (--check only reads _count; reconcile correctness is proven by the"
    echo "   backfill exit code at step 4 — re-run 'search-upgrade.sh --from 4'"
    echo "   to re-gate it.)"
    ok "index ${ES_INDEX} is readable (reconcile not re-verified in --check)"
  else
    ok "backfill reconcile gate passed at step 4; index ${ES_INDEX} is readable"
  fi
}

# G4: the read alias resolves to exactly one index — the physical index.
gate_G4() {
  log "Gate G4: read alias bound to the physical index (single-pointing)"
  local bound
  bound="$(os_curl "/_alias/${READ_ALIAS}" 2>/dev/null || true)"
  echo "$bound" | grep -q "\"${ES_INDEX}\"" \
    || fail "G4: alias ${READ_ALIAS} is not bound to ${ES_INDEX} (got: $bound)"
  # Reject a multi-index alias (half-new/half-old would serve partial data).
  # The _alias response is keyed by index name, each carrying one "aliases"
  # object, so the count of "aliases" occurrences == number of indices bound.
  local n
  n="$(echo "$bound" | grep -o '"aliases"' | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ] || fail "G4: alias ${READ_ALIAS} points at $n indices (must be exactly 1): $bound"
  ok "alias ${READ_ALIAS} -> ${ES_INDEX} (single-pointing)"
}

# G5: the reader is on es AND a real query through the alias SUCCEEDS (the alias
# resolves and OpenSearch answers). A zero-message deployment is a valid pass —
# we assert the search path works, not that the corpus is non-empty.
gate_G5() {
  log "Gate G5: reader switched to es and the alias serves real results"
  local be
  # shellcheck disable=SC2016  # ${OCTO_SEARCH_BACKEND} must expand INSIDE the container, not here.
  be="$("${DC[@]}" exec -T octo-server sh -lc 'echo "${OCTO_SEARCH_BACKEND:-}"' 2>/dev/null | tr -d '\r')"
  [ "$be" = "es" ] || fail "G5: octo-server OCTO_SEARCH_BACKEND is '$be', expected 'es'"
  # A match_all through the read alias must SUCCEED (a real response with a hit
  # total proves the alias resolves to a real index and OpenSearch is serving).
  # We deliberately do NOT require hits>=1: a brand-new / empty install upgrades
  # correctly and legitimately has zero messages.
  local resp hits
  resp="$(os_curl "/${READ_ALIAS}/_search" -XPOST -d '{"size":0,"query":{"match_all":{}}}' 2>/dev/null || true)"
  echo "$resp" | grep -q '"hits"' \
    || fail "G5: alias ${READ_ALIAS} did not answer a search (got: $resp)"
  hits="$(echo "$resp" | grep -o '"value":[0-9]*' | head -1 | cut -d: -f2)"
  echo "  alias ${READ_ALIAS} total hits = ${hits:-0}"
  if [ "${hits:-0}" -ge 1 ]; then
    ok "reader on es; alias-backed search returns ${hits} hit(s) — search is live"
  else
    ok "reader on es; alias-backed search succeeds (corpus currently empty — valid for a fresh install)"
  fi
}

run_all_gates() {
  gate_opensearch_reachable
  gate_G1; gate_G2; gate_G3; gate_G4; gate_G5
  if [ "${CHECK_MODE:-0}" = "1" ]; then
    log "Gates G1,G2,G4,G5 verified live; G3 confirmed the index is readable (reconcile not re-run in --check)."
  else
    log "All gates G1..G5 passed — search is live and self-consistent."
  fi
}

# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------
FROM_STEP=1
CHECK_MODE=0
case "${1:-}" in
  --check) CHECK_MODE=1; run_all_gates; exit 0 ;;
  --from)  FROM_STEP="${2:-1}" ;;
  "" ) ;;
  *) echo "usage: $0 [--from N | --check]"; exit 2 ;;
esac

# Validate --from: must be an integer 1..6 (the step count). Without this guard,
# `--from 7` would skip every step and `--from foo` would crash inside the `-le`
# arithmetic — either way the script could fall through to "Upgrade complete" and
# report a false success without having run anything.
if ! [[ "$FROM_STEP" =~ ^[1-6]$ ]]; then
  echo "error: --from must be an integer 1..6 (got '${FROM_STEP}')" >&2
  echo "usage: $0 [--from N | --check]" >&2
  exit 2
fi

[ "$FROM_STEP" -le 1 ] && step1_infra_up
[ "$FROM_STEP" -le 2 ] && step2_seed_cursor
[ "$FROM_STEP" -le 3 ] && step3_producer_on
[ "$FROM_STEP" -le 4 ] && step4_backfill
[ "$FROM_STEP" -le 5 ] && step5_bind_alias
[ "$FROM_STEP" -le 6 ] && step6_reader_es

log "Upgrade complete — search is live."
echo "  The live state has been persisted to ${ENV_FILE}:"
echo "    COMPOSE_PROFILES=search"
echo "    OCTO_SEARCH_BACKEND=es"
echo "    OCTO_SEARCH_PRODUCER_ON=true"
echo "  so a future 'docker compose up -d' keeps search on. Re-run with --check"
echo "  at any time to re-assert gates G1..G5 against the running stack."
