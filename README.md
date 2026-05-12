# OCTO Deployment

Kubernetes deployment manifests for the [OCTO](https://github.com/Mininglamp-OSS) platform.

> 中文版：[README.zh.md](./README.zh.md)
>
> For a single-node Docker Compose trial use [`Mininglamp-OSS/octo-server`](https://github.com/Mininglamp-OSS/octo-server)'s `docker/octo/` stack — it is upstream-maintained and self-contained. This repository focuses on multi-node Kubernetes deployment.

## Components

| Service | Image | Container ports |
|---|---|---|
| octo-server | `mininglamposs/octo-server` | 8090 (http) / 6979 (grpc) |
| octo-web | `mininglamposs/octo-web` | 80 |
| octo-admin | `mininglamposs/octo-admin` | 80 |
| octo-matter | `mininglamposs/octo-matter` | 8080 |
| octo-smart-summary-api | `mininglamposs/octo-smart-summary-api` | 8080 / 8081 |
| octo-smart-summary-worker | `mininglamposs/octo-smart-summary-worker` | 8082 |

External infrastructure expected (provisioned separately, **not** in this repo):

- MySQL 8 with three databases — `octo` (IM core), `octo_matter`, `octo_summary`
- Redis 7
- [WuKongIM](https://github.com/WuKongIM/WuKongIM) ≥ v2 (the IM long-connection backend)
- S3-compatible object storage (MinIO, AWS S3, Tencent COS, etc.)

### WuKongIM

OCTO does not embed an IM engine — it consumes [WuKongIM](https://github.com/WuKongIM/WuKongIM) over the latter's HTTP API and webhook gRPC. You can run any of the deployment modes documented at <https://docs.githubim.com/installation/overview>:

- Docker / docker-compose (single node, fastest to try)
- Kubernetes / Helm (multi-node, for production)
- Standalone binary

Whichever you pick, three things must line up between WuKongIM and `octo-server`:

| WuKongIM config | OCTO setting |
|---|---|
| `managerToken` | `octo-server-config.tsdd.yaml` → `wukongIM.managerToken` (also set as `WUKONGIM_MANAGER_TOKEN` in `octo-server-secret` for env-driven setups) |
| `webhook.grpcAddr` (the address WuKongIM dials back into) | `<octo-server-svc>:6979` so message events reach OCTO |
| `external.ip` / `external.wsAddr` / `external.wssAddr` (the public endpoints WuKongIM advertises to clients) | should match how end-user clients reach WuKongIM via your ingress / LB |

## Layout

```
kustomize/
├── base/                       Generic OSS templates (this is the canonical reference)
│   ├── kustomization.yaml      Pulls all resources, applies image transformer
│   ├── octo-*.yaml             Deployments + Services
│   ├── octo-*-config.yaml      ConfigMaps (non-sensitive)
│   └── octo-*-secret.example.yaml
│                               Secret templates with CHANGE_ME_* placeholders
└── overlays/
    ├── dev/                    Image tag = "dev"
    └── prod/                   Multi-replica production overlay
```

## Quick Start

Namespace is **not** hardcoded — specify it on the CLI.

```bash
# 1. Create the target namespace
kubectl create namespace octo

# 2. Prepare Secrets (one-time per environment).
#    Copy the *.example templates, fill in real values, then apply.
cd kustomize/base
for f in *-secret.example.yaml; do cp "$f" "${f/.example/}"; done
$EDITOR octo-*-secret.yaml         # replace every CHANGE_ME_*
kubectl apply -n octo \
  -f octo-server-secret.yaml \
  -f octo-matter-secret.yaml \
  -f octo-smart-summary-secret.yaml

# 3. Apply ConfigMaps + workloads
kubectl apply -n octo -k .
```

For environment-specific overrides:

```bash
kubectl apply -n octo-dev  -k kustomize/overlays/dev
kubectl apply -n octo-prod -k kustomize/overlays/prod
```

Preview the rendered manifests without applying:

```bash
kubectl kustomize kustomize/base
```

## Pin to a specific version

Edit `kustomize/base/kustomization.yaml` and replace `newTag: latest` with a release tag, e.g. `newTag: v0.1.0`. Each `images:` entry can be overridden independently.

## Secrets

Each service consumes a small Secret. Required keys per service:

| Secret | Required keys |
|---|---|
| `octo-server-secret` | `DM_MYSQL_DSN`, `DM_REDIS_ADDR`, `WUKONGIM_MANAGER_TOKEN`, `OCTO_ADMIN_PASSWORD`, `OCTO_MASTER_KEY`, `DMWORK_MASTER_KEY` (legacy alias of master key), `NOTIFY_INTERNAL_TOKEN`, `OCTO_INTERNAL_HMAC_SECRET`, `OCTO_JWT_SECRET`. Plus OIDC / COS / SMTP / APNS keys when those features are enabled. |
| `octo-matter-secret` | `MYSQL_DSN`, `LLM_API_KEY`, `NOTIFY_INTERNAL_TOKEN` (**must match `octo-server-secret`**). |
| `octo-smart-summary-secret` | `MYSQL_DSN`, `IM_MYSQL_DSN`, `LLM_API_URL`, `LLM_API_KEY`. |

Generate strong random tokens with:

```bash
openssl rand -hex 32     # for *_TOKEN / *_SECRET / MASTER_KEY
openssl rand -base64 32  # for DM_OIDC_RT_ENC_KEY
```

> Secret files (`*-secret.yaml`) are git-ignored. Only the `*.example.yaml` templates are tracked.

## Image registry

Default image references point at `docker.io/mininglamposs/<service>:latest`. To use a self-hosted registry, edit the `images:` block in `kustomize/base/kustomization.yaml`:

```yaml
images:
  - name: mininglamposs/octo-server
    newName: my-registry.example.com/octo/octo-server
    newTag: v0.1.0
```

For private registries that require authentication, create a Docker config Secret and reference it via `imagePullSecrets` on each Deployment (or patch via overlay).

## Open items

- [ ] Add an Ingress / Gateway example for `octo-web` + `octo-admin` (current README assumes you bring your own controller)
- [ ] Document the database bootstrap (which migrations the services apply on boot, vs. which require a one-shot Job)
- [ ] Add a sample MinIO + WuKongIM in-cluster manifest set for users who want a fully self-contained stack
- [ ] APNS `.p8` key mounting (or instructions to disable iOS push)

## License

Apache 2.0 — same as the rest of the OCTO suite.
