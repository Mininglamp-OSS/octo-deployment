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

---

## Quick start

```bash
git clone https://github.com/Mininglamp-OSS/octo-deployment.git
cd octo-deployment

cp docker/.env.example docker/.env
# Edit docker/.env — at minimum change the placeholders flagged in the file:
#   MYSQL_ROOT_PASSWORD, MINIO_ROOT_PASSWORD, OCTO_MINIO_APP_PASSWORD,
#   OCTO_MATTER_DB_PASSWORD, OCTO_SUMMARY_DB_PASSWORD,
#   OCTO_SUMMARY_READER_PASSWORD,
#   OCTO_MASTER_KEY, OCTO_NOTIFY_INTERNAL_TOKEN, OCTO_WUKONGIM_MANAGER_TOKEN

cd docker
docker compose config            # validate before starting
docker compose up -d
docker compose ps                # all services should reach (healthy)
```

Once healthy, the stack is reachable through nginx on
`http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}` (default `http://octo.local:28080`).
Add an `/etc/hosts` entry for `octo.local` if you keep the default domain.

Tear-down (drops the named volumes too — destructive):

```bash
docker compose down -v
```

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

`OCTO_MYSQL_BIND`, `OCTO_REDIS_BIND`, `OCTO_MINIO_CONSOLE_BIND`
default to `127.0.0.1`. This means MySQL (`23306`), Redis (`26379`)
and the MinIO console (`29001`) are **only reachable from the host
loopback**. The nginx-proxied paths (`/`, `/api/`, `/v1/`, `/admin/`,
`/matter/`, `/summary/`, `/ws`, `/minio/`) remain public — note that
`/minio-console/` is **not** in that list (see "Network surface"
below).

The same loopback default applies to the direct ports for
`octo-server` (`OCTO_SERVER_BIND`), `octo-matter` (`OCTO_MATTER_BIND`),
`smart-summary API` (`OCTO_SUMMARY_API_BIND`), and the WuKongIM
monitor port (`OCTO_WK_MONITOR_BIND`). The first three skip the
`octo_api` / `octo_auth` rate-limit zones the nginx vhost applies to
`/api/`, `/v1/`, `/matter/`, and `/summary/`, so leaving them
loopback-only keeps an operator-debug port from becoming a
rate-limit-free production path. The WuKongIM monitor port is an
admin surface, not a chat transport — chat clients reach WuKongIM via
the user-facing API/TCP/WS ports, which stay on `0.0.0.0`.

`OCTO_MINIO_API_BIND` is the asymmetric case — see "Network surface"
below for the rationale.

Override the loopback defaults only if you have rotated all
credentials and placed the host behind a firewall. **Redis runs
without authentication** in this stack — keep `OCTO_REDIS_BIND` on
`127.0.0.1` (or a private interface) until you wire `--requirepass`
into the redis service. See the "Hardening checklist" for the steps.

---

## Network surface

The stack exposes two distinct sets of host ports. Operators should
know which is which before changing any `OCTO_*_BIND` value.

| Service | Port (default) | Default bind | Why |
| --- | --- | --- | --- |
| nginx (HTTP) | `28080` | `0.0.0.0` | user-facing entrypoint |
| octo-server REST | `28081` | `127.0.0.1` | direct REST port for operator smoke tests; production traffic uses nginx `/api/` + `/v1/` (rate-limited via `octo_api`/`octo_auth` zones in `nginx.conf`). Override `OCTO_SERVER_BIND` to widen. |
| octo-admin | `28082` | `0.0.0.0` | admin SPA (also reachable via `/admin/`) |
| octo-web | `28083` | `0.0.0.0` | user SPA (also reachable via `/`) |
| octo-matter | `28086` | `127.0.0.1` | direct matter port for operator smoke tests; production traffic uses nginx `/matter/`. Override `OCTO_MATTER_BIND` to widen. |
| smart-summary API | `28087` | `127.0.0.1` | direct summary-api port for operator smoke tests; production traffic uses nginx `/summary/`. Override `OCTO_SUMMARY_API_BIND` to widen. |
| WuKongIM API / TCP / WS | `25001` / `25100` / `25200` | `0.0.0.0` | chat client transports |
| WuKongIM monitor | `25300` | `127.0.0.1` | observability / `/route` admin surface — not a user-facing transport. Override `OCTO_WK_MONITOR_BIND` for cross-host operator access. |
| **MinIO API** | **`29000`** | **`0.0.0.0`** | **presigned URLs — see below** |
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

### Why the MinIO API port is public by design

octo-server's `/api/v1/file/*` responses contain **presigned (SigV4)
URLs that point at the MinIO API directly** — not through nginx. SigV4
signs the canonical request path; any nginx rewrite (`/minio/...` ->
`/...`) breaks the signature, so the browser must reach MinIO's `9000`
port over the same hostname octo-server signed against. That is the
value of `TS_MINIO_DOWNLOADURL`, which is fixed to host:port form (no
path prefix) in `docker-compose.yaml`.

