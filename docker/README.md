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
sudo ./setup.sh --up                        # provision stack
sudo ./setup.sh --smoke-test                # smoke test (admin login + presign PUT). Alias: --verify (deprecated).

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
sudo ./setup.sh --up                        # provision stack
sudo ./setup.sh --smoke-test                # admin login + presign PUT end-to-end (alias: --verify, deprecated)
```

`setup.sh` auto-detects the public IP via `ifconfig.me`. If you run
on a host that has one (cloud VM, bare-metal with public IPv4), the
prompt prints the detected IP for reference but **defaults to
`localhost`** (Enter → local-only on this host). Type the detected
IP, or a real DNS name your clients can resolve, only when you want
the stack reachable from outside this host.

Or non-interactive:

```bash
./setup.sh --non-interactive --domain octo.example.com --ip 1.2.3.4
sudo ./setup.sh --up
sudo ./setup.sh --smoke-test
```

Or, on a fresh host where you want the same three steps without
prompts, do step 1 non-interactively and chain into the start-only
`--up` (R6 / GH#33, R8 / GH#43). `--up` brings the stack up itself,
blocking until every long-running service reports `(healthy)` and
every one-shot init job (`preflight`, `minio-init`) exits 0. On
timeout or startup failure it prints `compose ps`, lists the
specific failing service names, and emits a `logs <svc>` hint for
each before exiting 1. `--up` never rewrites/regenerates the secrets
in the `.env` step 1 wrote (it only `chown root:root` + `chmod 600`
that file for ownership hardening) — it is a start-only subcommand
and, if `docker/.env` is missing, exits 1 with a concrete remediation
pointer instead of silently regenerating secrets:

```bash
./setup.sh --non-interactive --ip 1.2.3.4         # step 1: gen .env, no prompts (no sudo)
sudo ./setup.sh --up                              # step 2: start the stack (start-only)
sudo ./setup.sh --smoke-test                      # step 3: end-to-end verify
```

If you really want to bootstrap + start in a single command (this
WILL generate fresh secrets — never use on a host whose `.env` is
already in production), pass `--up --force` explicitly:

```bash
sudo ./setup.sh --non-interactive --ip 1.2.3.4 --up --force   # explicit one-shot bootstrap
```

Without `--force`, a missing `docker/.env` is a fatal error — that
is the R8 (PR#36 Jerry-Xin CR) fix: "--up never regenerates secrets"
is now enforced by code, not just promised by docs.

`--up` uses `docker compose up -d --wait --wait-timeout 240` under
the hood (with a manual health-poll fallback on Compose < v2.20). The
wrapper retries once on a soft timeout (warm caches make the second
attempt typically <10s), so worst-case wall-clock is 2 × 240s. It
prints a `.` every 5 seconds while waiting so the run is visibly
alive on slow hosts (cold MySQL init can take 60-90s).

To enable the optional LLM summary services, add `--summary`:

```bash
./setup.sh --summary --domain octo.example.com --ip 1.2.3.4
sudo ./setup.sh --up
```

`setup.sh` writes `docker/.env` with rotated random secrets and a
generated `OCTO_ADMIN_PWD`, then **prints the admin URL + password at
the end of the run** so you do not have to grep `.env` for them. It is
the only path that gets a fresh checkout to a `(healthy)` stack
without manual editing.

Once healthy, the stack is reachable through nginx on
`http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}` (default `http://localhost:28080`).
With the default `localhost` no extra DNS / `/etc/hosts` configuration
is required on the host running the stack. If you set
`OCTO_DOMAIN=<a real hostname>`, make sure that name resolves on every
machine that hits the UI (either through real DNS or via an
`/etc/hosts` entry pointing at this host's IP).

### `setup.sh --smoke-test` smoke test

After `sudo ./setup.sh --up` reports all services healthy, run the
smoke test to confirm the *external* surface actually works:

```bash
sudo ./setup.sh --smoke-test
```

> **Why sudo?** `docker/.env` was generated by step 1 (`./setup.sh`).
> If step 1 ran without sudo, the file is owned by you (mode 600). If
> step 1 ran with sudo, it is owned by root. Either way, step 2
> (`sudo ./setup.sh --up`) needs sudo for the Docker daemon socket,
> and after step 2 the file ends up owned by root. Both `--up` (a
> start-only subcommand — it never regenerates secrets) and
> `--smoke-test` require sudo because the file contains every
> high-value secret on the stack — `MYSQL_ROOT_PASSWORD`,
> `MINIO_ROOT_PASSWORD`, `OCTO_MASTER_KEY`, `OCTO_ADMIN_PWD`,
> `OCTO_NOTIFY_INTERNAL_TOKEN`, `OCTO_WUKONGIM_MANAGER_TOKEN` — plus
> Compose control inputs like `COMPOSE_PROJECT_NAME` that the next
> privileged `docker compose` run will consume verbatim. Earlier
> revisions chmod'd / chown'd the file to widen access for a
> sudo-less `--smoke-test`; that widened *write* authority on
> authoritative deployment config, so R5 reverted to the simplest
> shape: ".env stays root:600 (default). Both `--up` and
> `--smoke-test` require sudo because the file contains MySQL/MinIO/
> admin credentials and Compose control inputs." If you forget sudo,
> `env_get()` surfaces a clear remediation (`Re-run as: sudo
> ./setup.sh --smoke-test`) instead of the previous nine cryptic
> probe FAILs.

> **Naming note** — the original spelling was `--verify`. It is
> retained as a deprecated alias (prints a one-line yellow notice and
> runs identically) for at least 2 releases and is scheduled for
> removal in v2.0+. New automation should prefer `--smoke-test`.
>
> **Why not "dry-run"?** This command is **not** read-only. It
> performs 1 POST (admin login), 1 GET (presign issuance), and 1 PUT
> (1-byte sentinel object that lands in the MinIO `common` bucket as
> `octo-verify-<timestamp>-<pid>.txt`, because the probe requests
> credentials for `type=common`). It exercises real auth + real
> storage; calling it a "verify" or "dry-run" understated the
> side-effects.

Output is grouped into two failure-domain banners so a FAIL tells you
immediately which layer to investigate:

- `[infra] container + nginx routing (step 1-7)` — container health,
  nginx vhost, octo-server REST, matter, MinIO health, admin SPA,
  web SPA. A FAIL here is a **platform** problem: a container is
  down, nginx isn't reverse-proxying, or a host port is firewalled.
  Look at `docker compose ps` / `docker compose logs` first.
- `[user-path] auth + WS + presigned PUT (step 8-11)` — WuKongIM `/ws`,
  admin login, presign issuance, signed PUT. A FAIL here is a
  **contract** problem: the platform is up but auth is wired wrong,
  MinIO IAM creds desynced, or SigV4 signing mismatches. Look at
  octo-server + MinIO together, not at nginx.

The 11 probes (PASS/FAIL printed for each):

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
prerequisite** of `--smoke-test` — step 8 (WuKongIM `/ws` upgrade probe)
opens a raw socket from python3, and steps 9-11 (admin login, presign
issuance, SigV4 PUT) parse JSON via `python3 -c 'import json'`.
Silently skipping the JSON-parse steps was the gap that hid
OOTB-BUG-2026-05-17-001. Missing `python3` now fails fast with a
non-zero exit; install it (every modern Linux distro ships it in the
base image) and re-run. This is what to run on a new host to confirm
"deployment actually works end-to-end" — separate from "containers
booted".

Step 11 leaves a 1-byte sentinel object in the `common` bucket
(`octo-verify-<timestamp>-<pid>.txt`). The bucket is determined by the
`type=common` query argument that step 10 passes to
`GET /api/v1/file/upload/credentials` — octo-server's MinIO backend
maps a request `type=` to the first path segment, then
`splitBucketAndObject` (octo-server `modules/file/helpers.go`) routes
it to the matching bucket from the allow-list (`file`, `chat`,
`moment`, `sticker`, `report`, `chatbg`, `common`, `download`,
`group`, `avatar`). `type=common` therefore lands in `common`. The
sentinel is intentionally left in place — the bundled `minio/minio`
image does NOT ship the `mc` client (`mc` lives in the separate
`minio/mc` image, which is only used by the one-shot `minio-init`
container), so the obvious `docker exec <project>-minio-1 mc rm ...`
command would always fail. A single byte per `--smoke-test` run is
well below noise; if you absolutely need a clean bucket, run `mc`
from its own image against the bucket via the project's docker
network, or hit MinIO's S3 DELETE API with the admin credentials in
`docker/.env`.

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
> OCTO_WK_WSS_ADDR=wss://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}/ws
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

## Production HTTPS deployment

The OOTB stack ships HTTP-only on `OCTO_HTTP_PORT` (default `28080`).
For production we recommend terminating TLS at a **reverse proxy in
front of** the compose stack rather than baking certbot into the
container set. This keeps cert lifecycle in the reverse-proxy layer
(where it belongs — see "Why we don't bundle certbot" below) and lets
you reuse whatever Let's Encrypt / Cloudflare / internal-CA workflow
your fleet already uses.

Three battle-tested paths follow. They are independent — pick the one
that matches your environment, you only need one.

In all three paths the upstream is the in-compose nginx on
`http://<host>:28080`. Restrict the in-compose nginx to the loopback
interface (see [Firewall rules for HTTPS](#firewall-rules-for-https)
below) so port `28080` is not directly reachable from the internet —
the reverse proxy is the only public listener.

> 💡 **HTTPS env override required for all three paths.** Once TLS
> terminates at the reverse proxy, octo-server still hands clients
> absolute URLs (presigned MinIO PUT/GET, admin baseURL, WS address).
> Set the following in `docker/.env` with the resolved literal
> hostname (`.env` does not interpolate `${...}` inside values):
>
> ```bash
> # docker/.env — required when fronted by a reverse proxy
> MINIO_SERVER_URL=https://octo.example.com
> TS_MINIO_DOWNLOADURL=https://octo.example.com
> TS_EXTERNAL_BASEURL=https://octo.example.com
> OCTO_WK_WSS_ADDR=wss://octo.example.com/ws       # browser WSS via reverse proxy (maps to WK_EXTERNAL_WSSADDR)
> ```
>
> All three URL values must share scheme + host + port — SigV4 signs
> against this exact URL and octo-server validates
> `TS_MINIO_DOWNLOADURL` as host:port-only at startup (no path
> prefix). See [HTTPS form (TLS termination)](#https-form-tls-termination)
> in the Network surface section above for the underlying rationale.

### Path A — Cloudflare Tunnel (recommended for "I just need HTTPS, fast")

Zero DNS edits, zero firewall ports open inbound, automatic HTTPS,
free DDoS + CDN. The only prerequisite is a domain on Cloudflare
(free plan is sufficient).

```bash
# 1. Install cloudflared (Debian/Ubuntu).
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb

# 2. Auth — opens a browser to pick the Cloudflare zone.
cloudflared tunnel login

# 3. Create the tunnel (records the UUID + credentials JSON under ~/.cloudflared/).
cloudflared tunnel create octo

# 4. Route DNS — Cloudflare auto-creates the CNAME for you.
cloudflared tunnel route dns octo octo.example.com

# 5. Write /etc/cloudflared/config.yml (substitute the UUID from step 3 —
#    `cloudflared tunnel list` prints it). Also copy the per-tunnel credentials
#    JSON from your user ~/.cloudflared/ into a service-owned path so the
#    root-owned systemd unit can read it (otherwise the service fails to start
#    because /root/.cloudflared/<uuid>.json does not exist).
sudo install -d -m 0755 /etc/cloudflared
sudo cp ~/.cloudflared/*.json /etc/cloudflared/
sudo tee /etc/cloudflared/config.yml >/dev/null <<'YML'
tunnel: <TUNNEL-UUID>
credentials-file: /etc/cloudflared/<TUNNEL-UUID>.json

ingress:
  - hostname: octo.example.com
    service: http://localhost:28080
    originRequest:
      connectTimeout: 30s
  - service: http_status:404
YML

# 6. Validate the config syntactically (no live Cloudflare call).
#    cloudflared auto-loads /etc/cloudflared/config.yml when --config is omitted.
sudo cloudflared --config /etc/cloudflared/config.yml tunnel ingress validate

# 7. Install as systemd service and start.
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Cloudflare's tunnel terminates TLS at the edge and proxies
`https://octo.example.com/*` (including `/ws` WebSocket upgrade and
`/{bucket}/{key}` MinIO presign PUT/GET) over a single outbound mTLS
tunnel to your host — **no inbound ports need to be open** on the host
firewall. The in-compose nginx still does the bucket-name routing for
presigned URLs because Cloudflare forwards the path verbatim (no
rewrite, no signature break).

**Body size note**: Cloudflare's Free plan caps request bodies at
100 MB; Pro raises it to 200 MB; Business to 500 MB. For OOTB chat
image / file messages 100 MB is plenty. If you need more, configure
it via Cloudflare dashboard (Rules → Configuration Rules → "Upload
size limit") or upgrade the plan.

**WebSocket note**: `cloudflared` forwards `Upgrade` / `Connection`
headers automatically — `/ws` and any `/api/*` long-poll fallback
just work, nothing to configure.

### Path B — host nginx + certbot (most common self-hosted form)

The classic "I already run nginx on this host" path. certbot's
`--nginx` plugin handles cert issuance AND automatic renewal AND
nginx reload, so once it's set up the cert lifecycle is hands-off.

```bash
# 1. Install nginx + certbot.
sudo apt-get update
sudo apt-get install -y nginx python3-certbot-nginx

# 2. Make sure the WebSocket-upgrade map is defined at http{} scope.
#    Debian/Ubuntu's default /etc/nginx/nginx.conf already includes
#    /etc/nginx/conf.d/*.conf inside http{}, so drop a small file there:
sudo tee /etc/nginx/conf.d/connection_upgrade.conf >/dev/null <<'NGINX'
# Required for proxy_set_header Connection $connection_upgrade.
# Maps the incoming Upgrade header to a per-request Connection value:
#   "upgrade" for WS handshakes, "close" for everything else.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINX

# 3. Drop the OCTO vhost.
sudo tee /etc/nginx/sites-available/octo.conf >/dev/null <<'NGINX'
upstream octo_backend {
    server 127.0.0.1:28080;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name octo.example.com;

    # certbot --nginx will rewrite this to a 301 redirect to https://
    # AFTER adding the 443 server block. ACME HTTP-01 + the redirect
    # both need port 80 reachable.
    location / {
        proxy_pass http://octo_backend;
        proxy_http_version 1.1;

        # Forward client identity to the in-compose nginx and the app.
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;

        # WebSocket upgrade — required for /ws AND /api long-poll fallback.
        # WITHOUT this pair, the WS handshake silently degrades to 200 and
        # the chat client never connects.
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;

        # MinIO presign PUT — chat-image / file-attachment uploads can be
        # 10-100 MB. The cap that hits first in this topology is the HOST
        # nginx; the in-compose nginx is already permissive enough.
        client_max_body_size               100M;

        # Long-lived chat WebSocket. OOTB chat sessions hold the socket
        # open for hours; the default 60s read_timeout drops it early.
        proxy_read_timeout                 3600s;
        proxy_send_timeout                 3600s;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/octo.conf /etc/nginx/sites-enabled/octo.conf

# 4. Validate the vhost syntax BEFORE asking certbot to touch it.
sudo nginx -t

# 5. Issue + install cert + add 443 block + set up auto-renew, in one shot.
sudo certbot --nginx -d octo.example.com \
  --non-interactive --agree-tos -m admin@example.com --redirect

# 6. Verify the renewal timer is armed (Debian/Ubuntu ship it pre-enabled).
sudo systemctl status certbot.timer
sudo certbot renew --dry-run
```

`certbot --nginx` adds the `listen 443 ssl` block, points it at the
LE cert in `/etc/letsencrypt/live/octo.example.com/`, sets
`return 301 https://...` on the port-80 block, and installs the
`certbot.timer` that renews ~30 days before expiry. Operator action
after that is limited to keeping `nginx` and `certbot` packages
patched.

**WebSocket note**: the `proxy_set_header Upgrade` /
`proxy_set_header Connection` pair plus the `map $http_upgrade
$connection_upgrade` block is the standard nginx WebSocket recipe.
`$http_upgrade` is empty on a normal REST request and equals
`websocket` on a WS upgrade; the `map` translates that into the
matching `Connection` value (`""` for REST, `upgrade` for WS). The
trap to avoid is hardcoding `proxy_set_header Connection "upgrade"`
on every request — that forces `Connection: upgrade` on non-WS
requests too and breaks HTTP/1.1 keepalive on REST. Always drive
`Connection` from the `map`, never a literal `"upgrade"`.

**Body size note**: `client_max_body_size 100M` covers MinIO presign
PUT for chat / file messages. Bump higher if your users upload bigger
files — the in-compose nginx will not be the bottleneck.

### Path C — Caddy (single binary, fewest moving parts)

Caddy auto-issues + auto-renews Let's Encrypt certs from a tiny
Caddyfile. No certbot, no timer, no separate vhost-enable dance.

```bash
# 1. Install Caddy (Debian/Ubuntu — official signed package repo).
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update
sudo apt-get install -y caddy

# 2. Write the Caddyfile.
sudo tee /etc/caddy/Caddyfile >/dev/null <<'CADDY'
octo.example.com {
    # Caddy auto-provisions the LE cert on first request and auto-renews
    # ~30 days before expiry. WebSocket upgrade is automatic — the
    # reverse_proxy directive already forwards Upgrade / Connection.
    reverse_proxy 127.0.0.1:28080 {
        # Caddy's reverse_proxy auto-sets Host + X-Forwarded-For /
        # -Proto / -Host. The only header worth adding explicitly is
        # X-Real-IP, which Caddy does NOT set by default but the
        # in-compose nginx + octo-server access logs read.
        header_up X-Real-IP {remote_host}

        # Long-lived chat WebSocket. OOTB chat sessions hold the socket
        # open for hours; bump timeouts above the default 30s/2m.
        transport http {
            read_timeout  1h
            write_timeout 1h
        }
    }

    # MinIO presign PUT — chat-image / file-attachment uploads.
    # Caddy's default request body cap is 10 MiB at the HTTP layer; raise
    # it to match the host nginx / Cloudflare paths above.
    request_body {
        max_size 100MB
    }
}
CADDY

# 3. Validate the config.
sudo caddy validate --config /etc/caddy/Caddyfile

# 4. Reload (Caddy hot-reloads — no dropped connections).
sudo systemctl reload caddy
```

What Caddy does for you, in one binary:

- Obtains the LE cert on the first inbound request (HTTP-01 via :80,
  TLS-ALPN-01 via :443; both ports must be reachable from the
  internet during issuance).
- Auto-renews at ~30 days before expiry. No timer, no cron entry.
- Speaks HTTP/2 and HTTP/3 by default.
- Forwards `Upgrade` / `Connection` headers automatically — no `map`
  block dance like nginx.

**Body size note**: Caddy's HTTP layer default body cap is 10 MiB,
which is below MinIO presign PUT for any image larger than a small
thumbnail. The `request_body { max_size 100MB }` line raises it to
match the other two paths.

### Why we don't bundle certbot in this repo

Two reasons, in this order:

1. **Cert lifecycle belongs in the reverse-proxy layer, not the app
   layer.** Operators with existing fleets already terminate TLS at a
   front door (host nginx, Caddy, Cloudflare, Traefik, a cloud LB).
   Bundling a certbot container in this stack would either (a) fight
   that front door for port 80 / 443, or (b) require a
   `--standalone-with-cert-forward` dance that is strictly more
   fragile than just pointing the existing front door at `:28080`. The
   OOTB sweet spot is "give you a working HTTP stack on `:28080`; you
   front it with your own TLS."
2. **Fully automated DNS-01 needs DNS provider write credentials**,
   and there is no portable way to ship that. Cloudflare API token vs
   Route53 key vs Aliyun AccessKey vs internal DNS — each is a
   different out-of-band setup. We do not want a setup script that
   asks for write credentials to your zone.

If you have a strong reason to terminate TLS inside the compose stack
itself (air-gapped lab where no host-side proxy is available, e.g.),
the HTTPS server block in `nginx/conf.d/octo.conf.template` is still
present and the manual procedure in
[`docker/certs/README.md`](certs/README.md) covers it. The three
reverse-proxy paths above are the recommended form for everything
else.

### Firewall rules for HTTPS

When fronting the stack with a reverse proxy:

| Port | Direction | Who needs to open it | Why |
| ---- | --------- | -------------------- | --- |
| `443/tcp` | inbound | Path B/C reverse-proxy host (Path A: not needed) | client HTTPS |
| `80/tcp`  | inbound | Path B/C reverse-proxy host (Path A: not needed) | LE HTTP-01 ACME challenge + HTTP→HTTPS redirect |
| `28080/tcp` | **loopback only** | in-compose nginx | upstream — bind to `127.0.0.1` via `OCTO_NGINX_BIND` so it is not reachable from the internet |

Path A (Cloudflare Tunnel) needs **no inbound ports at all** — the
tunnel is outbound-only. The reverse-proxy host firewall stays
completely closed inbound.

#### Primary — restrict the in-compose nginx to loopback (the only reliable way)

Edit `docker/.env` and set:

```bash
OCTO_NGINX_BIND=127.0.0.1
```

then restart nginx:

```bash
sudo docker compose up -d nginx
```

This binds port `28080` to the loopback interface only — only your
reverse proxy on the same host can reach it. External clients hitting
`http://<public-IP>:28080/` get connection refused / timeout at the
kernel level, before Docker or any container is involved.

Verify (on the host running compose):

```bash
curl -fsS http://127.0.0.1:28080/_nginx_up   # → "ok" (200)
curl --max-time 5 http://<public-IP>:28080/_nginx_up   # → connection refused / timeout
```

#### Secondary — defence-in-depth, NOT a replacement for OCTO_NGINX_BIND

> ⚠️ **DO NOT rely on `ufw deny 28080/tcp` alone.** Docker publishes
> ports via the iptables `DOCKER` chain, which is evaluated **before**
> ufw's `INPUT` / `ufw-*` chains. External traffic still reaches
> Docker-published ports regardless of ufw rules — `ufw deny 28080`
> looks correct in `ufw status` but does not actually block the port.
> See: https://github.com/docker/for-linux/issues/690
>
> `ufw deny 28080/tcp` can be added as defence-in-depth
> (belt-and-suspenders), but `OCTO_NGINX_BIND=127.0.0.1` is the only
> reliable restriction.

The usual host-firewall rules for Paths B / C (these *do* work — they
control `443` / `80` on the host nginx, which is not Docker-published):

```bash
# Debian/Ubuntu with ufw — Path B / C (the in-compose nginx is already
# restricted via OCTO_NGINX_BIND=127.0.0.1 above; these open the reverse
# proxy's own listeners).
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp     # Path B/C only (Cloudflare Tunnel does not need this)
sudo ufw enable
```

### WebSocket via reverse proxy

OCTO uses WebSocket on `/ws` (WuKongIM browser transport, the chat
data plane). `/api/*` is REST only, but **must** still pass through a
proxy that does NOT downgrade HTTP/1.1 keepalive — long-poll fallback
paths assume the connection stays open. All three reverse-proxy paths
above handle both:

- **Path A** (Cloudflare Tunnel): `cloudflared` auto-forwards
  `Upgrade` / `Connection` headers — `/ws` upgrade works with no
  config, `/api/*` keepalive works with no config.
- **Path B** (host nginx): the
  `proxy_set_header Upgrade $http_upgrade` +
  `proxy_set_header Connection $connection_upgrade` pair PLUS the
  `map $http_upgrade $connection_upgrade` block at http{} scope is
  the standard nginx WebSocket recipe. `$http_upgrade` is empty on
  REST and `websocket` on WS upgrade; the `map` translates that into
  the matching `Connection` value (`""` for REST, `upgrade` for WS).
  The trap is hardcoding `proxy_set_header Connection "upgrade"` —
  that forces `Connection: upgrade` on every request and breaks
  HTTP/1.1 keepalive on REST. The config above ships the `map` in
  `/etc/nginx/conf.d/connection_upgrade.conf` so it loads at http{}
  scope before any vhost.
- **Path C** (Caddy): the `reverse_proxy` directive forwards
  `Upgrade` / `Connection` automatically. No explicit header config
  needed.

If your `/ws` connection establishes (`101 Switching Protocols`) but
drops after ~60s, the culprit is `proxy_read_timeout` (nginx) or
`transport http { read_timeout }` (Caddy) — OOTB chat sessions hold
the socket open for hours, so 3600s is the safe value.

### Internal vs external port mapping

The reverse-proxy setup separates two ports that the OOTB stack
collapses:

| Layer | Listens on | Reachable from |
| ----- | ---------- | -------------- |
| Reverse proxy (host nginx / Caddy / Cloudflare edge) | `:443` (+ `:80` for ACME / redirect) | the internet |
| In-compose nginx (`OCTO_HTTP_PORT`) | `127.0.0.1:28080` (after the firewall / port-bind restriction above) | the host loopback only |
| Backing services (MinIO API, MySQL, Redis, WuKongIM monitor, …) | `127.0.0.1:<port>` (`OCTO_*_BIND` defaults) | the host loopback only |

The reverse proxy is the **only** public listener. Everything else
stays on loopback exactly as documented in
[Backing-service host bindings](#backing-service-host-bindings) and
[Network surface](#network-surface). The OOTB default of binding
`28080` to `0.0.0.0` (`OCTO_NGINX_BIND=0.0.0.0`) is for laptop-only
single-port deployments — set `OCTO_NGINX_BIND=127.0.0.1` in
`docker/.env` and `docker compose up -d nginx` the moment you put a
reverse proxy in front (see [Firewall rules for HTTPS](#firewall-rules-for-https)
above for why a ufw rule alone is not enough).

> 💡 **Why not bind the in-compose nginx directly to `:443`?** Two
> reasons: (1) it forces every TLS knob (cert path, cipher suite,
> HTTP/2 enablement, HSTS) into `nginx/conf.d/octo.conf.template`,
> which is supposed to be a single-tenant app-layer concern; (2) it
> puts the cert private key inside a container whose lifecycle is
> tied to application releases. The reverse-proxy split keeps the
> app layer cert-free and lets the cert lifecycle live where it
> belongs.

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
2. `${OCTO_DOMAIN}` resolves on the client. With the OOTB default
   (`localhost`) this is automatic on the same host the stack is
   running on. If you set OCTO_DOMAIN to a real hostname, that name
   has to resolve on every machine that hits the UI (real DNS or a
   matching `/etc/hosts` entry).
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
