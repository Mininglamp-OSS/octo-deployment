# OCTO golden-path demo — reference stack + channel bot

A reproducible, **one-command** path that brings up the OCTO reference stack
locally and wires a [`cc-channel-octo`](https://github.com/Mininglamp-OSS/cc-channel-octo)
bot that **replies** when a human @mentions it in a group channel. While the
bot's Claude Agent SDK turn runs, the channel shows a live typing indicator;
the reply is then posted in-channel (split into multiple messages if long).

This is the demo QA validates end-to-end (OCT-12).

> **Streaming status (read this).** True token-by-token streaming (the WuKongIM
> `IMStreamStart`→items→`IMStreamEnd` protocol) is **not** available to a
> `cc-channel-octo` bot today: those stream routes are exposed only on the
> internal `modules/robot` agent path, not on the public `/v1/bot` API the
> gateway uses (`/v1/bot` has no `stream/start` or `stream/end` route; the
> gateway removed its dead stream path in cc-channel-octo `b7139d2`). The bot
> therefore delivers a **typing indicator + a posted reply**, not an
> incrementally-rendered bubble. Adding incremental streaming to the public bot
> API + re-wiring the gateway is tracked as a follow-up (see OCT-10 children).

## What comes up

A focused subset of the canonical `../../docker/docker-compose.yaml` (that file
stays the single source of truth — this demo only selects services and generates
a local `.env`):

| Service | Role | Host endpoint (loopback) |
|---|---|---|
| `octo-server` | core API + WS gateway | `:28081` (direct REST), via nginx at `:28080` |
| `wukongim` | IM message bus | `:25001/25100/25200` |
| `web` (octo-web) | the chat UI | `:28083`, via nginx at `:28080` |
| `nginx` | ingress (API + web + `/ws`) | **`:28080`** ← clients dial this |
| `mysql` · `redis` · `minio` (+`minio-init`) | backing services | loopback only |

`admin`, `matter`, and the `summary-*` services are intentionally **not** part of
the golden path. `preflight` runs automatically as a dependency gate.

## Prerequisites

- Docker (with Compose v2) + `openssl` + `curl`
- For the bot: a built [`cc-channel-octo`](https://github.com/Mininglamp-OSS/cc-channel-octo)
  checkout (`npm install && npm run build`) and **Claude model credentials in
  your environment** (`ANTHROPIC_API_KEY`, or `ANTHROPIC_AUTH_TOKEN` +
  `ANTHROPIC_BASE_URL` for a gateway). The gateway forwards these to the Claude
  Agent SDK subprocess that generates the bot's reply.

## Quick start

```bash
cd demo/golden-path

# 1. Bring up the reference stack (generates .env with fresh secrets the first time).
./run.sh
#    → prints the superAdmin password and the octo-web URL.

# 2. Create a bot to get a bf_… token (one-time, via BotFather):
#    - open http://localhost:28083, log in as superAdmin (password from step 1)
#    - DM @BotFather:  send  /newbot  then a name; copy the bf_… token it returns
#      (BotFather's onboarding doc is also served at
#       http://localhost:28080/v1/bot/setup-quickstart.md)

# 3. Re-run, wired with the token — the bot comes online against the local stack:
OCTO_BOT_TOKEN=bf_xxxxxxxx ./run.sh

# 3b. (optional) also seed the demo group from the script — pass the UID of the
#     human who will @mention the bot (e.g. your superAdmin/registered user):
OCTO_HUMAN_UID=<your-user-uid> OCTO_BOT_TOKEN=bf_xxxxxxxx ./run.sh
```

Then in octo-web (`http://localhost:28083`): open the demo group (or create one
and add the bot), **@mention the bot**, and watch for the typing indicator
followed by the bot's posted reply (see **Streaming status** above for why this
is not a token-by-token bubble).

### Lifecycle

```bash
./run.sh ps       # show stack status
./run.sh logs -f  # follow stack logs
./run.sh down      # stop the stack (data volumes preserved)
./run.sh nuke      # stop + delete volumes AND the generated .env (full reset)
kill $(cat bot.pid)  # stop the bot gateway
tail -f bot.log      # follow the bot
```

## How isolation works (safety)

- **Secrets** are generated into a gitignored `.env` (`openssl rand`), never
  committed. Delete `.env` (or `./run.sh nuke`) to rotate.
- **The bot config is fully isolated** from any real `~/.cc-channel-octo`
  production config: `wire-bot.sh` writes a demo-local `$HOME`
  (`./.cc-octo-home/.cc-channel-octo/…`) and launches the gateway with that
  `HOME`, so your live bots/config are never touched.
- The compose project is namespaced `octo-golden`, so it won't collide with
  other local stacks.

## Acceptance mapping (OCT-10 / OCT-18)

- **Documented, reproducible script brings up the stack + a bot** → `./run.sh`
  (stack) and `OCTO_BOT_TOKEN=… ./run.sh` (bot), documented here. ✅
- **Bot replies to a human @mention in a group channel** → the bot joins the
  group (scripted via `OCTO_HUMAN_UID`, or added in web) as a `robot=1` member,
  shows a typing indicator while the Claude Agent SDK turn runs, then posts its
  reply via `cc-channel-octo`'s relay (`sendMessage` + splitting). Validated in
  octo-web (QA: OCT-12). ⚠️ **"streamed back" caveat:** the reply is posted, not
  incrementally rendered — see **Streaming status** above. Whether the demo's
  acceptance requires true incremental streaming is a scope call on OCT-10.

## QA end-to-end test plan (OCT-12)

1. `./run.sh` → confirm all 8 services report `healthy` (`./run.sh ps`) and
   `curl http://localhost:28080/v1/ping` returns `{"status":200}`.
2. Log into octo-web as superAdmin; create a bot via BotFather `/newbot`; copy
   the `bf_` token.
3. `OCTO_BOT_TOKEN=bf_… ./run.sh`; confirm `bot.log` shows
   `Ready — listening for messages`.
4. In octo-web, create a group, add the bot (or use `OCTO_HUMAN_UID` to seed it),
   and @mention the bot.
5. **Expected:** a typing indicator appears while the bot's turn runs, then the
   bot posts its reply in-channel (one or more messages if long). Note this is a
   posted reply, not an incrementally-rendered streaming bubble — see
   **Streaming status** at the top.
