# OCTO Helm Chart

Deploy the full OCTO stack on Kubernetes — MySQL, Redis, MinIO, WuKongIM, Nginx, and all application services — with a single `helm install`.

## Prerequisites

| Tool | Version |
|------|---------|
| Kubernetes | 1.24+ |
| Helm | 3.10+ |
| kubectl | matching cluster version |
| A default StorageClass | (or set `*.storage.storageClass`) |

---

## Quick Start

### 1. Create a values file

Create `my-values.yaml` with your configuration:

```yaml
# my-values.yaml
domain: "octo.example.com"
externalBaseURL: "https://octo.example.com"

ingress:
  enabled: true
  className: nginx
  host: "octo.example.com"
  tls:
    enabled: true
    secretName: octo-tls   # kubectl create secret tls octo-tls --cert=tls.crt --key=tls.key

llm:
  apiURL: "https://api.openai.com/v1"
  model: "gpt-4o"

secrets:
  llmApiKey: "sk-..."

server:
  config:
    register:
      disabled: false      # allow self-registration
      emailOn: true
    support:
      email: "noreply@example.com"
      emailSmtp: "smtp.gmail.com:465"
      emailPwd: "your-app-password"
```

To see all available options:

```bash
helm show values oci://ghcr.io/mininglamp-oss/octo --version 0.3.1
```

### 2. Install

**For users in China**, layer `values-china.yaml` first to switch the 6 OCTO app images from Docker Hub to the Tencent Cloud registry (`tsh8-deepminer-tcr1.tencentcloudcr.com/octo-oss/*`). Image tags inherit from `values.yaml`, so version bumps propagate to both regions:

```bash
helm install octo ./helm/octo \
  -f ./helm/octo/values-china.yaml \   # <-- only for China; omit elsewhere
  -f my-values.yaml \
  ...
```

For overseas users, omit `-f values-china.yaml` — defaults pull from Docker Hub.

```bash
helm install octo oci://ghcr.io/mininglamp-oss/octo --version 0.3.1 \
  --namespace octo --create-namespace \
  -f my-values.yaml \
  --set secrets.mysqlRootPassword="$(openssl rand -hex 16)" \
  --set secrets.minioRootPassword="$(openssl rand -hex 16)" \
  --set secrets.minioAppPassword="$(openssl rand -hex 24)" \
  --set secrets.matterDbPassword="$(openssl rand -hex 16)" \
  --set secrets.summaryDbPassword="$(openssl rand -hex 16)" \
  --set secrets.summaryReaderPassword="$(openssl rand -hex 16)" \
  --set secrets.octoMasterKey="$(openssl rand -hex 16)" \
  --set secrets.notifyInternalToken="$(openssl rand -hex 32)" \
  --set secrets.wukongimManagerToken="$(openssl rand -hex 32)" \
  --set secrets.adminPwd="$(openssl rand -hex 16)"
```

> **Important:** Save the randomly generated secret values — they are required for future upgrades.  
> Store them in a secrets manager or a local encrypted file.

### 3. Wait for all pods to be ready

```bash
kubectl get pods -n octo -w
```

All 11 pods should reach `1/1 Running` within 2–3 minutes.

### 4. Expose the service

By default `nginx.service.type` is `ClusterIP`. Expose it via your preferred method:

**Ingress** (recommended, configured in `my-values.yaml` above):  
Point your DNS to the Ingress controller's external IP and access `https://octo.example.com`.

**LoadBalancer** (cloud providers):  
Add to `my-values.yaml`:
```yaml
nginx:
  service:
    type: LoadBalancer
```

**Port-forward** (local testing):
```bash
kubectl port-forward -n octo svc/octo-nginx 8080:80
# open http://localhost:8080
```

---

## Upgrade

```bash
helm upgrade octo oci://ghcr.io/mininglamp-oss/octo --version 0.3.1 \
  --namespace octo \
  --reuse-values \
  -f my-values.yaml
```

`--reuse-values` preserves the secrets set during install. Only pass `-f` for values that change.

---

## HTTPS / TLS

The embedded Nginx handles all routing internally over plain HTTP. TLS termination should happen at the edge — either a cloud load balancer or a Kubernetes Ingress controller.

If your load balancer or ingress controller terminates TLS, set:

