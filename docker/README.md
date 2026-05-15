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
#   MYSQL_ROOT_PASSWORD, MINIO_ROOT_PASSWORD, OCTO_MASTER_KEY,
#   OCTO_NOTIFY_INTERNAL_TOKEN, OCTO_WUKONGIM_MANAGER_TOKEN

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
placeholder values that will either fail length checks or trip the
backing-service guards in `init-extra-dbs.sh`.

| Variable | What it is | How to generate |
| --- | --- | --- |
| `MYSQL_ROOT_PASSWORD` | MySQL `root` password (also embedded in `TS_DB_MYSQLADDR` / `DM_MYSQL_DSN`) | `openssl rand -hex 16` |
| `MINIO_ROOT_PASSWORD` | MinIO root credential | `openssl rand -hex 16` |
| `OCTO_MASTER_KEY` | 32-byte server master key | `openssl rand -hex 16` |
| `OCTO_NOTIFY_INTERNAL_TOKEN` | HMAC secret octo-server ↔ matter / smart-summary share | `openssl rand -hex 32` |
| `OCTO_WUKONGIM_MANAGER_TOKEN` | WuKongIM admin token, also used by octo-server | `openssl rand -hex 32` |
| `LLM_API_KEY` | LLM provider key consumed by matter + smart-summary (required for those features; leave blank for a smoke-test stack) | from your provider |

Everything else has sane defaults documented inline in
[`docker/.env.example`](.env.example).

### Backing-service host bindings

`OCTO_MYSQL_BIND`, `OCTO_REDIS_BIND`, `OCTO_MINIO_API_BIND`,
`OCTO_MINIO_CONSOLE_BIND` default to `127.0.0.1`. This means MySQL
(`23306`), Redis (`26379`), and the MinIO API (`29000`) / console
(`29001`) ports are **only reachable from the host loopback**. The
nginx-proxied paths (`/`, `/api/`, `/admin/`, `/matter/`, `/summary/`,
`/ws`, `/minio/`, `/minio-console/`) remain public.

Override only if you have rotated all credentials and placed the host
behind a firewall.

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

- Rotate every `CHANGE_ME_*` value in `.env`. The placeholders in
  `OCTO_MASTER_KEY` are intentionally one byte short so an unrotated
  config fails octo-server's length check.
- Keep `OCTO_*_BIND=127.0.0.1` on backing services. Only widen after
  rotating credentials and placing the host behind a firewall.
- Narrow `OCTO_NETWORK_SUBNET` further (already defaults to `/24`) if
  it overlaps an existing VPN / VPC range.
- Set a real `OCTO_WUKONGIM_MANAGER_TOKEN`. WuKongIM's `tokenAuthOn`
  is true in `wk.yaml`; an empty token means admin endpoints are
  reachable but unusable.
- Set `OCTO_WEBHOOK_SECRET_KEY` if you accept inbound webhooks.
- Switch `OCTO_DOMAIN` to a real hostname and front the stack with TLS
  (uncomment the `443` block in `docker-compose.yaml` and the HTTPS
  server block in `nginx/conf.d/octo.conf.template`).

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

---

## Layout

```
docker/
├── docker-compose.yaml       # full service orchestration
├── .env.example              # annotated environment template
├── README.md                 # this file
├── configs/
│   ├── octo-server.yaml      # mounted at /home/configs/tsdd.yaml
│   └── wk.yaml               # WuKongIM runtime config
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
