# OCTO · Docker Compose deployment

A self-contained one-shot deployment of the full OCTO stack — server,
admin console, web UI, matter, smart-summary, WuKongIM, MySQL, Redis,
MinIO, and an nginx reverse proxy — wired together by a single
`docker-compose.yaml`.

This stack targets:

- single-host evaluation deployments
- internal demo / staging
- the canonical "I just want to try OCTO" path

For multi-node / production, use `kustomize/base/` and bring your own
DB / cache / object store.

> 中文版：[README.zh.md](./README.zh.md)

## TL;DR — fastest path from `git clone` to a usable OCTO

```bash
git clone https://github.com/Mininglamp-OSS/octo-deployment.git
cd octo-deployment
./setup.sh                                  # interactive prompts
(cd docker && docker compose up -d --wait)  # subshell: stay in repo root
./setup.sh --verify                         # smoke test (admin login + presign PUT)

# Open in browser, password printed at the end of setup.sh:
#   Admin: http://<your-domain>:28080/admin/   (user: superAdmin)
#   Web:   http://<your-domain>:28080/
```

The single open port for client traffic is **TCP 28080** (configurable
via `OCTO_HTTP_PORT`). All backing services (MinIO API/console, MySQL,
Redis, WuKongIM monitor, direct REST ports) default to loopback. See
[Network surface](#network-surface) for the rationale.

---

## ⚠ Pre-flight: existing OCTO deployments on this host

> **READ THIS BEFORE EVERY `docker compose up -d` / `docker compose down -v`
> if there is any chance another OCTO stack already lives on this host.**

`docker-compose.yaml` sets a top-level `name: octo` as the default
project name (so a vanilla clone produces stable in-stack DNS names
`mysql`, `redis`, `octo-server`, … referenceable by literal hostname).
Compose v2 precedence still lets `COMPOSE_PROJECT_NAME` override that
top-level `name:` — both for the network/container suffix AND (via the
explicit `name:` on each volume in the `volumes:` block) for the named
volumes themselves. The side effect of the default is that **two
independent clones of this repo on the same host that DO NOT override
the project name share the same volumes** — meaning a
`docker compose down -v` from a "fresh" clone in `/tmp/foo` will erase
the named volumes (and therefore the MySQL data, MinIO objects, WuKongIM
message queues, etc.) belonging to a production clone in
`/opt/octo-deployment`. That is exactly how `im-test` lost its entire
user database on 2026-05-16 (INCIDENT-2026-05-16-001).

To make this safe, the named volumes are now templated on
`${COMPOSE_PROJECT_NAME:-octo}` (see the `volumes:` block in
`docker-compose.yaml`). An operator who wants a second, isolated stack
on a host that already runs OCTO only needs to override the project
name before bringing it up:

```bash
# Before bringing up a SECOND stack on a host that already runs OCTO:
export COMPOSE_PROJECT_NAME=octo-fz   # any unique suffix
./setup.sh --non-interactive --domain octo-fz.local --ip 127.0.0.1
cd docker
docker compose up -d                  # volumes: octo-fz_mysql-data, …
```

> 🔒 **`setup.sh` persists `COMPOSE_PROJECT_NAME` into `docker/.env`
> after you pick it.** Compose auto-loads `docker/.env` before reading
> either the YAML `name:` or the calling shell's
> `COMPOSE_PROJECT_NAME`, so a later `cd docker && docker compose up -d`
> from a fresh shell still scopes to the chosen project — you do NOT
> have to re-`export` the variable on every login. This also means
> `setup.sh --uninstall` reads the persisted value to scope its volume
> teardown grep (`^${project}_`), so it cannot silently chew through
> volumes from a different `octo-*` stack on the same host.

The two stacks then have fully separate Docker volumes
(`octo_mysql-data` vs `octo-fz_mysql-data`), networks
(`octo_octo-net` vs `octo-fz_octo-net`), and container names
(`octo-mysql-1` vs `octo-fz-mysql-1`). A `down -v` on either one only
removes its own state.

> ⚠️ **Running both stacks live at the same time also requires unique
> host ports + subnet.** `COMPOSE_PROJECT_NAME` only isolates the
> Docker objects (volumes, networks, container names); the compose
> file still publishes the same host ports
> (`OCTO_HTTP_PORT`, `OCTO_HTTPS_PORT`, `OCTO_MYSQL_PORT`,
> `OCTO_REDIS_PORT`, `OCTO_MINIO_API_PORT`, `OCTO_MINIO_CONSOLE_PORT`,
> `OCTO_WK_API_PORT`, `OCTO_WK_WS_PORT`,
> `OCTO_WK_TCP_PORT`, `OCTO_WK_MONITOR_PORT`, `OCTO_SUMMARY_API_PORT`) and uses the same
> default bridge subnet (`OCTO_NETWORK_SUBNET=172.28.0.0/24`). Two
> live stacks on one host will fail with port-bind / IPAM-overlap
> errors unless the second stack's `.env` also overrides every
> `*_PORT` it cares about and gives `OCTO_NETWORK_SUBNET` a non-
> overlapping CIDR (for example `172.29.0.0/24`). If your use case
> is "one stack live at a time, the second clone is just for a
> from-zero verification run", that is fine — bring down stack #1
> (`docker compose stop` — do NOT `down -v`) before bringing stack #2
> up, and the isolated volumes keep each stack's data safe.

### Before any `docker compose down -v` — verify what you are about to delete

`down -v` is destructive and irreversible. Run these two probes first
and confirm the output only references the stack you mean to wipe:

```bash
# 1. List Docker volumes that would be removed (must all belong to YOUR project)
docker compose config --volumes        # the volume keys this file declares
# Pin the scan to YOUR project — use literal prefix (grep -F), not the broad
# `^octo([-_]|$)` regex which matches every OCTO stack on this host.
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' docker/.env 2>/dev/null | cut -d= -f2)"
PROJECT="${PROJECT:-octo}"
docker volume ls --format '{{.Name}}' | grep -F "${PROJECT}_" # actual volumes touched

# 2. List containers in the OCTO namespace (must all belong to YOUR project)
docker ps --filter 'name=octo' --format '{{.Names}}'

# 3. If anything in (1) or (2) is NOT yours, STOP. Set
#    COMPOSE_PROJECT_NAME to your stack's suffix and re-check.
#    `docker ps` itself does NOT read COMPOSE_PROJECT_NAME (that env
#    var is consumed by `docker compose` only), so the command form
#    has to either go through `docker compose ps` OR filter by the
#    project-name prefix directly:
#       COMPOSE_PROJECT_NAME=octo-fz docker compose ps
#       docker ps --filter name=octo-fz
```

`setup.sh` runs an equivalent check at the top of each invocation and
warns when it finds existing OCTO containers / volumes on the host.
The warning is informational, NOT a block — you still have to be the
one who chooses the project name. Treat the prompt as the "did you
mean to do this on this host?" gate.

> 💡 **The 100% safe option for a clean from-zero E2E test is an
> ephemeral VM or a host with no existing OCTO deployment.** Volume
> isolation via `COMPOSE_PROJECT_NAME` protects against `down -v`
> collisions, but a single typo (`COMPOSE_PROJECT_NAME=octo` instead of
> `octo-fz`) is enough to break that protection. When in doubt, spin up
> a throwaway machine.

---

## Quick start

### Prerequisites checklist

- Linux or macOS host with `bash` ≥4, `openssl`, and either the Docker
  Compose v2 plugin (`docker compose`) or the standalone `docker-compose`
  binary on `$PATH`.
- The Docker daemon is running and the invoking user can reach it
  (`docker info` succeeds without `sudo`).
- **One open TCP port for client traffic**: `28080` (nginx HTTP,
  `OCTO_HTTP_PORT`). When you bring up HTTPS via the certs flow, the
  client port becomes `28443` (`OCTO_HTTPS_PORT`). All other ports
  (MinIO, MySQL, Redis, WuKongIM monitor, direct REST) default to
  loopback. The WuKongIM native chat transports (`25100` TCP / `25200`
  WS) only need to be reachable if you connect **native chat clients**
  directly to WuKongIM; browser / SPA chat traffic flows through nginx
  `/ws`. The WuKongIM manager API on `25001` is an admin / debug
  surface (not a chat transport) and stays on loopback regardless of
  client kind — see the network-surface table below.
- ≥ 4 GiB RAM, ≥ 10 GiB free disk for the named volumes.
- Outbound network access to `docker.io` (or a configured mirror) for
  pulling the `mininglamposs/*`, `mysql:8`, `redis:7-alpine`,
  `minio/minio`, `wukongim/wukongim`, and `nginx:1.27-alpine` images.
- **If another OCTO stack already runs on this host:** read the
  pre-flight section above and decide on a non-default
  `COMPOSE_PROJECT_NAME` before continuing.

Recommended (interactive setup):

```bash
git clone https://github.com/Mininglamp-OSS/octo-deployment.git
cd octo-deployment
./setup.sh                                  # interactive prompts
(cd docker && docker compose up -d --wait)  # subshell — keeps you in repo root
./setup.sh --verify                         # admin login + presign PUT end-to-end
```

`setup.sh` auto-detects the public IP via `ifconfig.me`. If you run
on a host that has one (cloud VM, bare-metal with public IPv4), the
prompt suggests the detected IP as your `OCTO_DOMAIN` default —
override with a real DNS name when you have one, or accept the IP
for an IP-only deployment.

Or non-interactive:

```bash
./setup.sh --non-interactive --domain octo.example.com --ip 1.2.3.4
(cd docker && docker compose up -d --wait)
./setup.sh --verify
```

To enable the optional LLM summary services, add `--summary`:

```bash
./setup.sh --summary --domain octo.example.com --ip 1.2.3.4
(cd docker && docker compose up -d --wait)
```

`setup.sh` writes `docker/.env` with rotated random secrets and a
generated `OCTO_ADMIN_PWD`, then **prints the admin URL + password at
the end of the run** so you do not have to grep `.env` for them. It is
the only path that gets a fresh checkout to a `(healthy)` stack
without manual editing.

Once healthy, the stack is reachable through nginx on
`http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}` (default `http://octo.local:28080`).
Add an `/etc/hosts` entry for `octo.local` if you keep the default domain.

### `setup.sh --verify` smoke test

After `docker compose up -d --wait` reports all services healthy, run
the smoke test to confirm the *external* surface actually works:

```bash
./setup.sh --verify
```

The script probes (and prints PASS/FAIL for each):

1. `docker compose ps` reports no `(unhealthy)` containers, no fatal
   states (`Exited (1)` / `Restarting` / `Dead`), and no expected
   service that is missing or cleanly stopped
2. nginx vhost up (`GET /_nginx_up`)
3. octo-server REST (`GET /api/v1/health`)
4. octo-matter (`GET /matter/health`) — **counted** toward failures
5. MinIO via nginx (`GET /minio/health/live`)
6. admin SPA reachable (`GET /admin/`)
7. web SPA reachable (`GET /`) — confirms the user-facing SPA is
   served end-to-end through the same nginx vhost as `/api/` and `/ws`
8. WuKongIM `/ws` upgrade probe (`GET /ws` with a real RFC 6455
   WebSocket-upgrade handshake via `python3` raw socket) — catches a
   `docker stop wukongim` that leaves the container in `Exited (0)`
   and slips past `(unhealthy)` and the fatal-state set; accepts
   `101` / `400` / `426` as healthy and treats `502` / `503` / `504`
   / `000` / other 4xx-5xx as failure
9. **admin login** (`POST /api/v1/manager/login` as `superAdmin` with
   `OCTO_ADMIN_PWD` from `.env`) — exercises the octo-server + MySQL +
   bcrypt + Redis-cache chain
10. **presigned PUT issuance** (`GET /api/v1/file/upload/credentials`) —
    exercises octo-server's MinIO IAM credential path
11. **1-byte PUT to the signed URL** — exercises nginx forwarding the
    SigV4 path verbatim AND MinIO accepting the signature (this is the
    exact code path that silently dropped image messages on the dual-port
    form before single-port reverse-proxy landed; see
    OOTB-BUG-2026-05-17-001).

Exit code is non-zero on any failure. `python3` is a **hard
prerequisite** of `--verify` — step 8 (WuKongIM `/ws` upgrade probe)
opens a raw socket from python3, and steps 9-11 (admin login, presign
issuance, SigV4 PUT) parse JSON via `python3 -c 'import json'`.
Silently skipping the JSON-parse steps was the gap that hid
OOTB-BUG-2026-05-17-001. Missing `python3` now fails fast with a
non-zero exit; install it (every modern Linux distro ships it in the
base image) and re-run. This is what to run on a new host to confirm
"deployment actually works end-to-end" — separate from "containers
booted".

Step 11 leaves a 1-byte sentinel object in the `file` bucket
(`octo-verify-<timestamp>-<pid>.txt`). It is intentionally left in
place — the bundled `minio/minio` image does NOT ship the `mc` client
(`mc` lives in the separate `minio/mc` image, which is only used by the
one-shot `minio-init` container), so the obvious
`docker exec <project>-minio-1 mc rm ...` command would always fail. A
single byte per `--verify` run is well below noise; if you absolutely
need a clean bucket, run `mc` from its own image against the bucket via
the project's docker network, or hit MinIO's S3 DELETE API with the
admin credentials in `docker/.env`.

### Uninstall / reset

The `setup.sh --uninstall` subcommand walks you through teardown with
three granularity levels:

```bash
./setup.sh --uninstall
```

```
Pick teardown granularity:
  1) Full uninstall   — stop containers AND remove named volumes (DATA LOSS)
  2) Data-only reset  — remove named volumes only (containers will be recreated next up)
  3) Containers only  — stop + remove containers, keep volumes (safe restart prep)
  q) Quit
```

Option 1 is destructive — the script prints the volumes about to be
removed and requires you to type `YES` to confirm. Before running
option 1 or 2, verify the volumes belong to YOUR stack. Always pin the
match to your literal project prefix (`${COMPOSE_PROJECT_NAME}_`), NOT
the broad `^octo([-_]|$)` regex — that regex matches every OCTO stack
on the host (e.g. `octo`, `octo-fz`, `octo-prod`) and can mask
neighboring-stack volumes that you do NOT want to remove.

```bash
# Read your project name from docker/.env (setup.sh persists it there)
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' docker/.env | cut -d= -f2)"
PROJECT="${PROJECT:-octo}"

# List the volumes that would be removed for THIS project only
docker volume ls --format '{{.Name}}' | grep -F "${PROJECT}_"
```

**🟢 Recommended:** use `./setup.sh --uninstall` — it validates the
project name against the Compose pattern, builds the volume list with
literal-prefix matching, previews exactly what will be deleted, and
requires a `YES` confirmation. The manual `docker compose` / `docker
volume rm` commands below are provided only for operators who already
know which project they are tearing down and prefer raw tooling.

Manual equivalents (raw compose — only after the project-name probe above):

```bash
# Full uninstall (DATA LOSS — irreversible)
# `docker compose down -v` only removes the volumes declared by THIS
# compose project (resolved from COMPOSE_PROJECT_NAME in docker/.env),
# so it is safe across multiple OCTO stacks as long as your project
# name is set correctly.
cd docker && docker compose down -v --remove-orphans

# Data-only reset — keep containers' images, drop only this project's volumes.
# `compose down` first, then literal-prefix volume removal (grep -F, not -E,
# so a project name like `octo-fz` will NOT also match `octo-fz-prod_*`).
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)"
PROJECT="${PROJECT:-octo}"
docker compose down
docker volume ls --format '{{.Name}}' \
  | grep -F "${PROJECT}_" \
  | xargs -r docker volume rm

# Containers only — safe restart prep (volumes preserved)
cd docker && docker compose down --remove-orphans
```

**⚠ Before any `docker compose down -v`** read
[Pre-flight: existing OCTO deployments on this host](#-pre-flight-existing-octo-deployments-on-this-host)
above — if you have multiple OCTO stacks on this host with the same
project name, `down -v` from any clone will wipe the shared volumes.

### Manual setup (advanced)

Skip `setup.sh` only if you need to drive the env-file generation from
your own tooling (Ansible, Vault, etc.):

```bash
cp docker/.env.example docker/.env
# Edit docker/.env — rotate ALL placeholders flagged in the file:
#   MYSQL_ROOT_PASSWORD, MINIO_ROOT_PASSWORD, OCTO_MINIO_APP_PASSWORD,
#   OCTO_MATTER_DB_PASSWORD, OCTO_SUMMARY_DB_PASSWORD,
#   OCTO_SUMMARY_READER_PASSWORD,
#   OCTO_MASTER_KEY, OCTO_NOTIFY_INTERNAL_TOKEN, OCTO_WUKONGIM_MANAGER_TOKEN
# Set OCTO_DOMAIN / OCTO_EXTERNAL_IP, and OCTO_ADMIN_PWD if you want
# auto-bootstrap of the first superAdmin (see "First-admin bootstrap").

cd docker
docker compose config            # validate before starting
docker compose up -d
docker compose ps                # all services should reach (healthy)
```

See "Required environment variables" below for the full contract.

---

## Required environment variables

These MUST be changed before bringing the stack up. Defaults are
placeholder values designed to fail fast: `OCTO_MASTER_KEY` is one byte
short of octo-server's length check, `MINIO_ROOT_PASSWORD` is 7 chars
(MinIO requires ≥8) so the `minio` container refuses to boot, the
`minio-init` one-shot aborts on any `CHANGE_ME_*` / `CHG_ME*` value
(case-insensitive) for the MinIO root or app credentials, the
`preflight` one-shot aborts on any `CHANGE_ME_*` / `CHG_ME*` value for
`OCTO_NOTIFY_INTERNAL_TOKEN` and `OCTO_WUKONGIM_MANAGER_TOKEN`, and
`init-extra-dbs.sh` aborts when `MYSQL_ROOT_PASSWORD` is still a
`CHANGE_ME_*` / `CHG_ME*` placeholder, when any service-account
password contains characters outside `[A-Za-z0-9._-]`, or when
`OCTO_MATTER_DB_PASSWORD` / `OCTO_SUMMARY_DB_PASSWORD` /
`OCTO_SUMMARY_READER_PASSWORD` is left at the literal-string defaults
(`matter` / `summary` / `summary_reader`). Together these checks mean
the OOTB stack cannot reach `(healthy)` with any of the placeholder
values still in place.

| Variable | What it is | How to generate |
| --- | --- | --- |
| `MYSQL_ROOT_PASSWORD` | MySQL `root` password (also embedded in `TS_DB_MYSQLADDR` / `DM_MYSQL_DSN` and validated against `[A-Za-z0-9._-]` by `init-extra-dbs.sh` so the Go MySQL DSN parser does not silently misread the user/host boundary; the script also refuses any `CHANGE_ME_*` / `CHG_ME*` casing) | `openssl rand -hex 16` |
| `MINIO_ROOT_PASSWORD` | MinIO root credential — used by `mc admin`, the MinIO console, and the `minio-init` bootstrap. NOT used by octo-server. The 7-char placeholder shipped in `.env.example` trips MinIO's own ≥8-char length check; `minio-init` then independently aborts on any `CHANGE_ME_*` / `CHG_ME*` value (case-insensitive) as defense in depth. | `openssl rand -hex 16` |
| `OCTO_MINIO_APP_PASSWORD` | Application-scoped IAM secret. octo-server signs presigned URLs with this credential pair (NOT the root pair). The `minio-init` service creates the user, attaches the bucket-scoped policy on first boot, AND aborts with a clear error when this value is empty or still a `CHANGE_ME_*` / `CHG_ME*` placeholder (case-insensitive). | `openssl rand -hex 24` |
| `OCTO_MATTER_DB_PASSWORD` | MySQL service account `matter` (full DML on `octo_matter`). `init-extra-dbs.sh` refuses the literal default `matter` so the OOTB stack cannot bring MySQL up with a guess-once credential. | `openssl rand -hex 16` |
| `OCTO_SUMMARY_DB_PASSWORD` | MySQL service account `summary` (full DML on `octo_summary`). `init-extra-dbs.sh` refuses the literal default `summary`. | `openssl rand -hex 16` |
| `OCTO_SUMMARY_READER_PASSWORD` | MySQL service account `summary_reader` (`SELECT` on the OCTO IM schema — see the `GRANT` block in `init-extra-dbs.sh`). `init-extra-dbs.sh` refuses the literal default `summary_reader`. | `openssl rand -hex 16` |
| `OCTO_MASTER_KEY` | 32-byte server master key | `openssl rand -hex 16` |
| `OCTO_NOTIFY_INTERNAL_TOKEN` | HMAC secret octo-server ↔ matter / smart-summary share. The `preflight` one-shot service refuses any `CHANGE_ME_*` / `CHG_ME*` casing. | `openssl rand -hex 32` |
| `OCTO_WUKONGIM_MANAGER_TOKEN` | WuKongIM admin token. Bound on WuKongIM via `WK_MANAGERTOKEN` (Viper auto-binds to YAML `managerToken`) and on octo-server via `TS_WUKONGIM_MANAGERTOKEN`. Leaving it empty makes WuKongIM's manager API reachable AND USABLE without auth — `preflight` refuses any `CHANGE_ME_*` / `CHG_ME*` casing as well. | `openssl rand -hex 32` |
| `LLM_API_KEY` | LLM provider key consumed by matter + smart-summary. Required for those features. The compose file falls back to a fake placeholder for `summary-worker` so the OOTB stack still reaches `(healthy)` — actual summarization calls fail until this is set. | from your provider |

Everything else has sane defaults documented inline in
[`docker/.env.example`](.env.example).

### Backing-service host bindings

`OCTO_MYSQL_BIND`, `OCTO_REDIS_BIND`, `OCTO_MINIO_API_BIND`,
`OCTO_MINIO_CONSOLE_BIND` default to `127.0.0.1`. This means MySQL
(`23306`), Redis (`26379`), MinIO API (`29000`) and the MinIO console
(`29001`) are **only reachable from the host loopback**. The
nginx-proxied paths (`/`, `/api/`, `/v1/`, `/admin/`, `/matter/`,
`/summary/`, `/ws`, and the bucket-name routes
`/file|chat|moment|sticker|report|chatbg|common|download|group|avatar`)
remain public — note that `/minio-console/` is **not** in that list
(see "Network surface" below).

The same loopback default applies to the direct ports for
`octo-server` (`OCTO_SERVER_BIND`), `octo-matter` (`OCTO_MATTER_BIND`),
`smart-summary API` (`OCTO_SUMMARY_API_BIND`), and the WuKongIM
monitor port (`OCTO_WK_MONITOR_BIND`). The first three skip the
`octo_api` / `octo_auth` rate-limit zones the nginx vhost applies to
`/api/`, `/v1/`, `/matter/`, and `/summary/`, so leaving them
loopback-only keeps an operator-debug port from becoming a
rate-limit-free production path. The WuKongIM monitor port is an
admin surface, not a chat transport. The user-facing WuKongIM ports
(API `25001` / TCP `25100` / WS `25200`) **also default to
`127.0.0.1`** — browser / SPA chat traffic reaches WuKongIM through
nginx `/ws`, and the manager API on `25001` is reached via
`docker exec` or an `ssh -L` tunnel against the loopback bind. Flip
`OCTO_WK_TCP_BIND` / `OCTO_WK_WS_BIND` to `0.0.0.0` only if you run
a native mobile / desktop IM client that dials WuKongIM directly
(see [Advanced: direct WuKongIM transports](#advanced-direct-wukongim-transports)
below); the manager-API bind should stay loopback in OOTB deploys.

Override the loopback defaults only if you have rotated all
credentials and placed the host behind a firewall. **Redis runs
without authentication** in this stack — keep `OCTO_REDIS_BIND` on
`127.0.0.1` (or a private interface) until you wire `--requirepass`
into the redis service. See the "Hardening checklist" for the steps.

---

## Network surface

The OOTB stack is **single-port for client traffic**. Browser / mobile
clients only need to reach the nginx vhost on `OCTO_HTTP_PORT` (default
`28080`); everything else — MinIO API, MinIO console, MySQL, Redis,
WuKongIM monitor, and the direct REST ports for octo-server / matter /
summary-api — defaults to loopback. **Operators only need to open one
TCP port (28080) in their firewall.**

| Service | Port (default) | Default bind | Why |
| --- | --- | --- | --- |
| **nginx (HTTP)** | **`28080`** | **`0.0.0.0`** | **user-facing entrypoint — the single open port** |
| nginx (HTTPS) | `28443` (placeholder) | `0.0.0.0` | HTTPS form; disabled by default — see "HTTPS" section below |
| octo-admin | `28082` | `127.0.0.1` | admin SPA — reached via nginx `/admin/` on `28080`. Direct port stays loopback so the admin UI is never on the public IP. Override `OCTO_ADMIN_BIND` only for short-lived diagnostics behind a private network / VPN. |
| octo-web | `28083` | `127.0.0.1` | user SPA — reached via nginx `/` on `28080`. Direct port stays loopback. Override `OCTO_WEB_BIND` only for diagnostics. |
| WuKongIM API | `25001` | `127.0.0.1` | **internal manager / debug API — NOT exposed through nginx**. There is no manager-API location in `docker/nginx/conf.d/octo.conf.template`; OOTB the API is reachable only from the host loopback. Reach it via `docker exec -it <wukongim-container> sh` for diagnostics, or — for short-lived remote access — `ssh -L 5001:127.0.0.1:25001 user@host` and hit `http://localhost:5001/`. Flip `OCTO_WK_API_BIND=0.0.0.0` only on a private network / VPN AFTER you have an auth proxy in front; the manager API has no built-in token gateway. |
| WuKongIM TCP | `25100` | `127.0.0.1` | **native IM transport** — required ONLY if you run a mobile / desktop app that dials WuKongIM over native TCP (browser / SPA traffic uses `/ws` via nginx). To enable: set `OCTO_WK_TCP_BIND=0.0.0.0` in `.env` AND open TCP `25100` on your firewall — see [Advanced: direct WuKongIM transports](#advanced-direct-wukongim-transports). |
| WuKongIM WS | `25200` | `127.0.0.1` | direct WebSocket port — same story as TCP above; browsers go through nginx `/ws`. Override `OCTO_WK_WS_BIND=0.0.0.0` only for native clients that bypass the nginx ingress. |
| octo-server REST | `28081` | `127.0.0.1` | direct REST port for operator smoke tests; production traffic uses nginx `/api/` + `/v1/` (rate-limited via `octo_api`/`octo_auth` zones in `nginx.conf`). Override `OCTO_SERVER_BIND` to widen. |
| octo-matter | `28086` | `127.0.0.1` | direct matter port; production traffic via nginx `/matter/`. Override `OCTO_MATTER_BIND`. |
| smart-summary API | `28087` | `127.0.0.1` | direct summary-api port; production traffic via nginx `/summary/`. Override `OCTO_SUMMARY_API_BIND`. |
| WuKongIM monitor | `25300` | `127.0.0.1` | observability / `/route` admin surface — not a user-facing transport. |
| MinIO API | `29000` | `127.0.0.1` | **single-port form**: object traffic flows through nginx bucket-name routing (`/{bucket}/{key}`). Widen `OCTO_MINIO_API_BIND` only for the legacy dual-port form (see [Dual-port advanced override](#dual-port-advanced-override) below). |
| MinIO console | `29001` | `127.0.0.1` | admin only; reach via SSH tunnel (see below) |
| MySQL | `23306` | `127.0.0.1` | backing service |
| Redis | `26379` | `127.0.0.1` | backing service |

The MinIO console is **not** proxied through nginx by default.
Earlier revisions exposed it under `/minio-console/`, which put the
MinIO admin login one click away from anyone who reached
`OCTO_HTTP_PORT` — and a stack booted with the placeholder root
password would have a known-default credential accepted there.
Operators reach the console via an SSH tunnel against the loopback
bind:

```bash
ssh -L 9001:127.0.0.1:29001 user@host
# then visit http://localhost:9001 in your browser
```

To re-enable the public route (NOT recommended; only do this after
rotating `MINIO_ROOT_PASSWORD` and placing the proxy behind auth),
uncomment the commented-out `octo_minio_console` upstream and
`/minio-console/` location block at the top of
`docker/nginx/conf.d/octo.conf.template`.

### Why single-port works for MinIO presigned URLs

octo-server's `/api/v1/file/*` responses contain **presigned (SigV4)
URLs**. SigV4 signs the canonical request path, so any nginx path
rewrite breaks the signature — but the nginx config does NOT rewrite.
The bucket-name regex location in
`docker/nginx/conf.d/octo.conf.template`:

```nginx
location ~ ^/(file|chat|moment|sticker|report|chatbg|common|download|group|avatar)/.+ {
    proxy_pass http://octo_minio_api;   # NO trailing slash — preserve SigV4 path
    proxy_set_header Host $http_host;
    ...
}
```

forwards `/{bucket}/{key}` requests to MinIO as-is. The client signs
against `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/{bucket}/{key}` and
MinIO verifies against the same canonical path. Both
`TS_MINIO_DOWNLOADURL` (octo-server side) and `MINIO_SERVER_URL` (MinIO
side) default to `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}` so the two
ends stay in sync. The data is protected by:

- the **application-scoped IAM credentials** (`OCTO_MINIO_APP_*`) that
  octo-server signs with — provisioned by the one-shot `minio-init`
  service (see "MinIO bootstrap & credential scoping" below). These
  credentials grant read/write/delete on the bucket whitelist and
  nothing else; they do NOT grant `mc admin` / IAM / console rights,
  and the MinIO root pair never reaches octo-server's environment.
- the **short TTL** of every presigned URL (minutes, not days),
- octo-server's authorisation layer in front of `/api/v1/file/*`.

A diagnostics-only `/minio/` location stays in nginx for sidecar
probes (e.g. `curl http://host:28080/minio/health/live`); it is
NOT used for client object traffic.

### Dual-port advanced override

The previous dual-port form — clients reaching MinIO directly on
`OCTO_MINIO_API_PORT` (29000) — still works for operators who want it
(sidecar diagnostics from another host, very high object throughput
that wants to skip nginx, etc.). To use it:

```bash
# in docker/.env
OCTO_MINIO_API_BIND=0.0.0.0
TS_MINIO_DOWNLOADURL=http://<your-host>:29000
MINIO_SERVER_URL=http://<your-host>:29000
```

…and open TCP `29000` in your firewall in addition to `28080`. There
is no architectural reason to do this on a single-host deployment;
the single-port default is the recommended path.

### Advanced: direct WuKongIM transports

The OOTB stack keeps WuKongIM's TCP (`25100`) and WebSocket (`25200`)
ports bound to `127.0.0.1`. Browser / SPA chat traffic reaches
WuKongIM through nginx's `/ws` location on `OCTO_HTTP_PORT` (`28080`)
— that single open port covers the default user experience.

A **native IM client** (mobile or desktop app that speaks WuKongIM's
own framing instead of the nginx-proxied WebSocket) needs to dial
those transports directly. In that case:

```bash
# in docker/.env
OCTO_WK_TCP_BIND=0.0.0.0   # native TCP transport
OCTO_WK_WS_BIND=0.0.0.0    # raw WebSocket without nginx in the middle
# OCTO_WK_API_BIND=0.0.0.0 # debug / manager surface only — see note in "Network surface" above before opening this on a public IP (no nginx auth gateway in front).
```

Then open the matching host ports on your firewall **in addition to
`28080`**:

```bash
sudo ufw allow 25100/tcp     # WuKongIM native TCP (only if needed)
sudo ufw allow 25200/tcp     # WuKongIM direct WebSocket (only if needed)
```

Pure browser / web deployments do not need this and should keep the
loopback defaults.

### HTTPS form (TLS termination)

`OCTO_HTTPS_PORT` (default `28443`) is the placeholder for the
single-port-plus-TLS form. The cert wiring is NOT automated in this
stack — see [`docker/certs/README.md`](certs/README.md) for the manual
procedure (Let's Encrypt or self-signed). Once certs are in place,
uncomment the 443 port mapping in `docker-compose.yaml`, the certs
volume mount, and the HTTPS server block in
`docker/nginx/conf.d/octo.conf.template`. Same single-port story —
clients only need `OCTO_HTTPS_PORT` open; MinIO traffic still flows
through nginx bucket-name routing under TLS.

> ⚠️ **HTTPS env override required** — the compose defaults for
> `MINIO_SERVER_URL`, `TS_MINIO_DOWNLOADURL`, and `TS_EXTERNAL_BASEURL`
> all expand to `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`. The HTTPS
> server block in nginx terminates TLS, but octo-server still hands
> clients absolute URLs (presigned MinIO PUT/GET, base URLs in admin
> responses) built from these three env vars. If you leave them at the
> defaults, clients receive `http://…:28080` URLs and either get mixed
> content errors or fall back through the HTTP listener. Until
> [YUJ-984](https://github.com/Mininglamp-OSS/octo-deployment/issues) (`OCTO_PUBLIC_SCHEME` auto-derivation) lands, set the three
> values explicitly in `docker/.env`:
>
> ```bash
> # docker/.env — required when HTTPS server block is enabled
> MINIO_SERVER_URL=https://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}
> TS_MINIO_DOWNLOADURL=https://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}
> TS_EXTERNAL_BASEURL=https://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}
> ```
>
> Substitute the literal hostname and port (`.env` does not interpolate
> `${...}` inside values: each value above must be the resolved string,
> e.g. `https://octo.example.com:28443`). All three must agree on
> scheme + host + port — SigV4 signs against this exact URL and
> octo-server validates `TS_MINIO_DOWNLOADURL` as host:port-only on
> startup (no path prefix). Also point `OCTO_WK_WSS_ADDR` at
> `wss://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}/ws` if your clients should
> open the WebSocket over TLS.

### Reverse-proxying behind a host nginx (TLS termination at a different hostname)

When a *host* nginx (different from the in-compose one) terminates TLS
and proxies `https://your.host/` back to the compose stack on
`OCTO_HTTP_PORT`, point both env vars at the public host:

```
MINIO_SERVER_URL=https://your.host
TS_MINIO_DOWNLOADURL=https://your.host
```

Both must use the **same scheme + host:port** (no path prefix —
`TS_MINIO_DOWNLOADURL` is validated host:port-only at octo-server
startup). The bucket-name regex location in the in-compose nginx will
still route `/{bucket}/{key}` to MinIO; just make sure the host nginx
forwards those paths through to the compose stack.

---

## MinIO bootstrap & credential scoping

The stack ships with an `octo-server` MinIO client that is **not** the
MinIO root user. On first start the `minio-init` one-shot service
runs after `minio` becomes healthy and:

1. Creates the IAM user named in `OCTO_MINIO_APP_USER` (default
   `octo-app`) with the password from `OCTO_MINIO_APP_PASSWORD`.
2. (Re)installs the `octo-app` policy from
   [`docker/configs/minio-octo-app-policy.json`](configs/minio-octo-app-policy.json),
   which grants `s3:GetObject`/`PutObject`/`DeleteObject`/multipart
   actions plus `s3:ListBucket` on the bucket whitelist octo-server
   uses (`file`, `chat`, `moment`, `sticker`, `report`, `chatbg`,
   `common`, `download`, `group`, `avatar`). Notably absent:
   `s3:CreateBucket`, `mc admin` rights, console access, IAM control.
3. Attaches the policy to `octo-app`.
4. Pre-creates each whitelisted bucket so the first
   `/api/v1/file/upload` call does not depend on the app user holding
   bucket admin privileges.
5. Sets `anonymous download` on the **content** buckets so the SPA can
   render `<img src=…>` directly (uploads still use signed PUTs):

   > ⚠️ **Security trade-off**: the content buckets below become
   > **anonymously readable by URL**. This matches OCTO web's
   > `<img src>` model (the SPA embeds the unsigned `downloadUrl`
   > returned by `getUploadCredentials` directly — CDN-style, like
   > most IM apps), but it means image URLs are world-readable
   > forever once issued. `s3:ListBucket` stays denied and object
   > keys are high-entropy UUIDs (no enumeration), but anyone who
   > sees a chat-image URL can fetch it. Deleting a chat message
   > does not GC the underlying MinIO object. See the PR#22
   > description for the full threat model and the tracking issue
   > for switching to signed GET once octo-web supports it.

   | Bucket    | Anonymous policy | Why |
   |-----------|------------------|-----|
   | `chat`    | `download`       | image / file messages embedded in chat panes |
   | `file`    | `download`       | generic file attachments |
   | `moment`  | `download`       | moments feed media |
   | `sticker` | `download`       | sticker thumbnails |
   | `chatbg`  | `download`       | chat-background images |
   | `common`  | `download`       | shared static assets |
   | `avatar`  | `download`       | user / group avatars |
   | `report`  | *private*        | audit reports — keep signed |
   | `group`   | *private*        | group exports — keep signed |
   | `download`| *private*        | server-staged downloads — keep signed |

   Writes are still gated by the `octo-app` IAM policy; anonymous is
   GET-only. The `mc anonymous set download` calls are idempotent, so
   re-running `docker compose up -d` is safe.

`octo-server` then runs with the app credentials only — root credentials
live exclusively in the `minio-init` job, the `mc` CLI path, and the
console. A leak of `octo-server`'s environment / config-map / log
spillage gives an attacker bucket-level data access at most, not the
ability to add users, change root, or take over the cluster.

To rotate the app password:

```bash
# 1. set new value in docker/.env
sed -i 's/^OCTO_MINIO_APP_PASSWORD=.*/OCTO_MINIO_APP_PASSWORD=<new>/' docker/.env
# 2. re-run the stack — minio-init is idempotent, will reset the secret,
#    octo-server picks it up on its next env render
docker compose up -d
```

To rotate the policy itself, edit
`docker/configs/minio-octo-app-policy.json` and re-run `docker compose
up -d` — `minio-init` calls `mc admin policy update` whenever the
policy already exists.

---

## First-admin bootstrap

`register.off: true` is the OSS default — public registration is
disabled, and there is no SMS verification fallback in this stack. So
the first admin has to be created out-of-band.

The two paths below are the only ones that work against the current
octo-server binary. Earlier drafts of this doc referenced
`OCTO_BOOTSTRAP_ADMIN_*` env vars and an `octo-server admin
hash-password` CLI subcommand — neither exists in the binary today.
Use Option A unless you have a strong reason to prefer Option B.

### Option A · `adminPwd` config-driven bootstrap (recommended)

octo-server has a built-in first-admin hook tied to the `adminPwd`
config key. On startup, if the user row identified by
`account.adminUID` (default `"admin"`) does not yet exist AND
`adminPwd` is non-empty, it inserts a `superAdmin` row with
`username = "superAdmin"`, `role = "superAdmin"`, and
`password = bcrypt(adminPwd)`. The hook is a one-shot per database —
once the row exists, subsequent restarts no-op even if `adminPwd` is
still set, so leaving the value in place is safe.

To use it:

1. Pick a strong password (treat it as a deploy-time secret —
   octo-server hashes it before write, but the plaintext sits in your
   `.env`).
2. Add to `docker/.env`. `TS_ADMINPWD` is wired into the
   `octo-server` service in `docker-compose.yaml` by default — when
   `OCTO_ADMIN_PWD` is non-empty, octo-server seeds the row on first
   start. Leave `OCTO_ADMIN_PWD` empty (or commented) to skip
   auto-bootstrap and create the admin manually via Option B:

   ```bash
   # docker/.env
   OCTO_ADMIN_PWD=<a strong password>
   ```

   ```yaml
   # docker/docker-compose.yaml — octo-server service environment (already present):
   TS_ADMINPWD: ${OCTO_ADMIN_PWD:-}
   ```

   `setup.sh` generates a random `OCTO_ADMIN_PWD` automatically and
   prints it once at the end of the run.
3. `docker compose up -d` (or `docker compose restart octo-server` if
   the stack is already up). On first start with an empty `user`
   table, octo-server seeds the row.
4. Visit `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/admin/` and log in
   with username `superAdmin` and the password from step 1.
5. Rotate the password from the admin UI and remove `OCTO_ADMIN_PWD`
   from `.env`. (The seeded row is the source of truth from this
   point; the `adminPwd` config key is only consulted when the row is
   absent.)

### Option B · Manual SQL seed

Use this when you cannot edit `docker-compose.yaml`, or you want a
non-default username / UID. The schema is in
`octo-server/modules/user/sql/20191106000003_user_legacy01.sql` (the
relevant fields are `uid`, `username`, `name`, `password`, `role`,
`status`).

```bash
# 1. Generate a bcrypt hash on the host (any cost ≥ 10):
HTPASSWD_HASH=$(htpasswd -bnBC 10 "" '<your password>' | tr -d ':\n')
# Or in Python:
#   python3 -c 'import bcrypt; print(bcrypt.hashpw(b"<pw>", bcrypt.gensalt(10)).decode())'

# 2. Insert the row. role MUST be the string 'superAdmin' (or 'admin')
#    — the column is VARCHAR(40), not an integer enum.
docker compose exec mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" octo <<SQL
INSERT INTO \`user\`
  (uid, username, name, password, role, status, created_at, updated_at)
VALUES
  ('admin', 'superAdmin', 'OCTO Admin', '${HTPASSWD_HASH}', 'superAdmin', 1, NOW(), NOW());
SQL
```

Then visit `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/admin/` and log in
with `superAdmin` and the password you hashed.

> The placeholder UID `'admin'` matches `account.adminUID`'s default
> value. If you change `account.adminUID` in `octo-server.yaml`, use
> the same value here so the Option A re-seed hook stays consistent
> with your manual row.

---

## Hardening checklist

Before exposing the stack beyond a developer laptop:

- Rotate every `CHANGE_ME_*` / `CHG_ME*` value in `.env`. The
  placeholder in `OCTO_MASTER_KEY` is intentionally one byte short so
  an unrotated config fails octo-server's length check;
  `MINIO_ROOT_PASSWORD` ships at 7 chars so it trips MinIO's own ≥8-
  char minimum at boot; the `minio-init` one-shot independently aborts
  on any `CHANGE_ME_*` / `CHG_ME*` value (case-insensitive) for either
  MinIO credential pair; the `preflight` one-shot aborts on any
  `CHANGE_ME_*` / `CHG_ME*` casing for `OCTO_NOTIFY_INTERNAL_TOKEN` and
  `OCTO_WUKONGIM_MANAGER_TOKEN`; and `init-extra-dbs.sh` aborts on
  first MySQL volume init when `MYSQL_ROOT_PASSWORD` is still a
  `CHANGE_ME_*` / `CHG_ME*` placeholder, when any service-account
  password contains characters outside `[A-Za-z0-9._-]`, or when the
  three MySQL service-account passwords (`OCTO_MATTER_DB_PASSWORD`,
  `OCTO_SUMMARY_DB_PASSWORD`, `OCTO_SUMMARY_READER_PASSWORD`) are
  still at their literal-string defaults. There is no longer a path
  for the OOTB stack to come up with placeholder credentials in
  place.
- Keep `OCTO_MYSQL_BIND` / `OCTO_REDIS_BIND` / `OCTO_MINIO_API_BIND`
  / `OCTO_MINIO_CONSOLE_BIND` at `127.0.0.1`. Only widen after rotating
  credentials and placing the host behind a firewall.
- Redis runs **without authentication** in this stack — there is no
  `--requirepass` on the `redis` service `command:`. Flipping
  `OCTO_REDIS_BIND` to `0.0.0.0` therefore exposes an unauthenticated
  Redis to any host that can reach the port. Before widening the
  bind, EITHER keep Redis on a private interface only, OR add
  `--requirepass <secret>` to the `redis` service `command:` in
  `docker-compose.yaml` AND wire the same secret into `TS_DB_REDISPASS`
  / `DM_REDIS_PASS` on the `octo-server` service so the application
  side keeps reaching cache. (Adding a CLI-flag-driven Redis password
  is tracked as a follow-up; see the PR description for the link.)
- The MinIO console is loopback-only and **not** proxied through
  nginx by default. Reach it via SSH-forward to `:29001` (see
  "Network surface"). If you ever uncomment the `/minio-console/`
  block in `nginx/conf.d/octo.conf.template`, treat
  `MINIO_ROOT_PASSWORD` rotation as a precondition — the public
  `OCTO_HTTP_PORT` then becomes a path to `mc admin`.
- `OCTO_MINIO_API_BIND` is `127.0.0.1` in the single-port default —
  client object traffic goes through nginx bucket-name routing. Only
  widen if you have explicitly opted in to the dual-port advanced
  override (see Network surface · Dual-port).
- Narrow `OCTO_NETWORK_SUBNET` further (already defaults to `/24`) if
  it overlaps an existing VPN / VPC range.
- `OCTO_MASTER_KEY` rotation gotcha: the master key is what
  octo-server uses to AEAD-encrypt at-rest fields (the encrypted
  per-user / per-tenant material referenced in the server config).
  Rotating it after data has been written makes the previously
  encrypted rows undecryptable — there is no built-in re-encrypt
  pass. So the rotation flow is: pick a strong key at first deploy
  (`openssl rand -hex 16`), keep it, and only swap it as part of a
  full reset (drop the encrypted columns / re-onboard users) or a
  coordinated migration. This applies only to `OCTO_MASTER_KEY`;
  `OCTO_NOTIFY_INTERNAL_TOKEN` and `OCTO_WUKONGIM_MANAGER_TOKEN` are
  HMAC-only and safe to rotate by restarting all dependent services
  with the new value.
- Set a real `OCTO_WUKONGIM_MANAGER_TOKEN`. WuKongIM's `tokenAuthOn`
  is `true` in `wk.yaml`, but the token is bound from the env var
  `WK_MANAGERTOKEN` (Viper auto-binds upper-case `WK_<KEY>` to the
  YAML key). When that env var is empty, BOTH WuKongIM and
  octo-server short-circuit token comparison and accept any string,
  so the manager API stays reachable AND USABLE without auth — the
  opposite of the safe-by-default behaviour the wording on this line
  used to imply. The wukongim image is pinned to a specific release
  (`v2.2.4-20260313`) precisely so the env-var contract is stable;
  if you bump `OCTO_WK_IMAGE`, re-validate that
  `WK_MANAGERTOKEN` still binds and that `tokenAuthOn: true` is not
  rejected at startup on the new tag.
- Set `OCTO_WEBHOOK_SECRET_KEY` if you accept inbound webhooks.
- Switch `OCTO_DOMAIN` to a real hostname and front the stack with TLS
  (uncomment the `443` block in `docker-compose.yaml` and the HTTPS
  server block in `nginx/conf.d/octo.conf.template`).
- Pin every `mininglamposs/octo-*` image to a specific tag once the
  PresignedPutter fix in `Mininglamp-OSS/octo-server#24` ships a
  release. The compose file currently defaults to `:latest` for
  `octo-server`, `octo-web`, `octo-admin`, `octo-matter`, and the
  smart-summary images — fine for a laptop, not fine for a stable
  deployment. WuKongIM and `mc` are already pinned.

---

## Troubleshooting

### `docker compose up` complains about port collisions

Pick different host ports in `.env` — every backing-service port
(`OCTO_MYSQL_PORT`, `OCTO_REDIS_PORT`, `OCTO_MINIO_API_PORT`, …) and
every public-facing port (`OCTO_HTTP_PORT`, `OCTO_SERVER_PORT`,
`OCTO_ADMIN_PORT`, `OCTO_WEB_PORT`, `OCTO_MATTER_PORT`,
`OCTO_SUMMARY_API_PORT`, `OCTO_WK_*_PORT`) is overridable.

### nginx serves the default Welcome page instead of OCTO

`docker/nginx/empty-default.conf` is mounted on top of the image's
`default.conf` so the OCTO vhost wins. If you have customised the
nginx mount, make sure that override is preserved.

### After recreating `octo-server` or `wukongim`, nginx returns 502 until reload

The four core upstreams that ship with the stack
(`octo_api`, `octo_ws`, `octo_minio_api` → `octo-server` /
`wukongim`) intentionally keep their `upstream {}` blocks so the
nginx keepalive pools stay intact for steady-state traffic. The
trade-off is that nginx resolves those hostnames once at worker
boot and caches the IP for the life of the worker — so a targeted
`docker compose up -d --force-recreate octo-server` or
`--force-recreate wukongim` (image bump, config edit, IM-server
version pin, etc.) leaves nginx routing to the dead IP until the
worker is bounced.

The leaf upstreams (`admin`, `web`, `matter`, `summary-api`) use
the variable + Docker DNS resolver pattern and recover on their
own. For the four core upstreams, after recreating
`octo-server` or `wukongim` run:

```bash
docker compose exec nginx nginx -s reload
```

Reload is online (no dropped connections) and takes <1s. This is
not needed when the *full* stack is restarted via
`docker compose up -d` without `--force-recreate` on a specific
service, because nginx itself is recreated alongside the dependency
and re-resolves at boot.

### Image upload returns 500 / "PresignedPutter is nil"

The OCTO image upload pipeline depends on the PresignedPutter
implementation tracked in
[`Mininglamp-OSS/octo-server#24`](https://github.com/Mininglamp-OSS/octo-server/issues/24).
Pin `OCTO_SERVER_IMAGE` to a tag built from a commit that includes
that fix (or `:latest` once it ships).

### Presigned URL access fails with "connection refused" / "name resolution"

Symptom: image / file upload returns 200 from `/api/v1/file/*`, but
the browser then hangs or 0-bytes when fetching the presigned URL,
**or** the chat UI shows an `[image]` chip but the receiver sees an
empty bubble.

In the single-port form (default), presigned URLs point at the nginx
vhost (`${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`) and the bucket-name regex
location forwards the request to MinIO. Check, in order:

1. `OCTO_HTTP_PORT` (default `28080`) is reachable from the client
   network — `curl -v http://${OCTO_DOMAIN}:28080/_nginx_up` should
   return `200`.
2. `${OCTO_DOMAIN}` resolves on the client (the `/etc/hosts` entry
   for `octo.local` has to exist on every machine that hits the UI,
   not just the host).
3. `TS_MINIO_DOWNLOADURL` and `MINIO_SERVER_URL` agree — both should
   default to `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}` (no path
   prefix). Verify with `docker compose config | grep -E
   '(TS_MINIO_DOWNLOADURL|MINIO_SERVER_URL)'`. octo-server rejects
   path-prefixed download URLs at startup.
4. The bucket-name regex location is present in
   `docker/nginx/conf.d/octo.conf.template`:
   `^/(file|chat|moment|sticker|report|chatbg|common|download|group|avatar)/.+`.
   If you have customised the nginx config, make sure that block is
   preserved.

If you have explicitly opted in to the legacy dual-port form
(`OCTO_MINIO_API_BIND=0.0.0.0` + `TS_MINIO_DOWNLOADURL=...:29000`),
also confirm TCP `29000` is open to the client network. The
single-port form does NOT need port `29000` open.

Do **not** "fix" this by adding an nginx rewrite that strips
`/{bucket}/` from the URI — SigV4 signatures break under any path
rewrite. See "Why single-port works for MinIO presigned URLs" above.

### `WuKongIM /route` returns the literal string `${OCTO_DOMAIN}`

Compose only interpolates `.env` values once — it does **not**
recursively expand `${...}` inside a `.env` value. Leave
`OCTO_WK_WS_ADDR=` empty so the default expression in
`docker-compose.yaml` builds the address from `OCTO_DOMAIN` /
`OCTO_HTTP_PORT`. Set a literal value (e.g. `ws://1.2.3.4:28080/ws`)
only when you want to override the auto-built default.

### SPA route names that collide with MinIO bucket names

The single-port reverse proxy routes any URL matching
`^/(file|chat|moment|sticker|report|chatbg|common|download|group|avatar)/.+`
to MinIO without rewriting the path (presigned URLs depend on the URI
being byte-identical to what SigV4 signed). If you fork `octo-web` and
add a frontend route that happens to land under one of these prefixes
**and** the route's first path segment looks like a MinIO object key
(`/chat/some-key`, `/group/some-id`, …), nginx will dispatch it to
MinIO and the browser will see MinIO's XML `NoSuchKey` error instead of
the SPA.

Mitigations:

- **Prefer SPA prefixes that are NOT in the bucket whitelist** —
  `/conversations/`, `/teams/`, `/spaces/` are all collision-free.
- **If you must keep a colliding prefix**, ensure the SPA segments
  after it cannot be confused with object keys (e.g. namespace them
  under `/chat/_app/<id>` so the regex still matches but the key is
  guaranteed to be a 404 you can detect and bounce back to the SPA).
- **Or**: tighten the bucket-name regex in
  `docker/nginx/conf.d/octo.conf.template` to require the object-key
  shape octo-server emits (currently `<bucket>/<unix-timestamp>/<uuid>/<uuid>.<ext>`
  or `<bucket>/<sanitised-path>` for the upload-path form). The default
  regex was deliberately kept permissive because the upload-path form
  has no fixed prefix; narrowing it requires auditing every call site
  of `getUploadCredentials` in `octo-server` first.

The OOTB SPA shipped in this repo does not collide with any of these
prefixes, so the default regex is safe out of the box.

### MySQL refuses to start with "ERROR 1396 (HY000): Operation CREATE USER failed"

`scripts/init-extra-dbs.sh` runs only on first volume init. If you've
already booted with the wrong passwords, the simplest fix is:

```bash
docker compose down -v        # drops mysql-data
# fix passwords in .env
docker compose up -d
```

If you cannot drop the volume, run the SQL by hand against the live
container — the script's `CREATE USER` / `GRANT` statements are at the
bottom of `scripts/init-extra-dbs.sh`.

### Health endpoints

After the stack reports healthy, these should all return 200 for the
default (no-summary) deployment:

| Path | Purpose |
| --- | --- |
| `/_nginx_up` | nginx reverse-proxy probe |
| `/api/v1/health` | octo-server REST |
| `/matter/health` | octo-matter |
| `/` | octo-web SPA |

```bash
for p in /_nginx_up /api/v1/health /matter/health /; do
  printf '%-22s %s\n' "$p" "$(curl -fsS -o /dev/null -w '%{http_code}' "http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}$p")"
done
```

If the summary profile is enabled (`./setup.sh --summary`, or
`COMPOSE_PROFILES=summary` in `.env`), also probe `/summary/health`:

```bash
curl -fsS "http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/summary/health"
```

Without the summary profile the `summary-api` container is not
started, so `/summary/health` will 502 through nginx — that is
expected, not a failure.

The `summary-worker` container has no public route — it serves
`/internal/healthz` on port `8082` inside the `octo-net` network only.
The route covered by the docker healthcheck above is not reachable from
the host. To verify the worker explicitly (covers `LLM_API_KEY` /
`MYSQL_DSN` validation, which would otherwise show up only as a stuck
`(starting)` state):

```bash
docker compose exec summary-worker \
  wget -qO- http://localhost:8082/internal/healthz
docker compose ps summary-worker   # expect (healthy)
```

If the container is stuck `(unhealthy)` / restarting, inspect
`docker compose logs summary-worker | tail -50` for `required environment
variables not set` — the most common OOTB cause is an empty
`LLM_API_KEY` paired with an `OCTO_SUMMARY_WORKER_IMAGE` pin that
predates the placeholder fallback in `docker-compose.yaml`.

---

## Layout

```
docker/
├── docker-compose.yaml       # full service orchestration
├── .env.example              # annotated environment template
├── README.md                 # this file
├── configs/
│   ├── octo-server.yaml      # mounted at /home/configs/tsdd.yaml
│   ├── wk.yaml               # WuKongIM runtime config
│   └── minio-octo-app-policy.json  # IAM policy installed by minio-init
├── nginx/
│   ├── nginx.conf            # gzip + main http block
│   ├── empty-default.conf    # silences the stock nginx welcome vhost
│   └── conf.d/
│       └── octo.conf.template
└── scripts/
    └── init-extra-dbs.sh     # one-shot MySQL bootstrap (matter / summary)
```

## Out-of-scope

The compose file does NOT cover: clustering / HA, automated TLS
provisioning, log shipping, or backup. Use the kustomize overlays for
production-shaped deployments.
