# OCTO Helm Chart

通过一条 `helm install` 命令，在 Kubernetes 上部署完整的 OCTO 服务栈——MySQL、Redis、MinIO、WuKongIM、Nginx 以及所有应用服务。

## 前置条件

| 工具 | 版本要求 |
|------|---------|
| Kubernetes | 1.24+ |
| Helm | 3.10+ |
| kubectl | 与集群版本匹配 |
| 默认 StorageClass | （或手动指定 `*.storage.storageClass`） |

---

## 快速开始

### 1. 创建配置文件

新建 `my-values.yaml`，填入你的配置：

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
      disabled: false      # 允许用户自主注册
      emailOn: true
    support:
      email: "noreply@example.com"
      emailSmtp: "smtp.gmail.com:465"
      emailPwd: "your-app-password"
```

查看所有可用配置项：

```bash
helm show values oci://ghcr.io/mininglamp-oss/octo --version 0.3.1
```

### 2. 安装

**国内用户**先叠加 `values-china.yaml`，把 6 个 OCTO 应用镜像从 Docker Hub 切到腾讯云 registry（`tsh8-deepminer-tcr1.tencentcloudcr.com/octo-oss/*`）。镜像 tag 从 `values.yaml` 继承，单点升版同时覆盖两个区域：

```bash
helm install octo ./helm/octo \
  -f ./helm/octo/values-china.yaml \   # <-- 只有国内需要，海外省略
  -f my-values.yaml \
  ...
```

海外用户不加 `-f values-china.yaml`，默认从 Docker Hub 拉取。

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
  --set secrets.userApiKeySecret="$(openssl rand -hex 16)" \
  --set secrets.notifyInternalToken="$(openssl rand -hex 32)" \
  --set secrets.wukongimManagerToken="$(openssl rand -hex 32)" \
  --set secrets.adminPwd="$(openssl rand -hex 16)"
```

> **重要：** 请妥善保存安装时随机生成的密钥值，升级时需要用到。  
> 建议存入密钥管理工具或本地加密文件。

### 3. 等待所有 Pod 就绪

```bash
kubectl get pods -n octo -w
```

全部 11 个 Pod 应在 2–3 分钟内达到 `1/1 Running` 状态。

### 4. 暴露服务

默认 `nginx.service.type` 为 `ClusterIP`，根据实际环境选择暴露方式：

**Ingress**（推荐，已在上方 `my-values.yaml` 中配置）：  
将域名 DNS 指向 Ingress 控制器的外部 IP，访问 `https://octo.example.com` 即可。

**LoadBalancer**（云环境）：  
在 `my-values.yaml` 中添加：
```yaml
nginx:
  service:
    type: LoadBalancer
```

**端口转发**（本地测试）：
```bash
kubectl port-forward -n octo svc/octo-nginx 8080:80
# 浏览器访问 http://localhost:8080
```

---

## 升级

```bash
helm upgrade octo oci://ghcr.io/mininglamp-oss/octo --version 0.3.1 \
  --namespace octo \
  --reuse-values \
  -f my-values.yaml
```

`--reuse-values` 会保留安装时设置的密钥，`-f` 只需传入有变更的配置。

---

## HTTPS / TLS

内置 Nginx 在集群内部以纯 HTTP 处理所有路由，TLS 终止应在边缘完成——云负载均衡器或 Kubernetes Ingress 控制器均可。

如果负载均衡器或 Ingress 已做 TLS 终止，只需设置：

```yaml
externalBaseURL: "https://octo.example.com"
```

WebSocket 地址（`wss://`）和 MinIO 预签名 URL 的协议会自动从 `externalBaseURL` 推导，无需额外配置。

---

## 核心配置参数

### 顶层参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `domain` | 公网访问域名 | `octo.local` |
| `externalBaseURL` | 完整公网地址（含协议和域名） | `http://<domain>:80` |
| `timezone` | 容器时区 | `UTC` |

### 密钥

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `secrets.mysqlRootPassword` | MySQL root 密码 | `""` |
| `secrets.minioRootPassword` | MinIO root 密码（≥ 8 位） | `""` |
| `secrets.minioAppPassword` | MinIO 应用级 IAM 密码 | `""` |
| `secrets.matterDbPassword` | matter 服务的 MySQL 密码 | `""` |
| `secrets.summaryDbPassword` | summary 服务的 MySQL 密码 | `""` |
| `secrets.summaryReaderPassword` | summary 服务的 MySQL 只读密码 | `""` |
| `secrets.octoMasterKey` | OCTO 主密钥（恰好 32 位十六进制） | `""` |
| `secrets.userApiKeySecret` | usersecret / botfather 用户 API Key 加密密钥（恰好 32 位十六进制） | `""` |
| `secrets.notifyInternalToken` | 服务间 HMAC 令牌 | `""` |
| `secrets.wukongimManagerToken` | WuKongIM 管理员令牌 | `""` |
| `secrets.adminPwd` | 初始超级管理员密码 | `superAdmin` |
| `secrets.llmApiKey` | AI 功能 LLM API Key | `""` |

### LLM（AI 功能）

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `llm.apiURL` | LLM API 地址 | `https://api.example.com/v1` |
| `llm.model` | 模型名称 | `claude-sonnet-4-6` |

### octo-server 运行时配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `server.config.register.disabled` | 禁止用户自主注册 | `true` |
| `server.config.register.emailOn` | 启用邮箱注册 | `false` |
| `server.config.support.email` | 发件人地址 | `""` |
| `server.config.support.emailSmtp` | SMTP 服务器（`host:port`） | `""` |
| `server.config.support.emailPwd` | SMTP 密码（自动渲染到 Secret，不会出现在 ConfigMap） | `""` |
| `server.config.logger.level` | 日志级别（0=关闭 … 4=调试） | `2` |
| `summary.enabled` | 启用 Smart Summary（要求设置 `secrets.llmApiKey`） | `false` |

常用 SMTP 配置示例：

| 邮件服务 | SMTP 地址 | 说明 |
|---------|-----------|------|
| Gmail | `smtp.gmail.com:465` | 使用应用专用密码 |
| QQ 邮箱 | `smtp.qq.com:465` | 使用授权码 |
| 163 邮箱 | `smtp.163.com:465` | 使用授权码 |
| Outlook | `smtp.office365.com:587` | 使用账号密码 |

### 存储配置

每个有状态组件均支持 `storage.size` 和 `storage.storageClass`：

```yaml
mysql:
  storage:
    size: 20Gi
    storageClass: ""   # 留空使用集群默认 StorageClass

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

### 外部服务

如果要复用已有的 MySQL / Redis / MinIO / WuKongIM 而不部署 chart 内置的 StatefulSet，把对应的 `<service>.enabled` 置为 `false`，并填入对应的 `external<Service>` 字段：

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
  minioAppPassword: "..."           # IAM 凭据由外部 MinIO 维护

wukongim:
  enabled: false
externalWukongim:
  apiURL: "http://wukongim.prod.svc:5001"
  wsEndpoint: "wukongim.prod.svc:5200"   # nginx ws upstream 用 host:port
```

`<service>.enabled: false` 但对应 `external<Service>.*` 字段为空时，`helm template` 会直接失败，不会渲染出半成品 manifest。

### Ingress 配置

```yaml
ingress:
  enabled: false
  className: ""          # 如 nginx、traefik、qcloud
  host: ""               # 默认使用 .Values.domain
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "1000m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
  tls:
    enabled: false
    secretName: ""       # 已存在的 TLS Secret 名称
```

---

## 搜索（可选）

消息搜索（Kafka + OpenSearch[analysis-ik] + es-indexer）是**可选**组件，**默认关闭**。
当 `search.enabled=false`（默认）时，chart 渲染**零**个搜索资源——与 `docker`
（`--search` / `COMPOSE_PROFILES=search`）和 `kustomize/search` 对齐。

```yaml
search:
  enabled: true        # 默认 false → 不渲染任何搜索资源
```

开启后只部署搜索**基础设施**，**不会**将 octo-server 接到 OpenSearch（reader 后端 /
producer 切换）。后者是独立的、需 owner 把关的步骤，**不在本 chart 范围内**——与
`kustomize/search` 一致（同样只装基础设施）。本开关**不改动**
`deployment-octo-server` 及其 ConfigMap。

### 开启清单

1. **构建并推送 OpenSearch 镜像。** `search.opensearch.image` 默认为
   `octo-search-opensearch-ik:2.17.0`，这是**本地构建名，直接拉取会失败**。请构建
   `docker/opensearch/Dockerfile`（内置 analysis-ik，插件版本必须与 OpenSearch 版本一致），
   推送到你的 registry，并设置 `search.opensearch.image.repository`/`tag`
   （或 `global.imageRegistry`）。
2. **固定 indexer 镜像。** `search.indexer.image` 仅在 `v*` tag / 手动触发时发布；
   生产环境请固定到真实 tag/digest。
3. 私有 registry 的**拉取凭据**通过 `global.imagePullSecrets`（chart 级）统一配置，
   而非每个 pod 单独配置。

### `clusterId` 不可变

`search.kafka.clusterId` 在首次安装时会在 Kafka PVC 上格式化 KRaft 元数据。
**在已有 PVC 上修改它会导致 broker 崩溃循环。** 只有在全新部署 / 全新 PVC 时才重新
生成（`kafka-storage.sh random-uuid`）。

### 独立 producer 为禁用产物

`search.producer` 以**禁用产物**形式发布：`enabled: false` + `replicas: 0`。
实际运行它（`replicas>0`）**需 owner 把关，且超出本 chart 版本范围**——chart 会在
**渲染期对任何 `replicas>0` fail-fast**。本 chart **比 `kustomize/search` 收紧**：
kustomize 依赖**运行时**互斥（Redis run-lock + cursor CAS + `producer-mutex-guard`
initContainer），渲染期守卫无法替代；本 chart 额外在渲染期挡掉 `replicas>0`。
`producer-mutex-guard` initContainer 作为运行时兜底保留。后续票放开此路径时，请通过
`search.producer.existingSecret`（预建 Secret）引用凭据，不要用 `--set` 内联 DSN
（会泄漏到 release Secret、values 历史和 shell 历史）。

### 生产加固

OpenSearch 安全插件**默认关闭**（`search.opensearch.disableSecurityPlugin: true`），
且 chart**不附带 NetworkPolicy**。生产环境请将搜索运行在网络隔离的 namespace，
开启 OpenSearch 安全插件（设 `disableSecurityPlugin: false` 并在 es-indexer 上配置
`ES_USERNAME`/`ES_PASSWORD`），并限制对 OpenSearch/Kafka Service 的访问。

### 验证就绪

```bash
# OpenSearch 健康
kubectl exec -n <ns> sts/octo-search-opensearch -- \
  curl -s localhost:9200/_cluster/health
# 验证 post-install hook 创建的 Kafka topic
kubectl exec -n <ns> sts/octo-search-kafka -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

> **china overlay 说明：** 新增的搜索镜像（自建 opensearch-ik + 私有 indexer）
> 尚未为 `values-china.yaml` 镜像化；接通 china overlay 的搜索镜像覆盖是后续票。

---

## 卸载

```bash
helm uninstall octo -n octo
kubectl delete pvc --all -n octo   # 删除持久化数据
kubectl delete namespace octo
```

> **警告：** 删除 PVC 会永久清除所有数据（MySQL、MinIO、Redis、WuKongIM），卸载前请做好备份。

---

## 架构说明

```
                    ┌─────────────────────────────────────┐
  浏览器 / 客户端 ──▶ │  Kubernetes Ingress / LoadBalancer  │
                    └──────────────┬──────────────────────┘
                                   │ :80
                    ┌──────────────▼──────────────────────┐
                    │           octo-nginx                 │
                    │  （路由分发、限速、WebSocket 升级）     │
                    └──┬──────┬──────┬──────┬─────────────┘
                       │      │      │      │
                   /api/  /ws  /minio/ /admin/ /matter/ /summary/
                       │      │      │      │
              octo-server  wukongim  minio  octo-admin
              octo-web              │      octo-matter
                                    │      summary-api
                              mysql / redis summary-worker
```

所有路由复杂性（WebSocket 升级、URL 改写、预签名 URL 透传）均由内置 Nginx 处理。Kubernetes Ingress 只需一条兜底规则，将流量指向 `octo-nginx` Service 即可。
