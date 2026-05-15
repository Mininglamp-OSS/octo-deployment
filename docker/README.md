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
| `MYSQL_ROOT_PASSWORD` | MySQL `root` password (also embedded in `DM_MYSQL_DSN`) | `openssl rand -hex 16` |
| `MINIO_ROOT_PASSWORD` | MinIO root credential | `openssl rand -hex 16` |
| `OCTO_MASTER_KEY` | 32-byte server master key | `openssl rand -hex 16` |
| `OCTO_NOTIFY_INTERNAL_TOKEN` | HMAC secret octo-server ↔ matter / smart-summary share | `openssl rand -hex 32` |
| `OCTO_WUKONGIM_MANAGER_TOKEN` | WuKongIM admin token, also used by octo-server | `openssl rand -hex 32` |
| `LLM_API_KEY` | LLM provider key consumed by matter + smart-summary | from your provider |

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

Choose **one** of the two paths below.

### Option A · SQL one-liner (manual, recommended for evaluation)

After `docker compose up -d` reaches healthy, exec into the MySQL
container and seed an admin row directly:

```bash
docker compose exec mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" octo <<'SQL'
-- Replace the placeholders before running.
--   - <UID>      : any 11-char string (e.g. shasum -a256 -b username | head -c 11)
--   - <USERNAME> : the login name
--   - <PWHASH>   : bcrypt of the password — run:
--                    docker compose exec octo-server /home/octo-server admin hash-password
--                  (or any bcrypt tool — cost 10 is fine)
INSERT INTO `user`
  (`uid`, `username`, `name`, `password`, `role`, `status`, `created_at`, `updated_at`)
VALUES
  ('<UID>', '<USERNAME>', 'OCTO Admin', '<PWHASH>', 1, 1, NOW(), NOW());
SQL
```

Then visit `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/admin/` and log in.

### Option B · Bootstrap env vars (auto-create on first start)

If your `OCTO_SERVER_IMAGE` is built from a commit that supports the
bootstrap-admin path, you can have octo-server insert the row itself
on first start. Add to `docker/.env`:

```bash
OCTO_BOOTSTRAP_ADMIN_USERNAME=admin
OCTO_BOOTSTRAP_ADMIN_PASSWORD=<a strong password>
OCTO_BOOTSTRAP_ADMIN_NAME=OCTO Admin
```

octo-server creates the row only when the `user` table is empty, so
this is safe to leave set across restarts.

> If your image does not yet honour these vars, the values are simply
> ignored and you should fall back to Option A.

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