The data is protected by:

- the **application-scoped IAM credentials** (`OCTO_MINIO_APP_*`) that
  octo-server signs with — provisioned by the one-shot `minio-init`
  service (see "MinIO bootstrap & credential scoping" below). These
  credentials grant read/write/delete on the bucket whitelist and
  nothing else; they do NOT grant `mc admin` / IAM / console rights,
  and the MinIO root pair never reaches octo-server's environment.
- the **short TTL** of every presigned URL (minutes, not days),
- octo-server's authorisation layer in front of `/api/v1/file/*`.

Closing the port closes valid uploads / downloads. If you want a
firewall-restricted deployment, restrict `29000` to the same client
range that can reach `28080` — do not block it.

If you absolutely need every public port to live behind nginx, you'd
need a SigV4-aware proxy (e.g. one that re-signs each request) — that
is out of scope for this compose stack.

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
2. Add to `docker/.env` and uncomment the matching env line in the
   `octo-server` service in `docker-compose.yaml` (commented out by
   default to keep the OOTB stack from auto-creating an admin in the
   wrong environment):

   ```bash
   # docker/.env
   OCTO_ADMIN_PWD=<a strong password>
   ```

   ```yaml
   # docker/docker-compose.yaml — octo-server service environment:
   TS_ADMINPWD: ${OCTO_ADMIN_PWD:-}
   ```
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
- Keep `OCTO_MYSQL_BIND` / `OCTO_REDIS_BIND` /
  `OCTO_MINIO_CONSOLE_BIND` at `127.0.0.1`. Only widen after rotating
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
- `OCTO_MINIO_API_BIND` stays `0.0.0.0` — see "Network surface · Why
  the MinIO API port is public by design". Restrict the port at the
  firewall layer if you need to limit reach, do not close it.
- Narrow `OCTO_NETWORK_SUBNET` further (already defaults to `/24`) if
  it overlaps an existing VPN / VPC range.
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

### Image upload returns 500 / "PresignedPutter is nil"

The OCTO image upload pipeline depends on the PresignedPutter
implementation tracked in
[`Mininglamp-OSS/octo-server#24`](https://github.com/Mininglamp-OSS/octo-server/issues/24).
Pin `OCTO_SERVER_IMAGE` to a tag built from a commit that includes
that fix (or `:latest` once it ships).

### Presigned URL access fails with "connection refused" / "name resolution"

Symptom: image / file upload returns 200 from `/api/v1/file/*`, but
the browser then hangs or 0-bytes when fetching the presigned URL.

The presigned URL points at `${OCTO_DOMAIN}:${OCTO_MINIO_API_PORT}`
(default `http://octo.local:29000`), bypassing nginx. Check, in
order:

1. `OCTO_MINIO_API_BIND` is `0.0.0.0` (default). If you narrowed it
   to `127.0.0.1`, only the host itself can reach the port — LAN /
   browser clients on other machines will fail.
2. `OCTO_MINIO_API_PORT` (default `29000`) is reachable from the
   client's network — `curl -v http://${OCTO_DOMAIN}:29000/minio/health/live`
   should return `200`.
3. `${OCTO_DOMAIN}` resolves on the client (the `/etc/hosts` entry
   for `octo.local` has to exist on every machine that hits the UI,
   not just the host).
4. `TS_MINIO_DOWNLOADURL` in the rendered config has **no path
   component** — `docker compose config | grep TS_MINIO_DOWNLOADURL`
   should print exactly `http://<host>:<port>`. octo-server PR#50 R4
   rejects path-prefixed values at startup.

Do **not** "fix" this by routing the URL through nginx (`/minio/...`)
— SigV4 signatures break under any path rewrite. See "Network surface
· Why the MinIO API port is public by design" above.

### `WuKongIM /route` returns the literal string `${OCTO_DOMAIN}`

Compose only interpolates `.env` values once — it does **not**
recursively expand `${...}` inside a `.env` value. Leave
`OCTO_WK_WS_ADDR=` empty so the default expression in
`docker-compose.yaml` builds the address from `OCTO_DOMAIN` /
`OCTO_HTTP_PORT`. Set a literal value (e.g. `ws://1.2.3.4:28080/ws`)
only when you want to override the auto-built default.

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

After the stack reports healthy, these should all return 200:

| Path | Purpose |
| --- | --- |
| `/_nginx_up` | nginx reverse-proxy probe |
| `/api/v1/health` | octo-server REST |
| `/matter/health` | octo-matter |
| `/summary/health` | smart-summary API |
| `/` | octo-web SPA |

```bash
for p in /_nginx_up /api/v1/health /matter/health /summary/health /; do
  printf '%-22s %s\n' "$p" "$(curl -fsS -o /dev/null -w '%{http_code}' "http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}$p")"
done
```

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
