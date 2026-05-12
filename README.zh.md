# OCTO Deployment

[OCTO](https://github.com/Mininglamp-OSS) 平台的 Kubernetes 部署清单。

> English: [README.md](./README.md)
>
> 单机 Docker Compose 试用请使用 [`Mininglamp-OSS/octo-server`](https://github.com/Mininglamp-OSS/octo-server) 仓库内的 `docker/octo/`（上游维护，自包含）。本仓库专注多节点 Kubernetes 部署。

## 组件

| 服务 | 镜像 | 容器端口 |
|---|---|---|
| octo-server | `mininglamposs/octo-server` | 8090（http） / 6979（grpc） |
| octo-web | `mininglamposs/octo-web` | 80 |
| octo-admin | `mininglamposs/octo-admin` | 80 |
| octo-matter | `mininglamposs/octo-matter` | 8080 |
| octo-smart-summary-api | `mininglamposs/octo-smart-summary-api` | 8080 / 8081 |
| octo-smart-summary-worker | `mininglamposs/octo-smart-summary-worker` | 8082 |

依赖的外部基础设施（需自行准备，**不**在本仓库内）：

- MySQL 8，三个库：`octo`（IM 核心）、`octo_matter`、`octo_summary`
- Redis 7
- WuKongIM ≥ v2（IM 长连接后端）
- 兼容 S3 的对象存储（MinIO / AWS S3 / 腾讯 COS 等）

## 目录结构

```
kustomize/
├── base/                       通用 OSS 模板（参考实现）
│   ├── kustomization.yaml      汇总所有资源 + image transformer
│   ├── octo-*.yaml             Deployment + Service
│   ├── octo-*-config.yaml      ConfigMap（非敏感）
│   └── octo-*-secret.example.yaml
│                               Secret 模板，含 CHANGE_ME_* 占位
└── overlays/
    ├── dev/                    镜像 tag=dev 的 overlay
    └── prod/                   多副本生产 overlay
```

## 快速开始

namespace **不写死**，由命令行指定。

```bash
# 1. 创建目标 namespace
kubectl create namespace octo

# 2. 准备 Secret（每个环境一次性操作）。
#    把 *.example 模板复制一份，填入真实值后 apply。
cd kustomize/base
for f in *-secret.example.yaml; do cp "$f" "${f/.example/}"; done
$EDITOR octo-*-secret.yaml         # 把每处 CHANGE_ME_* 替换成真实值
kubectl apply -n octo \
  -f octo-server-secret.yaml \
  -f octo-matter-secret.yaml \
  -f octo-smart-summary-secret.yaml

# 3. apply ConfigMap + Workload
kubectl apply -n octo -k .
```

环境差异化部署：

```bash
kubectl apply -n octo-dev  -k kustomize/overlays/dev
kubectl apply -n octo-prod -k kustomize/overlays/prod
```

预览渲染结果但不应用：

```bash
kubectl kustomize kustomize/base
```

## 锁定版本

编辑 `kustomize/base/kustomization.yaml`，把 `newTag: latest` 换成 release tag，例如 `newTag: v0.1.0`。`images:` 列表里每条都可独立覆盖。

## Secret

各服务消费一个独立 Secret，必填字段如下：

| Secret | 必填 Key |
|---|---|
| `octo-server-secret` | `DM_MYSQL_DSN`、`DM_REDIS_ADDR`、`WUKONGIM_MANAGER_TOKEN`、`OCTO_ADMIN_PASSWORD`、`OCTO_MASTER_KEY`、`DMWORK_MASTER_KEY`（master key 的 legacy 别名）、`NOTIFY_INTERNAL_TOKEN`、`OCTO_INTERNAL_HMAC_SECRET`、`OCTO_JWT_SECRET`。启用 OIDC / COS / SMTP / APNS 时再加对应字段。 |
| `octo-matter-secret` | `MYSQL_DSN`、`LLM_API_KEY`、`NOTIFY_INTERNAL_TOKEN`（**必须与 `octo-server-secret` 一致**）。 |
| `octo-smart-summary-secret` | `MYSQL_DSN`、`IM_MYSQL_DSN`、`LLM_API_URL`、`LLM_API_KEY`。 |

随机 token 生成：

```bash
openssl rand -hex 32     # *_TOKEN / *_SECRET / MASTER_KEY
openssl rand -base64 32  # DM_OIDC_RT_ENC_KEY
```

> Secret 文件（`*-secret.yaml`）已被 .gitignore 排除，仓库里只跟踪 `*.example.yaml` 模板。

## 镜像仓库

默认镜像地址 `docker.io/mininglamposs/<service>:latest`。要换成自建仓库，改 `kustomize/base/kustomization.yaml` 的 `images:` 段：

```yaml
images:
  - name: mininglamposs/octo-server
    newName: my-registry.example.com/octo/octo-server
    newTag: v0.1.0
```

私有仓库需要鉴权时，创建 Docker config 类型的 Secret，并在每个 Deployment（或通过 overlay patch）里 `imagePullSecrets` 引用。

## 待补

- [ ] Ingress / Gateway 示例（当前 README 默认你自带 controller）
- [ ] 数据库初始化说明（哪些 migration 服务启动时自动应用、哪些需要 Job 一次性导入）
- [ ] MinIO + WuKongIM 在集群内部署的样板（给希望完全自包含部署的用户）
- [ ] APNS `.p8` 挂载方式（或如何禁用 iOS 推送）

## License

Apache 2.0 —— 与 OCTO 套件其余仓库一致。