```yaml
externalBaseURL: "https://octo.example.com"
```

The WebSocket address (`wss://`) and MinIO presigned URL scheme are derived automatically from `externalBaseURL` — no additional config needed.

---

## Key Configuration Reference

### Top-level

| Parameter | Description | Default |
|-----------|-------------|---------|
| `domain` | Public hostname | `octo.local` |
| `externalBaseURL` | Full public URL (scheme + host) | `http://<domain>:80` |
| `timezone` | Container timezone | `UTC` |

### Secrets

| Parameter | Description | Default |
|-----------|-------------|---------|
| `secrets.mysqlRootPassword` | MySQL root password | `""` |
| `secrets.minioRootPassword` | MinIO root password (≥ 8 chars) | `""` |
| `secrets.minioAppPassword` | MinIO app-scoped IAM password | `""` |
| `secrets.matterDbPassword` | MySQL password for matter service | `""` |
| `secrets.summaryDbPassword` | MySQL password for summary service | `""` |
| `secrets.summaryReaderPassword` | MySQL read-only password for summary | `""` |
| `secrets.octoMasterKey` | OCTO master key (exactly 32 hex chars) | `""` |
| `secrets.notifyInternalToken` | Inter-service HMAC token | `""` |
| `secrets.wukongimManagerToken` | WuKongIM admin token | `""` |
| `secrets.adminPwd` | Initial superAdmin password | `superAdmin` |
| `secrets.llmApiKey` | LLM API key for AI features | `""` |

### LLM (AI features)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `llm.apiURL` | LLM API base URL | `https://api.example.com/v1` |
| `llm.model` | Model name | `claude-sonnet-4-6` |

### octo-server runtime

| Parameter | Description | Default |
|-----------|-------------|---------|
| `server.config.register.disabled` | Disable self-registration | `true` |
| `server.config.register.emailOn` | Enable email registration | `false` |
| `server.config.support.email` | Sender address for outbound email | `""` |
| `server.config.support.emailSmtp` | SMTP server (`host:port`) | `""` |
| `server.config.support.emailPwd` | SMTP password (rendered into the Secret, never the ConfigMap) | `""` |
| `server.config.logger.level` | Log level (0=off … 4=debug) | `2` |
| `summary.enabled` | Enable Smart Summary (requires `secrets.llmApiKey`) | `false` |

### Storage

Each stateful component has a `storage.size` and `storage.storageClass` field:

```yaml
mysql:
  storage:
    size: 20Gi
    storageClass: ""   # uses cluster default

redis:
  storage:
    size: 10Gi

minio:
  storage:
    size: 50Gi

wukongim:
  storage:
    size: 10Gi
```

### External services

To point at pre-existing MySQL / Redis / MinIO / WuKongIM instead of the bundled StatefulSets, set the corresponding `<service>.enabled: false` and fill in the matching `external<Service>` block:

```yaml
redis:
  enabled: false
externalRedis:
  addr: "redis.prod.svc:6379"       # host:port

minio:
  enabled: false
externalMinio:
  endpoint: "minio.prod.svc:9000"   # host:port
  appUser: "octo-app"
secrets:
  minioAppPassword: "..."           # IAM credentials managed externally

wukongim:
  enabled: false
externalWukongim:
  apiURL: "http://wukongim.prod.svc:5001"
  wsEndpoint: "wukongim.prod.svc:5200"   # host:port for nginx ws upstream
```

The chart fails fast (`helm template` errors out) if `<service>.enabled: false` but the corresponding `external<Service>.*` field is empty.

### Ingress

```yaml
ingress:
  enabled: false
  className: ""          # e.g. nginx, traefik, qcloud
  host: ""               # defaults to .Values.domain
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "1000m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
  tls:
    enabled: false
    secretName: ""       # existing TLS secret name
```

---

## Search (optional)

Message search (Kafka + OpenSearch[analysis-ik] + es-indexer) is an **opt-in**
component, **default OFF**. With `search.enabled=false` (the default) the chart
renders **zero** search resources — parity with `docker` (`--search` /
`COMPOSE_PROFILES=search`) and `kustomize/search`.

```yaml
search:
  enabled: true        # default false → no search resources rendered
```

