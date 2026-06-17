# OCTO golden-path demo — reference stack + streaming channel bot

A reproducible, **one-command** path that brings up the OCTO reference stack
locally and wires a [`cc-channel-octo`](https://github.com/Mininglamp-OSS/cc-channel-octo)
bot that **streams** a reply when a human @mentions it in a group channel.

This is the demo QA validates end-to-end (OCT-12).

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
  Agent SDK subprocess that generates the streamed reply.

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
and add the bot), **@mention the bot**, and watch the reply stream back
token-by-token.

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
  (stack) and `OCTO_BOT_TOKEN=… ./run.sh` (bot), documented here.
- **Bot replies to a human @mention in a group channel, streamed back** → the
  bot joins the group (scripted via `OCTO_HUMAN_UID`, or added in web) and the
  Claude Agent SDK streams its reply; `cc-channel-octo`'s stream relay posts it
  incrementally. Validated in octo-web (QA: OCT-12).

## QA end-to-end test plan (OCT-12)

1. `./run.sh` → confirm all 8 services report `healthy` (`./run.sh ps`) and
   `curl http://localhost:28080/v1/ping` returns `{"status":200}`.
2. Log into octo-web as superAdmin; create a bot via BotFather `/newbot`; copy
   the `bf_` token.
3. `OCTO_BOT_TOKEN=bf_… ./run.sh`; confirm `bot.log` shows
   `Ready — listening for messages`.
4. In octo-web, create a group, add the bot (or use `OCTO_HUMAN_UID` to seed it),
   and @mention the bot.
5. **Expected:** the bot replies in-channel and the reply renders incrementally
   (streamed), not as one delayed block.
