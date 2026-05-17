# OCTO Deployment

**OCTO 官方 OOTB（开箱即用）部署仓库**——既包含 [`docker/`](./docker/) 下的单机 Docker Compose 栈，也包含 [`kustomize/`](./kustomize/) 下用于 [OCTO](https://github.com/Mininglamp-OSS) 平台的多节点 Kubernetes 清单。

本仓库是 OCTO 部署的 single source of truth。曾经放在 `Mininglamp-OSS/octo-server` 里的部署 artefact（`docker/octo/`、`docker/tsdd/`）已经退役；从这里消费。

---

## ⚠️ 重要声明与免责条款

### 产品定位

OCTO 是一个开源的**团队协作与通信平台**，仅供合法的组织内部使用。OCTO 作为技术框架提供——OCTO 项目及其贡献者**不**运营、托管或管理任何面向终端用户的消息服务。

### 禁止用途

您**不得**直接或间接将 OCTO 用于以下任何目的：

- 未经授权的监控、拦截或窃听私人通信
- 规避执法机构、监管部门或合法政府要求
- 传播违法、有害或违禁内容（包括但不限于欺诈、骚扰、涉恐信息及儿童保护相关违法内容）
- 在要求许可的司法管辖区内，未经许可运营面向公众的即时通讯服务
- 任何违反适用的地方、国家或国际法律法规的活动

### 部署者责任

部署 OCTO 即表示**您**（部署者/运营者）承担以下全部责任：

1. **法规合规** — 取得所在司法管辖区要求的全部许可证照。在中华人民共和国境内，这可能包括但不限于：ICP 备案、即时通信业务相关的增值电信业务经营许可证，以及遵守《网络安全法》《数据安全法》《个人信息保护法》等法律法规。在欧盟地区，可能适用《数字服务法》（DSA）、《通用数据保护条例》（GDPR）及《电子隐私指令》。在美国，可能适用《电子通信隐私法》（ECPA）、《通信协助执法法》（CALEA）及各州隐私法律。其他司法管辖区另有各自的合规要求。
2. **内容审核** — 根据适用法律建立适当的内容审核机制、举报渠道和用户安全保障措施。
3. **数据保护** — 确保数据的处理、存储、留存和删除操作符合适用的数据保护法规。
4. **用户告知** — 就数据收集、处理行为及用户在适用法律下享有的权利，向您的用户充分告知。
5. **安全保障** — 维护您部署实例的安全性，包括及时应用更新和安全补丁。

### 免责声明与责任限制

OCTO 按**"原样"**提供，不附带任何形式的明示或默示担保。OCTO 项目、明略科技及其贡献者不对因部署、运营或使用本软件而产生的任何索赔、损害、法律后果、监管处罚或其他责任承担责任。这包括但不限于因部署者未遵守适用法律法规而导致的任何责任。

完整的 Apache 2.0 许可证条款见 [LICENSE](./LICENSE)。

---

> English: [README.md](./README.md)
>
> **单机 Docker Compose 试用**用本仓库的 [`docker/`](./docker/) ——一条 `docker compose up -d` 起完整 OCTO 栈（server + admin + web + matter + smart-summary + WuKongIM + MySQL + Redis + MinIO + nginx）。中文步骤见 [`docker/README.zh.md`](./docker/README.zh.md)。本 `kustomize/` 树作为多节点 Kubernetes 部署的标准参考保留。

## 单机 Docker Compose 试用（最短路径）

```bash
git clone https://github.com/Mininglamp-OSS/octo-deployment.git
cd octo-deployment
./setup.sh                                  # 交互式向导（自动探测公网 IP，生成所有密钥）
(cd docker && docker compose up -d --wait)  # subshell：保持在 repo 根目录
./setup.sh --verify                         # admin login + presign PUT 端到端检查
```

在全新机器上想一条命令搞定，用 `--up`（GH#32）—— `setup.sh` 写完 `docker/.env` 之后自己起栈，**阻塞直到每个长跑服务都 `(healthy)`、每个一次性 init job（`preflight`、`minio-init`）干净退出**。超时或启动失败时打印 `compose ps`、列出具体出问题的服务名、对每个失败服务给一条 `logs <svc>` 排查命令，然后 exit 1。等待期间每 5 秒打一个 `.`，方便看到脚本还活着：

```bash
./setup.sh --non-interactive --ip <PUBLIC_IP> --up   # 写 .env + 起栈 + 等齐 healthy
./setup.sh --verify
```

`setup.sh` 在最后打印 admin URL + superAdmin 密码。密码同时已写入 `docker/.env`（mode 600）——请把这个文件当成密钥对待，首次登录后从 admin UI 轮换密码（见 `docker/README.zh.md`「首位管理员引导」一节）。客户端只需开**一个** TCP 端口：`28080`（`OCTO_HTTP_PORT`，nginx HTTP 入口）。HTTPS 启用后客户端端口换成 `28443`（`OCTO_HTTPS_PORT`）。其他所有端口（MinIO、MySQL、Redis、WuKongIM monitor、各服务直连 REST）默认 loopback。

卸载 / 重置走交互式：

```bash
./setup.sh --uninstall
# 三档：1) 完全卸载（数据全丢）  2) 仅重置数据  3) 仅重启容器
```

完整文档：[`docker/README.zh.md`](./docker/README.zh.md)（含 `Uninstall / Reset`、`Network surface`、`MinIO bootstrap`、`Hardening checklist`、故障排查等章节）。

## Kubernetes 部署组件

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
- [WuKongIM](https://github.com/WuKongIM/WuKongIM) ≥ v2（IM 长连接后端）
- 兼容 S3 的对象存储（MinIO / AWS S3 / 腾讯 COS 等）

### WuKongIM

OCTO 不内置 IM 引擎，通过 HTTP API + webhook gRPC 调用 [WuKongIM](https://github.com/WuKongIM/WuKongIM)。可以按 <https://docs.githubim.com/zh/installation/overview> 文档选用任一部署方式：

- Docker / docker-compose（单机，最快试用）
- Kubernetes / Helm（多节点，生产推荐）
- 直接跑二进制

无论哪种部署方式，WuKongIM 与 `octo-server` 必须在这三处对齐：

| WuKongIM 配置 | OCTO 对应配置 |
|---|---|
| `managerToken` | `octo-server-config.tsdd.yaml` → `wukongIM.managerToken`（env 驱动场景则在 `octo-server-secret` 里设 `WUKONGIM_MANAGER_TOKEN`） |
| `webhook.grpcAddr`（WuKongIM 回调地址） | `<octo-server-svc>:6979`，让 IM 消息事件能回到 OCTO |
| `external.ip` / `external.wsAddr` / `external.wssAddr`（WuKongIM 对客户端暴露的公网地址） | 与终端客户端经 ingress / LB 访问 WuKongIM 的实际地址一致 |

## 目录结构

```
docker/                         单机 Docker Compose 栈
├── docker-compose.yaml
├── .env.example
├── README.md / README.zh.md
└── ...
kustomize/                      多节点 K8s 部署
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

## 快速开始（Kubernetes 路径）

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
