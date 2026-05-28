# 国内部署指南

OCTO 6 个应用镜像（octo-server/web/admin/matter/summary-api/summary-worker）默认在 Docker Hub。国内集群直连不稳定，chart 提供了 `values-china.yaml` overlay，把这些镜像换成腾讯云公开镜像源（`tsh8-deepminer-tcr1.tencentcloudcr.com/octo-oss/*`）。除此之外的基础设施镜像（MySQL/Redis/MinIO/WuKongIM/nginx/busybox）通常走集群已配的 Docker Hub mirror（TKE / 阿里云 ACK 等都自带）。

> 镜像 tag 由 `values.yaml` 统一管理，国内/海外共用，下次升版自动跟随。

---

## 前置条件

| 工具 | 版本要求 |
|------|---------|
| Kubernetes | 1.24+ |
| Helm | 3.10+ |
| kubectl | 与集群版本匹配 |
| 默认 StorageClass | （或手动指定 `*.storage.storageClass`） |

---

## 第一步：创建配置文件

新建 `my-values.yaml`，**不要**在里面写 `global.imageRegistry`（让 `values-china.yaml` overlay 接管 6 个 OCTO 应用镜像）：

```yaml
domain: "octo.example.com"
externalBaseURL: "https://octo.example.com"

# Ingress（按实际环境配置）
ingress:
  enabled: true
  className: nginx
  host: "octo.example.com"
  tls:
    enabled: true
    secretName: octo-tls   # kubectl create secret tls octo-tls --cert=tls.crt --key=tls.key

# LLM（AI 功能，可选）
llm:
  apiURL: "https://your-llm-api/v1"
  model: "gpt-4o"

secrets:
  llmApiKey: ""

server:
  config:
    register:
      disabled: false
      emailOn: true
    support:
      email: "noreply@example.com"
      emailSmtp: "smtp.example.com:465"
      emailPwd: "your-smtp-password"
```

---

## 第二步：安装

```bash
kubectl create namespace octo

helm install octo ./helm/octo \
  --namespace octo \
  -f ./helm/octo/values-china.yaml \
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

> **重要**：妥善保存随机生成的密钥值，升级时通过 `--reuse-values` 复用，否则会报"secret must be set"。`secrets.adminPwd` 留空时 octo-server 会跳过 superAdmin 自动创建——首次安装务必设置，否则 `/admin/` 没有可登录账号。

---

## 第三步：验证

```bash
# 等待所有 Pod 就绪（约 2-3 分钟）
kubectl get pods -n octo -w

# 确认 6 个 OCTO 应用镜像均来自腾讯云
kubectl get pods -n octo \
  -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u
```

OCTO 应用镜像应以 `tsh8-deepminer-tcr1.tencentcloudcr.com/octo-oss/` 开头；`mysql/redis/minio/wukongim/nginx/busybox` 仍来自 Docker Hub（依赖集群 mirror）。

---

## 升级

```bash
helm upgrade octo ./helm/octo \
  --namespace octo \
  --reuse-values \
  -f ./helm/octo/values-china.yaml \
  -f my-values.yaml
```

> 不要加 `--wait`：octo-server 的 `minio-bootstrap` init container 与 minio StatefulSet 启动有轻微时序耦合，默认 install 会自然解决，但 `--wait` 会让 Helm 等所有 pod Ready 才返回，导致首次安装时 Helm 命令阻塞较久（不会死锁，但体验差）。

---

## 卸载

```bash
helm uninstall octo -n octo
kubectl delete pvc --all -n octo   # 永久删除所有数据
kubectl delete namespace octo
```

> **警告**：删除 PVC 会永久清除 MySQL、MinIO、Redis、WuKongIM 的数据，请提前备份。
