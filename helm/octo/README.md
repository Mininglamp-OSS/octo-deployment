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
helm show values oci://ghcr.io/mininglamp-oss/octo --version 0.2.1
```

### 2. Install

```bash
helm install octo oci://ghcr.io/mininglamp-oss/octo --version 0.2.1 \
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
helm upgrade octo oci://ghcr.io/mininglamp-oss/octo --version 0.2.1 \
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
| `server.config.support.emailPwd` | SMTP password | `""` |
| `server.config.logger.level` | Log level (0=off … 4=debug) | `2` |

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
