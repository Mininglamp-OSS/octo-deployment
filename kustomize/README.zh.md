# OCTO · Kubernetes（kustomize）

OCTO 平台的多节点 Kubernetes 部署。本目录是带真实 ingress controller、多副本 workload 和外部 provision 的后端服务（MySQL / Redis / WuKongIM / S3 兼容对象存储）跑 OCTO 的标准参考。

> English: [README.md](./README.md)
>
> **单机 Docker Compose 试用**用仓库根目录的 [`../docker/`](../docker/) 树——一条 `docker compose up -d` 起完整栈。本 `kustomize/` 树是多节点 K8s 路径。

## 快速开始

完整流程见[顶层 `README.zh.md`](../README.zh.md) 的 "快速开始（Kubernetes 路径）" 章节。短版本：

```bash
kubectl create namespace octo

cd kustomize/base
for f in *-secret.example.yaml; do cp "$f" "${f/.example/}"; done
$EDITOR octo-*-secret.yaml         # 把每处 CHANGE_ME_* 替换成真实值

kubectl apply -n octo \
  -f octo-server-secret.yaml \
  -f octo-matter-secret.yaml \
  -f octo-smart-summary-secret.yaml

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

`kustomize/search/`（Kafka + OpenSearch + es-indexer）是**可选**的独立搜索
overlay，**默认关闭**：它故意**不**被 `base` 或任何 overlay 引用，所以
`kubectl apply -k base|overlays/dev|overlays/prod` 渲染**零**个搜索资源。需显式
opt-in：`kubectl apply -k kustomize/search`，详见
[`kustomize/search/README.md`](./search/README.md)。这与其他部署入口的可选搜索
开关一致（docker `--search`、helm `search.enabled`）。

## 待补

- [ ] `octo-web` + `octo-admin` 的 Ingress / Gateway 示例
- [ ] 集群内 MinIO + WuKongIM 示例 manifest
- [ ] APNS `.p8` 挂载说明

完整 Secret 契约、镜像仓库 override 模式和组件参考见[顶层 `README.zh.md`](../README.zh.md)。
