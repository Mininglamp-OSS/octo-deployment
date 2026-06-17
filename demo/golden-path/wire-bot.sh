#!/usr/bin/env bash
# =============================================================================
# wire-bot.sh — wire a cc-channel-octo bot to the local golden-path stack.
#
#   wire-bot.sh <api_base> <bf_token>
#
# Invoked by run.sh once a bot token is supplied. It:
#   1. writes an ISOLATED cc-channel-octo config (a demo-local $HOME so the
#      operator's real ~/.cc-channel-octo production config is never touched),
#   2. optionally creates a demo group channel containing the human + bot
#      (when OCTO_HUMAN_UID is set — bot auto-joins as bot_admin),
#   3. launches the gateway in the background (logs to ./bot.log).
#
# The bot inherits this process's ANTHROPIC_* env, which the Claude Agent SDK
# subprocess uses to generate (and stream) replies. Make sure model credentials
# are present in the environment before running wired.
# =============================================================================
set -euo pipefail

API_BASE="${1:?usage: wire-bot.sh <api_base> <bf_token>}"
BOT_TOKEN="${2:?usage: wire-bot.sh <api_base> <bf_token>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_REPO="${CC_CHANNEL_OCTO_DIR:-$HOME/Octo/cc-channel-octo}"   # built gateway checkout
DEMO_HOME="$HERE/.cc-octo-home"                                # isolated HOME for the bot
CFG_DIR="$DEMO_HOME/.cc-channel-octo"
BOT_ID="golden"
BOT_LOG="$HERE/bot.log"

log()  { printf '\033[1;36m[wire-bot]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[wire-bot]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[wire-bot] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. validate the token against the live stack (cheap, catches typos early)
# -----------------------------------------------------------------------------
log "validating bot token against $API_BASE …"
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $BOT_TOKEN" \
  "$API_BASE/v1/bot/groups" || true)
case "$code" in
  200|404) log "token accepted (HTTP $code)";;
  401|403) die "bot token rejected (HTTP $code) — re-check the bf_… token from BotFather";;
  *)       warn "unexpected HTTP $code probing /v1/bot/groups; continuing anyway";;
esac

# -----------------------------------------------------------------------------
# 2. optional: create a demo group channel (human + bot)
# -----------------------------------------------------------------------------
# A bot that creates a group auto-joins it as bot_admin. Supplying OCTO_HUMAN_UID
# (the user who will @mention the bot — e.g. your superAdmin/registered user)
# seeds the group with that human as a member so the @mention has somewhere to
# land. Without it, create/join the group from octo-web instead (see README).
if [ -n "${OCTO_HUMAN_UID:-}" ]; then
  log "creating demo group channel (creator + member: $OCTO_HUMAN_UID)…"
  resp=$(curl -s -H "Authorization: Bearer $BOT_TOKEN" -H "Content-Type: application/json" \
    -X POST "$API_BASE/v1/bot/createGroup" \
    -d "{\"name\":\"Golden Path Demo\",\"members\":[\"$OCTO_HUMAN_UID\"],\"creator\":\"$OCTO_HUMAN_UID\"}" || true)
  group_no=$(printf '%s' "$resp" | sed -nE 's/.*"group_no"[: ]*"([^"]+)".*/\1/p')
  if [ -n "$group_no" ]; then
    log "demo group created: group_no=$group_no  (bot auto-joined as bot_admin)"
  else
    warn "group create did not return a group_no — response: $resp"
    warn "create the group from octo-web instead and add the bot."
  fi
else
  log "OCTO_HUMAN_UID not set — skipping scripted group creation."
  log "  (you'll create the group + add the bot from octo-web; see README)"
fi

# -----------------------------------------------------------------------------
# 3. write the ISOLATED cc-channel-octo config
# -----------------------------------------------------------------------------
log "writing isolated bot config under $CFG_DIR (real ~/.cc-channel-octo untouched)"
mkdir -p "$CFG_DIR/$BOT_ID"
cat > "$CFG_DIR/config.json" <<JSON
{
  "apiUrl": "$API_BASE",
  "bots": [{ "id": "$BOT_ID" }],
  "sdk": { "allowedTools": "*", "permissionMode": "bypassPermissions", "toolProgress": true },
  "rateLimit": { "maxPerMinute": 30 }
}
JSON
cat > "$CFG_DIR/$BOT_ID/config.json" <<JSON
{
  "botToken": "$BOT_TOKEN"
}
JSON
chmod 600 "$CFG_DIR/config.json" "$CFG_DIR/$BOT_ID/config.json"

# Friendly persona so the streamed reply is obviously "the demo bot".
cat > "$CFG_DIR/$BOT_ID/SOUL.md" <<'MD'
You are the OCTO golden-path demo bot. Be concise and friendly. When a human
@mentions you in a group, greet them and confirm the streaming reply works.
MD

# -----------------------------------------------------------------------------
# 4. launch the gateway (isolated HOME → isolated baseDir)
# -----------------------------------------------------------------------------
[ -f "$CC_REPO/dist/index.js" ] || die "cc-channel-octo build not found at $CC_REPO/dist/index.js (set CC_CHANNEL_OCTO_DIR or run 'npm run build' there)"

if [ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  warn "no ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN in env — the bot will connect"
  warn "but the Claude Agent SDK cannot generate a reply without model credentials."
fi

log "starting gateway (logs → $BOT_LOG)…"
HOME="$DEMO_HOME" nohup node "$CC_REPO/dist/index.js" > "$BOT_LOG" 2>&1 &
echo $! > "$HERE/bot.pid"
log "gateway started (pid $(cat "$HERE/bot.pid")). Tail it with:  tail -f $BOT_LOG"

cat <<EOF

$(printf '\033[1;32m✓ Bot wired.\033[0m')

  • Watch it connect:   tail -f $BOT_LOG   (look for "Ready — listening for messages")
  • In octo-web (http://localhost:28083), open the demo group (or create one and add the bot),
    then @mention the bot. The reply streams back token-by-token.
  • Stop the bot:        kill \$(cat $HERE/bot.pid)

EOF