Enabling deploys search **infrastructure only**. It does **not** wire
octo-server onto OpenSearch (reader backend / producer cut-over). That is a
separate, owner-gated step and is **out of scope** for this chart — parity with
`kustomize/search`, which is also infra-only. `deployment-octo-server` and its
ConfigMap are untouched by this toggle.

### Enable checklist

1. **Build & push the OpenSearch image.** `search.opensearch.image` defaults to
   `octo-search-opensearch-ik:2.17.0`, which is a **local build name and will
   NOT pull as-is**. Build `docker/opensearch/Dockerfile` (analysis-ik baked in;
   plugin version MUST match the OpenSearch version), push to your registry, and
   set `search.opensearch.image.repository`/`tag` (or `global.imageRegistry`).
2. **Pin the indexer image.** `search.indexer.image` is published only on `v*`
   tags / manual dispatch; pin a real tag/digest for prod.
3. **Pull secrets** for private registries go through `global.imagePullSecrets`
   (chart-wide), not a per-pod secret.

### `clusterId` is immutable

`search.kafka.clusterId` formats the KRaft metadata on the Kafka PVC on first
install. **Changing it on an existing PVC crash-loops the broker.** Regenerate
(`kafka-storage.sh random-uuid`) ONLY for a fresh deploy / fresh PVC.

### Standalone producer is a disabled artifact

`search.producer` is shipped **disabled-artifact-only**: `enabled: false` +
`replicas: 0`. Actually running it (`replicas>0`) is **owner-gated and out of
scope for this chart revision** — the chart **fail-fasts at render time** on any
`replicas>0`. This chart is **deliberately stricter than `kustomize/search`**:
kustomize relies on **runtime** mutual exclusion (Redis run-lock + cursor CAS +
the `producer-mutex-guard` initContainer), which a template-time render guard
cannot replace; this chart additionally blocks `replicas>0` at render. The
`producer-mutex-guard` initContainer is preserved as the runtime backstop. When
a future ticket opens this path, reference credentials via
`search.producer.existingSecret` (a pre-created Secret) rather than inlining the
DSN with `--set` (which would leak it into the release Secret, values history,
and shell history).

### Production hardening

The OpenSearch security plugin is **disabled by default**
(`search.opensearch.disableSecurityPlugin: true`) and the chart ships **no
NetworkPolicy**. For production, run search on a network-isolated namespace,
enable the OpenSearch security plugin (set `disableSecurityPlugin: false` and
wire `ES_USERNAME`/`ES_PASSWORD` on the es-indexer), and restrict access to the
OpenSearch/Kafka Services.

### Verify readiness

```bash
# OpenSearch health
kubectl exec -n <ns> sts/octo-search-opensearch -- \
  curl -s localhost:9200/_cluster/health
# Kafka topics created by the post-install hook
kubectl exec -n <ns> sts/octo-search-kafka -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

> **china overlay note:** the new search images (self-built opensearch-ik +
> private indexer) are not yet mirrored for `values-china.yaml`; wiring the
> china overlay's search image overrides is a separate follow-up.

---

## Uninstall

```bash
helm uninstall octo -n octo
kubectl delete pvc --all -n octo   # remove persistent data
kubectl delete namespace octo
```

> **Warning:** Deleting PVCs permanently removes all data (MySQL, MinIO, Redis, WuKongIM). Back up before uninstalling.

---

## Architecture

```
                    ┌─────────────────────────────────────┐
  Browser / App ──▶ │  Kubernetes Ingress / LoadBalancer  │
                    └──────────────┬──────────────────────┘
                                   │ :80
                    ┌──────────────▼──────────────────────┐
                    │           octo-nginx                 │
                    │  (routing, rate-limit, WS upgrade)   │
                    └──┬──────┬──────┬──────┬─────────────┘
                       │      │      │      │
                   /api/  /ws  /minio/ /admin/ /matter/ /summary/
                       │      │      │      │
              octo-server  wukongim  minio  octo-admin
              octo-web              │      octo-matter
                                    │      summary-api
                              mysql / redis summary-worker
```

All routing complexity (WebSocket upgrades, URL rewrites, presigned-URL passthrough) is handled by the embedded Nginx. The Kubernetes Ingress only needs a single catch-all rule pointing at the `octo-nginx` Service.
