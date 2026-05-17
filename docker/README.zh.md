# OCTO · Docker Compose 部署

OCTO 全栈一键部署 —— server、admin console、web UI、matter、smart-summary、WuKongIM、MySQL、Redis、MinIO 以及前置 nginx 反向代理，全部由单个 `docker-compose.yaml` 串起来。

本栈面向：

- 单机评估部署
- 内部 demo / staging
- 「我就想试试 OCTO」的标准路径

多节点 / 生产部署请使用 `kustomize/base/` 并自带 DB / 缓存 / 对象存储。

> English: [README.md](./README.md)

## TL;DR —— 从 `git clone` 到可用 OCTO 的最短路径

```bash
git clone https://github.com/Mininglamp-OSS/octo-deployment.git
cd octo-deployment
./setup.sh                                         # 交互式向导
(cd docker && docker compose up -d --wait)         # subshell：起完仍回到原目录
./setup.sh --verify                                # 端到端自检（admin 登录 + 文件预签名 PUT）

# 浏览器打开（密码在 setup.sh 末尾打印）：
#   Admin: http://<你的域名>:28080/admin/   (用户：superAdmin)
#   Web:   http://<你的域名>:28080/
```

对客户端流量只需**对外开一个 TCP 端口：28080**（可通过 `OCTO_HTTP_PORT` 调整）。所有后端服务（MinIO API/console、MySQL、Redis、WuKongIM monitor、各服务直连 REST 端口）默认 loopback。详见下方 [Network surface](#network-surface) 章节。

---

## ⚠ 前置：本机已有其他 OCTO 部署的情况

> **每次 `docker compose up -d` / `docker compose down -v` 之前都要看一眼这段**，
> 只要这台机器上还有可能存在另一份 OCTO 实例。

`docker-compose.yaml` 把 Compose project name 写死为 `octo`（顶层 `name: octo`）。这让栈内 DNS 名（`mysql`、`redis`、`octo-server`…）稳定，但代价是**同一台机器上两份独立 clone 默认共享同一个 project name**——也就是说 `/tmp/foo` 里那份「新 clone」的一个 `docker compose down -v` 会清掉 `/opt/octo-deployment` 这份生产 clone 的所有 named volume（MySQL 数据、MinIO 对象、WuKongIM 消息队列…）。`im-test` 2026-05-16 整个用户库被清就是这么没的（INCIDENT-2026-05-16-001）。

为防御这种情况，named volume 现已模板化为 `${COMPOSE_PROJECT_NAME:-octo}_*`（见 `docker-compose.yaml` 里的 `volumes:` 块）。要在已经跑着 OCTO 的机器上起第二份隔离的栈，只需在 up 之前 export 项目名：

```bash
# 在已经跑着 OCTO 的机器上起第二份栈：
export COMPOSE_PROJECT_NAME=octo-fz   # 任意唯一后缀
./setup.sh --non-interactive --domain octo-fz.local --ip 127.0.0.1
cd docker
docker compose up -d                  # 卷名：octo-fz_mysql-data, …
```

两份栈就有完全独立的 Docker volume（`octo_mysql-data` 对 `octo-fz_mysql-data`）、网络（`octo_octo-net` 对 `octo-fz_octo-net`）和容器名（`octo-mysql-1` 对 `octo-fz-mysql-1`）。任意一份的 `down -v` 只动它自己的状态。

> ⚠️ **两份栈同时跑还需要分配独立的 host 端口和子网**：`COMPOSE_PROJECT_NAME` 只隔离 Docker 对象，compose 文件依然 publish 同一组 host 端口（`OCTO_HTTP_PORT`、`OCTO_HTTPS_PORT`、`OCTO_MYSQL_PORT`、`OCTO_REDIS_PORT`、`OCTO_MINIO_API_PORT`、`OCTO_MINIO_CONSOLE_PORT`、`OCTO_WK_API_PORT`、`OCTO_WK_WS_PORT`、`OCTO_WK_TCP_PORT`、`OCTO_WK_MONITOR_PORT`、`OCTO_SUMMARY_API_PORT`）并使用同一默认 bridge 子网（`OCTO_NETWORK_SUBNET=172.28.0.0/24`）。两份栈同时 live 会以 port-bind / IPAM-overlap 错误失败，除非第二份的 `.env` 也覆盖每个 `*_PORT` 并把 `OCTO_NETWORK_SUBNET` 改成不重叠的 CIDR（例如 `172.29.0.0/24`）。如果用法是「同一时刻只跑一份、第二份 clone 只是 from-zero 验证」，那就 `docker compose stop`（**不要 `down -v`**）停下栈 #1 再起栈 #2，独立卷会保护各自数据。

### `docker compose down -v` 之前——先确认你要删的是什么

`down -v` 不可逆。先跑两个 probe，确认输出里全是你打算删的栈：

```bash
# 1. 列出要删的 Docker volume（必须都属于你的项目）
docker compose config --volumes        # 本文件声明的卷 key
# 用字面前缀（grep -F）pin 死你这份项目，不要用宽松的 `^octo([-_]|$)` 正则
# ——后者会匹配本机所有 OCTO 栈（`octo` / `octo-fz` / `octo-prod`...）。
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' docker/.env 2>/dev/null | cut -d= -f2)"
PROJECT="${PROJECT:-octo}"
docker volume ls --format '{{.Name}}' | grep -F "${PROJECT}_" # 磁盘上实际会动的卷

# 2. 列出 OCTO 命名空间下的容器（必须都属于你的项目）
docker ps --filter 'name=octo' --format '{{.Names}}'

# 3. 如果 (1) 或 (2) 里有不属于你的，就停下。设置
#    COMPOSE_PROJECT_NAME 为你那份的后缀再 check。注意 `docker ps`
#    本身**不读** COMPOSE_PROJECT_NAME（那是 `docker compose` 才消费
#    的环境变量），所以命令要么走 `docker compose ps`、要么直接用
#    项目名前缀过滤：
#       COMPOSE_PROJECT_NAME=octo-fz docker compose ps
#       docker ps --filter name=octo-fz
```

`setup.sh` 每次启动时也会跑等价检查，并在发现已有 OCTO 容器 / 卷时警告。默认 project name `octo` 在交互模式下会**强制**要求你确认；非交互模式下检测到冲突会直接 fatal，强制要求你 export 一个非默认 `COMPOSE_PROJECT_NAME` 再重试。

> 💡 **想干干净净跑 from-zero E2E，100% 安全的做法是用一台一次性 VM 或没有任何 OCTO 部署的主机。** `COMPOSE_PROJECT_NAME` 隔离能挡住 `down -v` 冲突，但一个 typo（把 `octo-fz` 打成 `octo`）就够把保护击穿。不确定就开台 throwaway 机器。

---

## 快速开始

### 前置清单

- Linux 或 macOS 主机，装好 `bash` ≥4、`openssl`，以及 Docker Compose v2 插件（`docker compose`）或 standalone `docker-compose` 二进制（在 `$PATH` 里）。
- Docker daemon 在跑，调用用户能直接 `docker info`（不需要 `sudo`）。
- **客户端流量只需要一个 TCP 端口对外开**：`28080`（nginx HTTP，`OCTO_HTTP_PORT`）。启用 HTTPS 后客户端端口变成 `28443`（`OCTO_HTTPS_PORT`）。其他所有端口（MinIO、MySQL、Redis、WuKongIM monitor、各服务直连 REST，以及 web/admin/WuKongIM API·TCP·WS）默认 loopback。WuKongIM 传输端口 `25001 / 25100 / 25200` 只在**原生 chat 客户端直连 WuKongIM** 时才需外露（覆盖 `OCTO_WK_TCP_BIND` / `OCTO_WK_WS_BIND`）；浏览器/SPA 的 chat 流量走 nginx `/ws`。
- ≥ 4 GiB RAM，≥ 10 GiB 空闲磁盘给 named volume。
- 出口网络能到 `docker.io`（或配置好的 mirror）拉镜像：`mininglamposs/*`、`mysql:8`、`redis:7-alpine`、`minio/minio`、`wukongim/wukongim`、`nginx:1.27-alpine`。
- **本机已经跑着另一份 OCTO 栈：** 先看上面那段前置警告，决定一个非默认的 `COMPOSE_PROJECT_NAME` 再继续。

推荐（交互式）：

```bash
git clone https://github.com/Mininglamp-OSS/octo-deployment.git
cd octo-deployment
./setup.sh                                  # 交互式向导
(cd docker && docker compose up -d --wait)  # subshell：保持在 repo 根目录
./setup.sh --verify                         # admin login + presign PUT 端到端检查
```

`setup.sh` 通过 `ifconfig.me` 自动探测公网 IP。如果主机有公网 IP（云 VM、有公网 IPv4 的裸金属），交互向导会把探测到的 IP 作为 `OCTO_DOMAIN` 的默认建议——有真正的 DNS 名时填进去，没有就直接用 IP 跑「纯 IP」部署。

非交互：

```bash
./setup.sh --non-interactive --domain octo.example.com --ip 1.2.3.4
(cd docker && docker compose up -d --wait)
./setup.sh --verify
```

启用可选的 LLM summary 服务加 `--summary`：

```bash
./setup.sh --summary --domain octo.example.com --ip 1.2.3.4
(cd docker && docker compose up -d --wait)
```

`setup.sh` 写出含轮换随机密钥的 `docker/.env` 和自动生成的 `OCTO_ADMIN_PWD`，并**在最后打印 admin URL + 密码**，免得你回头去 grep `.env`。这是从空 checkout 到 `(healthy)` 栈无需手改任何东西的唯一路径。

栈起来后，通过 nginx 访问：`http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`（默认 `http://octo.local:28080`）。继续用默认域名 `octo.local` 的话需要在客户端 `/etc/hosts` 里加一条解析。

### `setup.sh --verify` 自检命令

`docker compose up -d --wait` 报告所有服务 healthy 之后，跑自检命令确认**外部表面**确实能用：

```bash
./setup.sh --verify
```

脚本会探测（每步打印 PASS/FAIL）：

1. `docker compose ps` 没有 `(unhealthy)` 容器
2. nginx vhost up（`GET /_nginx_up`）
3. octo-server REST（`GET /api/v1/health`）
4. octo-matter（`GET /matter/health`）——**计入** 失败
5. 经 nginx 访问 MinIO（`GET /minio/health/live`）
6. admin SPA 可达（`GET /admin/`）
7. **admin 登录**（`POST /api/v1/manager/login`，用 `.env` 里的
   `OCTO_ADMIN_PWD` 以 `superAdmin` 身份）——验证 octo-server + MySQL +
   bcrypt + Redis 缓存这条链
8. **预签名 PUT 凭据签发**（`GET /api/v1/file/upload/credentials`）——
   验证 octo-server 的 MinIO IAM 凭据路径
9. **1 字节 PUT 到预签名 URL**——验证 nginx 原样转发 SigV4 路径以及
   MinIO 接受签名（双端口形态下 29000 被防火墙挡时图片消息静默丢失走
   的就是这条路径，见 OOTB-BUG-2026-05-17-001）。

任何步骤失败 exit code 非 0。`python3` 是 `--verify` 的**硬前置依赖**——
第 7-9 步（admin 登录、presign 签发、SigV4 PUT）用 `python3 -c 'import json'`
解析 JSON，过去 silently skip 它们正是 OOTB-BUG-2026-05-17-001 被掩盖的口子。
现在缺失 `python3` 会 fail-fast 非 0 退出；装上（所有 modern Linux 发行版
base image 都自带）再重跑。这是用来在新机器上确认「端到端真的能用」的
命令——区别于「容器起来了」。

第 9 步会在 `file` bucket 留下一个 1 字节哨兵对象
（`octo-verify-<timestamp>-<pid>.txt`）。这是故意留下的——本仓库使用
的 `minio/minio` 镜像 **不带** `mc` 客户端（`mc` 在独立的 `minio/mc`
镜像里，只被一次性的 `minio-init` 容器用到），所以
`docker exec <project>-minio-1 mc rm ...` 这种命令必然报
`mc: executable file not found`。每次 `--verify` 多 1 字节远低于噪声；
真要清干净请单独跑 `minio/mc` 镜像接入项目的 docker 网络，或者拿
`docker/.env` 里的管理员凭据直接调 MinIO S3 DELETE API。

### 卸载 / 重置

`setup.sh --uninstall` 子命令引导三档卸载粒度：

```bash
./setup.sh --uninstall
```

```
Pick teardown granularity:
  1) Full uninstall   — 停容器 + 删 named volume（数据全丢）
  2) Data-only reset  — 只删 named volume（容器下次 up 时重建）
  3) Containers only  — 停 + 删容器，保留 volume（安全重启准备）
  q) Quit
```

选项 1 是破坏性的——脚本会先打印要删的 volume 列表，要求你打 `YES` 才执行。选项 1 或 2 之前先确认 volume 属于你这份栈。**始终用字面项目前缀（`${COMPOSE_PROJECT_NAME}_`）来匹配，不要用宽松的 `^octo([-_]|$)` 正则**——后者会把本机所有 OCTO 栈（`octo`、`octo-fz`、`octo-prod` 等）一起捞出来，可能误删别人的卷。

```bash
# 从 docker/.env 读出你的项目名（setup.sh 写到那里）
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' docker/.env | cut -d= -f2)"
PROJECT="${PROJECT:-octo}"

# 只列出当前项目下会被删的卷
docker volume ls --format '{{.Name}}' | grep -F "${PROJECT}_"
```

**🟢 推荐：** 用 `./setup.sh --uninstall`——它会按 Compose 规范校验项目名、用字面前缀算出待删卷列表、列出预览、并强制 `YES` 确认。下面的手工 `docker compose` / `docker volume rm` 命令仅供已经清楚自己在拆哪份栈、又偏好原始工具的操作员参考。

手动等价（raw compose——先跑上面的项目名 probe）：

```bash
# 完全卸载（数据全丢，不可逆）
# `docker compose down -v` 只删本 compose project 声明的卷
# （从 docker/.env 里的 COMPOSE_PROJECT_NAME 解析），所以只要项目名
# 设对了，多份 OCTO 栈并存也是安全的。
cd docker && docker compose down -v --remove-orphans

# 只重置数据——保留镜像，仅删本项目的卷。
# 先 `compose down`，再按字面前缀删卷（grep -F，不是 -E，
# 这样 project name 是 `octo-fz` 时不会把 `octo-fz-prod_*` 也一起匹掉）。
PROJECT="$(grep -E '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2)"
PROJECT="${PROJECT:-octo}"
docker compose down
docker volume ls --format '{{.Name}}' \
  | grep -F "${PROJECT}_" \
  | xargs -r docker volume rm

# 只重启（保留 volume）
cd docker && docker compose down --remove-orphans
```

**⚠ 任何 `docker compose down -v` 之前**先看上面 [本机已有其他 OCTO 部署](#-前置本机已有其他-octo-部署的情况) 那段——同主机同 project name 的多份 OCTO 栈，任意一份的 `down -v` 都会清掉共享卷。

### 手动 setup（advanced）

只在你必须用自己的工具（Ansible、Vault…）来生成 env 文件时才跳过 `setup.sh`：

```bash
cp docker/.env.example docker/.env
# 编辑 docker/.env，轮换所有 placeholder：
#   MYSQL_ROOT_PASSWORD、MINIO_ROOT_PASSWORD、OCTO_MINIO_APP_PASSWORD、
#   OCTO_MATTER_DB_PASSWORD、OCTO_SUMMARY_DB_PASSWORD、
#   OCTO_SUMMARY_READER_PASSWORD、
#   OCTO_MASTER_KEY、OCTO_NOTIFY_INTERNAL_TOKEN、OCTO_WUKONGIM_MANAGER_TOKEN
# 设 OCTO_DOMAIN / OCTO_EXTERNAL_IP；如果要 auto-bootstrap superAdmin 也设 OCTO_ADMIN_PWD
# （详见 "First-admin bootstrap"）。

cd docker
docker compose config            # 启动前 validate
docker compose up -d --wait
docker compose ps                # 所有服务应到 (healthy)
```

完整变量契约见下面「必填环境变量」章节。

---

## 必填环境变量

栈起来之前**必须**改下面这些。默认值是设计成 fail-fast 的 placeholder：`OCTO_MASTER_KEY` 比 octo-server 的长度校验少一字节，`MINIO_ROOT_PASSWORD` 7 字符（MinIO 要求 ≥8）让 `minio` 容器拒绝启动，`minio-init` 一次性服务会拒绝任何 `CHANGE_ME_*` / `CHG_ME*`（大小写不敏感）的 MinIO root / app 凭据，`preflight` 一次性服务对 `OCTO_NOTIFY_INTERNAL_TOKEN` 和 `OCTO_WUKONGIM_MANAGER_TOKEN` 做同样校验，`init-extra-dbs.sh` 在 `MYSQL_ROOT_PASSWORD` 还是 `CHANGE_ME_*` / `CHG_ME*` placeholder、service-account 密码含 `[A-Za-z0-9._-]` 之外字符、`OCTO_MATTER_DB_PASSWORD` / `OCTO_SUMMARY_DB_PASSWORD` / `OCTO_SUMMARY_READER_PASSWORD` 仍然是字面默认（`matter` / `summary` / `summary_reader`）时全部拒绝。这些 check 加起来意味着——OOTB 栈不可能在 placeholder 凭据没换的情况下到达 `(healthy)`。

| 变量 | 含义 | 生成方式 |
| --- | --- | --- |
| `MYSQL_ROOT_PASSWORD` | MySQL `root` 密码（也会内嵌进 `TS_DB_MYSQLADDR` / `DM_MYSQL_DSN`；`init-extra-dbs.sh` 按 `[A-Za-z0-9._-]` 校验，避免 Go MySQL DSN parser 把 user/host 边界识别错；同时拒绝任何 `CHANGE_ME_*` / `CHG_ME*` 大小写形式） | `openssl rand -hex 16` |
| `MINIO_ROOT_PASSWORD` | MinIO root credential——`mc admin`、MinIO 控制台、`minio-init` bootstrap 用。**octo-server 不用**。`.env.example` 里 7 字符的 placeholder 会触发 MinIO 自己的 ≥8 长度校验；`minio-init` 再独立拒绝任何 `CHANGE_ME_*` / `CHG_ME*`（大小写不敏感）做纵深防御。 | `openssl rand -hex 16` |
| `OCTO_MINIO_APP_PASSWORD` | App-scoped IAM secret。octo-server **不用** root 对来签预签名 URL，而用这对。`minio-init` 在第一次启动时创建该 user、attach bucket-scoped policy，并在该值为空或仍是 `CHANGE_ME_*` / `CHG_ME*` placeholder 时显式 abort。 | `openssl rand -hex 24` |
| `OCTO_MATTER_DB_PASSWORD` | MySQL service account `matter`（在 `octo_matter` 上有完整 DML）。`init-extra-dbs.sh` 拒绝字面 `matter`。 | `openssl rand -hex 16` |
| `OCTO_SUMMARY_DB_PASSWORD` | MySQL service account `summary`（在 `octo_summary` 上有完整 DML）。`init-extra-dbs.sh` 拒绝字面 `summary`。 | `openssl rand -hex 16` |
| `OCTO_SUMMARY_READER_PASSWORD` | MySQL service account `summary_reader`（对 OCTO IM 库有 `SELECT`，见 `init-extra-dbs.sh` 里的 `GRANT` 块）。`init-extra-dbs.sh` 拒绝字面 `summary_reader`。 | `openssl rand -hex 16` |
| `OCTO_MASTER_KEY` | 32 字节 server master key | `openssl rand -hex 16` |
| `OCTO_NOTIFY_INTERNAL_TOKEN` | octo-server ↔ matter / smart-summary 之间共享的 HMAC secret。`preflight` 一次性服务拒绝任何 `CHANGE_ME_*` / `CHG_ME*` 大小写形式。 | `openssl rand -hex 32` |
| `OCTO_WUKONGIM_MANAGER_TOKEN` | WuKongIM admin token。WuKongIM 侧通过 `WK_MANAGERTOKEN`（Viper 自动绑到 YAML `managerToken`），octo-server 侧通过 `TS_WUKONGIM_MANAGERTOKEN`。空值会让 WuKongIM manager API 在无鉴权前提下可达**且可用**——`preflight` 同样拒绝 `CHANGE_ME_*` / `CHG_ME*`。 | `openssl rand -hex 32` |
| `LLM_API_KEY` | matter + smart-summary 用的 LLM provider key。这些功能必填。compose 文件为 `summary-worker` fallback 到一个假占位让 OOTB 栈能 `(healthy)`——但真正的 summarization 调用在你没设真 key 之前都会失败。 | 从 LLM 供应商处取得 |

其他变量都有合理默认，详见 [`docker/.env.example`](.env.example) 行内注释。

### Backing-service host bindings

`OCTO_MYSQL_BIND`、`OCTO_REDIS_BIND`、`OCTO_MINIO_API_BIND`、`OCTO_MINIO_CONSOLE_BIND` 默认 `127.0.0.1`。也就是说 MySQL（`23306`）、Redis（`26379`）、MinIO API（`29000`）、MinIO console（`29001`）**只能从主机 loopback 访问**。nginx 代理的路径（`/`、`/api/`、`/v1/`、`/admin/`、`/matter/`、`/summary/`、`/ws`，以及 bucket 路径 `/file|chat|moment|sticker|report|chatbg|common|download|group|avatar`）保持公开——注意 `/minio-console/` **不**在公开列表（见 "Network surface"）。

同样的 loopback 默认也适用于 `octo-server`（`OCTO_SERVER_BIND`）、`octo-matter`（`OCTO_MATTER_BIND`）、`smart-summary API`（`OCTO_SUMMARY_API_BIND`）和 WuKongIM monitor 端口（`OCTO_WK_MONITOR_BIND`）。前三个跳过 nginx vhost 对 `/api/`、`/v1/`、`/matter/`、`/summary/` 应用的 `octo_api` / `octo_auth` 限流，保留 loopback-only 避免操作员调试端口变成无限流生产路径。WuKongIM monitor 是 admin 表面，不是 chat 传输。

**用户入口（web / admin / WuKongIM TCP·WS）默认也是 loopback**：`OCTO_WEB_BIND`、`OCTO_ADMIN_BIND`、`OCTO_WK_API_BIND`、`OCTO_WK_TCP_BIND`、`OCTO_WK_WS_BIND` 全部默认 `127.0.0.1`。浏览器流量经 nginx `/`、`/admin/`、`/ws` 反代——单端口承诺由此成立。**WuKongIM 管理 API（5001 / host 25001）是内部 debug 接口，不挂在 nginx 上**（`docker/nginx/conf.d/octo.conf.template` 没有 manager-API location），OOTB 通过 `docker exec` 进 wukongim 容器访问；远程诊断用 `ssh -L 5001:127.0.0.1:25001 user@host`。仅当运行**原生 IM 客户端**（手机 / 桌面 app 直连 WuKongIM TCP 5100 或 WS 5200，不走 nginx `/ws`）才把 `OCTO_WK_TCP_BIND` / `OCTO_WK_WS_BIND` 改成 `0.0.0.0`，并在防火墙上额外开 `25100` / `25200`。详见英文版「Advanced: direct WuKongIM transports」。`OCTO_ADMIN_BIND` / `OCTO_WEB_BIND` / `OCTO_WK_API_BIND` 仅在**私网 / VPN 后**做短期直连诊断时才放开，事后立刻还原；管理 API 没有内置 auth gateway，不要在公网 IP 上放开。

只在**已轮换所有凭据 + 主机背后有防火墙**之后才覆盖 loopback 默认。**Redis 在本栈无密码运行**——`OCTO_REDIS_BIND` 留在 `127.0.0.1`（或私网接口）直到你给 redis 服务加上 `--requirepass`。完整流程见「Hardening checklist」。

---

## Network surface

OOTB 栈对**客户端流量是单端口**的。浏览器 / 移动客户端只需要够得着 nginx vhost 的 `OCTO_HTTP_PORT`（默认 `28080`）；其他所有（MinIO API、MinIO console、MySQL、Redis、WuKongIM monitor，以及 octo-server / matter / summary-api 的直连 REST 端口）默认 loopback。**运维只需要在防火墙上开一个 TCP 端口（28080）。**

| 服务 | 端口（默认） | 默认 bind | 说明 |
| --- | --- | --- | --- |
| **nginx (HTTP)** | **`28080`** | **`0.0.0.0`** | **用户入口——唯一对外开的端口** |
| nginx (HTTPS) | `28443`（placeholder） | `0.0.0.0` | HTTPS 形态；默认未启用——见下面 "HTTPS 形态" |
| octo-admin | `28082` | `127.0.0.1` | admin SPA——经 nginx `/admin/` 访问。直连端口默认 loopback，admin UI 不会在公网 IP 上裸奔。仅在私网 / VPN 后做诊断时 `OCTO_ADMIN_BIND=0.0.0.0`。 |
| octo-web | `28083` | `127.0.0.1` | user SPA——经 nginx `/` 访问。直连端口默认 loopback。仅在诊断时 `OCTO_WEB_BIND=0.0.0.0`。 |
| WuKongIM API | `25001` | `127.0.0.1` | **内部 manager / debug API——不挂在 nginx 上**。`docker/nginx/conf.d/octo.conf.template` 没有 manager-API location，OOTB 只能从 host loopback 访问。诊断用 `docker exec -it <wukongim-container> sh`；远程访问用 `ssh -L 5001:127.0.0.1:25001 user@host` 后访问 `http://localhost:5001/`。仅在私网 / VPN 且前置 auth proxy 后再 `OCTO_WK_API_BIND=0.0.0.0`——管理 API 自身没有 token gateway。 |
| WuKongIM TCP | `25100` | `127.0.0.1` | **原生 IM 传输**——仅在原生 chat 客户端（手机/桌面 app 直连 WuKongIM）时需要。改法：`.env` 设 `OCTO_WK_TCP_BIND=0.0.0.0` + 防火墙开 `25100`。浏览器走 nginx `/ws`，不需要这步。 |
| WuKongIM WS | `25200` | `127.0.0.1` | 直连 WebSocket——同上原生客户端故事。`OCTO_WK_WS_BIND=0.0.0.0` 启用。 |
| octo-server REST | `28081` | `127.0.0.1` | 操作员 smoke-test 用直连 REST 端口；生产流量走 nginx `/api/` + `/v1/`（带 `octo_api`/`octo_auth` 限流）。`OCTO_SERVER_BIND` 覆盖。 |
| octo-matter | `28086` | `127.0.0.1` | matter 直连端口；生产流量走 nginx `/matter/`。`OCTO_MATTER_BIND` 覆盖。 |
| smart-summary API | `28087` | `127.0.0.1` | summary-api 直连端口；生产流量走 nginx `/summary/`。`OCTO_SUMMARY_API_BIND` 覆盖。 |
| WuKongIM monitor | `25300` | `127.0.0.1` | 可观测性 / `/route` admin 表面——不是用户传输。 |
| MinIO API | `29000` | `127.0.0.1` | **单端口形态**：对象流量走 nginx bucket-name 路由（`/{bucket}/{key}`）。仅在双端口 advanced override 时才把 `OCTO_MINIO_API_BIND` 放开（见下方）。 |
| MinIO console | `29001` | `127.0.0.1` | 仅管理员；通过 SSH 隧道访问（见下文） |
| MySQL | `23306` | `127.0.0.1` | backing service |
| Redis | `26379` | `127.0.0.1` | backing service |

MinIO console 默认**不**通过 nginx 暴露。早期版本曾把它放在 `/minio-console/`，结果 MinIO admin login 离公网入口只差一次点击——配合 placeholder root 密码就能直接登。运维通过 SSH 隧道访问 loopback bind：

```bash
ssh -L 9001:127.0.0.1:29001 user@host
# 然后浏览器打开 http://localhost:9001
```

如要重新开放公网路由（**不推荐**；仅在轮换 `MINIO_ROOT_PASSWORD` 并加上 auth 之后），取消注释 `docker/nginx/conf.d/octo.conf.template` 顶部的 `octo_minio_console` upstream 和 `/minio-console/` location 块。

### 为什么单端口对 MinIO 预签名 URL 也能成立

octo-server 的 `/api/v1/file/*` 响应里带的是**预签名（SigV4）URL**。SigV4 对 canonical request path 签名，任何 nginx 路径 rewrite 都会破坏签名——但本 nginx 配置**不做** rewrite。`docker/nginx/conf.d/octo.conf.template` 里的 bucket-name 正则 location：

```nginx
location ~ ^/(file|chat|moment|sticker|report|chatbg|common|download|group|avatar)/.+ {
    proxy_pass http://octo_minio_api;   # 无 trailing slash —— 保留 SigV4 path
    proxy_set_header Host $http_host;
    ...
}
```

把 `/{bucket}/{key}` 原样转发到 MinIO。客户端对 `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/{bucket}/{key}` 签名，MinIO 也用同一条 canonical path 验签。`TS_MINIO_DOWNLOADURL`（octo-server 侧）和 `MINIO_SERVER_URL`（MinIO 侧）都默认 `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`，两端保持一致。

数据安全靠：

- **App-scoped IAM 凭据**（`OCTO_MINIO_APP_*`，octo-server 用它签名）——`minio-init` 一次性服务 provision。这对凭据只允许 bucket 白名单上的读/写/删，**不**给 `mc admin` / IAM / console 权限，MinIO root 对始终不会出现在 octo-server 环境里。
- 每个预签名 URL 的**短 TTL**（分钟级，不是天级），
- octo-server 在 `/api/v1/file/*` 前的鉴权层。

nginx 里还保留一个仅供诊断的 `/minio/` location（如 `curl http://host:28080/minio/health/live`），**不**用于客户端对象流量。

### 双端口 advanced override

之前的双端口形态——客户端直接走 `OCTO_MINIO_API_PORT`（29000）访问 MinIO——对希望这么用的运维（从别的主机做 sidecar 诊断、对象吞吐高想跳过 nginx 等）仍可用。改法：

```bash
# 在 docker/.env 里
OCTO_MINIO_API_BIND=0.0.0.0
TS_MINIO_DOWNLOADURL=http://<your-host>:29000
MINIO_SERVER_URL=http://<your-host>:29000
```

然后在防火墙上同时开 `28080` 和 `29000`。单主机部署没有架构理由这么做，单端口默认形态是推荐路径。

### HTTPS 形态（TLS 终结）

`OCTO_HTTPS_PORT`（默认 `28443`）是**单端口 + TLS** 形态的占位变量。证书装载流程**未**自动化——见 [`docker/certs/README.md`](certs/README.md) 里手动步骤（Let's Encrypt 或自签）。证书到位后，取消注释 `docker-compose.yaml` 里的 443 端口映射、certs volume mount，以及 `docker/nginx/conf.d/octo.conf.template` 里的 HTTPS server 块。仍然是单端口故事——客户端只需 `OCTO_HTTPS_PORT` 开放；MinIO 流量还是经 nginx bucket-name 路由在 TLS 下传输。

> ⚠️ **启用 HTTPS 必须同时覆盖三个 URL 变量**——compose 默认把
> `MINIO_SERVER_URL` / `TS_MINIO_DOWNLOADURL` / `TS_EXTERNAL_BASEURL`
> 都展开成 `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`。nginx 的 HTTPS
> server 块只在前面终结 TLS，但 octo-server 仍然按上述三个变量给客户端
> 返回**绝对 URL**（presigned MinIO PUT/GET、admin 响应里的 baseURL 等）。
> 不覆盖就会让客户端拿到 `http://…:28080` 的 URL，要么报 mixed-content，
> 要么直接退化到 HTTP listener。在 [YUJ-984](https://github.com/Mininglamp-OSS/octo-deployment/issues)（`OCTO_PUBLIC_SCHEME`
> 自动推导）落地之前，请在 `docker/.env` 里显式设置这三个值：
>
> ```bash
> # docker/.env —— 启用 HTTPS server block 时必须设置
> MINIO_SERVER_URL=https://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}
> TS_MINIO_DOWNLOADURL=https://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}
> TS_EXTERNAL_BASEURL=https://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}
> ```
>
> 注意 `.env` 不做 `${...}` 二次插值——上面三个值要替换成解析后的字面字符串
> （例如 `https://octo.example.com:28443`）。三个值的 scheme + host + port
> 必须一致：SigV4 是对这个完整 URL 签名的，octo-server 在启动时也会校验
> `TS_MINIO_DOWNLOADURL` 只能是 host:port（不能带 path 前缀）。如果希望客户端
> 走 wss，把 `OCTO_WK_WSS_ADDR` 也指向 `wss://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}/ws`。

### 在 host nginx 后做 TLS 终结（不同 hostname）

如果用一台**主机** nginx（不是栈内那台）做 TLS 终结，把 `https://your.host/` 反代回栈的 `OCTO_HTTP_PORT`，需要把两个变量都指向公网 host：

```
MINIO_SERVER_URL=https://your.host
TS_MINIO_DOWNLOADURL=https://your.host
```

两个值必须**同一 scheme + host:port**（不带 path——`TS_MINIO_DOWNLOADURL` 在 octo-server 启动时被校验为 host:port-only）。栈内 nginx 的 bucket-name 正则 location 仍会把 `/{bucket}/{key}` 路由到 MinIO；确保 host nginx 把这些路径透传过来即可。

---

## MinIO bootstrap & 凭据范围

本栈带的 `octo-server` MinIO 客户端**不是** MinIO root 用户。第一次启动时，`minio` healthy 后 `minio-init` 一次性服务依次：

1. 创建 `OCTO_MINIO_APP_USER` 指定的 IAM 用户（默认 `octo-app`），密码取 `OCTO_MINIO_APP_PASSWORD`。
2. （重新）安装 `octo-app` policy（[`docker/configs/minio-octo-app-policy.json`](configs/minio-octo-app-policy.json)），授予 octo-server 用的 bucket 白名单（`file`、`chat`、`moment`、`sticker`、`report`、`chatbg`、`common`、`download`、`group`、`avatar`）上的 `s3:GetObject`/`PutObject`/`DeleteObject`/multipart actions 加 `s3:ListBucket`。**故意不给** `s3:CreateBucket`、`mc admin`、console、IAM 控制权限。
3. 给 `octo-app` 用户 attach 该 policy。
4. 预创建每个白名单 bucket，让第一次 `/api/v1/file/upload` 调用不依赖 app user 有 bucket admin 权限。
5. 给**内容** bucket 设 `anonymous download`，让 SPA 能直接渲染 `<img src=…>`（上传还是走签名 PUT）：

   > ⚠️ **安全权衡**：下面这些内容 bucket 变成**通过 URL 匿名可读**。这是 OCTO web 的 `<img src>` 模型（SPA 直接 embed `getUploadCredentials` 返回的未签名 `downloadUrl`——CDN 风格，跟主流 IM app 一样），但意味着图片 URL 一旦签发就永远全网可读。`s3:ListBucket` 仍 deny、对象 key 是高熵 UUID（无法枚举），但谁看到 chat-image URL 谁就能 fetch。删聊天消息也不会 GC 底下的 MinIO 对象。完整威胁模型见 PR#22 描述；切换到 signed GET 的跟踪 issue 待 octo-web 支持后做。

   | Bucket    | 匿名 policy | 用途 |
   |-----------|-------------|------|
   | `chat`    | `download`  | 聊天面板里的图片 / 文件消息 |
   | `file`    | `download`  | 通用文件附件 |
   | `moment`  | `download`  | moments 信息流媒体 |
   | `sticker` | `download`  | sticker 缩略图 |
   | `chatbg`  | `download`  | 聊天背景图 |
   | `common`  | `download`  | 共享静态资源 |
   | `avatar`  | `download`  | 用户 / 群头像 |
   | `report`  | *private*   | 审计报表——必须签名 |
   | `group`   | *private*   | 群导出——必须签名 |
   | `download`| *private*   | 服务端 stage 的下载——必须签名 |

   写入仍受 `octo-app` IAM policy 约束；匿名只能 GET。`mc anonymous set download` 是幂等的，重新跑 `docker compose up -d` 安全。

之后 `octo-server` 只用 app 凭据跑——root 凭据只活在 `minio-init` 这一处、`mc` CLI 路径，和 console 里。`octo-server` 环境 / config-map / 日志泄露最多给攻击者 bucket 级数据访问权限，不会让对方加用户、改 root 或接管集群。

轮换 app 密码：

```bash
# 1. docker/.env 里设新值
sed -i 's/^OCTO_MINIO_APP_PASSWORD=.*/OCTO_MINIO_APP_PASSWORD=<new>/' docker/.env
# 2. 重跑栈 —— minio-init 幂等，会重置 secret；octo-server 下一次 env render 自动取到
docker compose up -d
```

轮换 policy 本身，编辑 `docker/configs/minio-octo-app-policy.json` 然后 `docker compose up -d` —— policy 已存在时 `minio-init` 会调 `mc admin policy update`。

---

## 首位 admin 启动

`register.off: true` 是 OSS 默认——禁止公开注册，本栈也没有 SMS 验证 fallback。所以首位 admin 必须 out-of-band 创建。

下面两条是当前 octo-server 二进制实际生效的路径。早期文档提过的 `OCTO_BOOTSTRAP_ADMIN_*` env 和 `octo-server admin hash-password` CLI 子命令今天的二进制里**都不存在**。除非有强理由选 B，否则用 A。

### 选项 A · `adminPwd` config-driven bootstrap（推荐）

octo-server 有一个跟 `adminPwd` config key 绑定的内建首位 admin 钩子。启动时如果 `account.adminUID`（默认 `"admin"`）的 user 行尚不存在且 `adminPwd` 非空，就会插入一行 `superAdmin`：`username = "superAdmin"`、`role = "superAdmin"`、`password = bcrypt(adminPwd)`。该钩子在每个 database 上是 one-shot——行存在后即使 `adminPwd` 仍设着，后续 restart 也 no-op，所以留着该值是安全的。

用法：

1. 选一个强密码（当 deploy-time secret 对待——octo-server 写入前 bcrypt 一次，但明文留在你的 `.env` 里）。
2. 写到 `docker/.env`。`TS_ADMINPWD` 默认就已经在 `docker-compose.yaml` 的 `octo-server` 服务上连好——当 `OCTO_ADMIN_PWD` 非空时 octo-server 第一次启动就种下这一行。留 `OCTO_ADMIN_PWD` 空（或注释）会跳过 auto-bootstrap，改走选项 B 手动建：

   ```bash
   # docker/.env
   OCTO_ADMIN_PWD=<强密码>
   ```

   ```yaml
   # docker/docker-compose.yaml —— octo-server 服务 environment（已存在）：
   TS_ADMINPWD: ${OCTO_ADMIN_PWD:-}
   ```

   `setup.sh` 自动生成随机 `OCTO_ADMIN_PWD`，并在运行末尾打印一次。
3. `docker compose up -d`（或栈已起的话 `docker compose restart octo-server`）。第一次启动 user 表为空时 octo-server 种下该行。
4. 访问 `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/admin/`，用 `superAdmin` 加 step 1 的密码登录。
5. 从 admin UI 改密码并从 `.env` 删掉 `OCTO_ADMIN_PWD`。（种下的那行从此是 source of truth；`adminPwd` config key 只在该行不存在时才被查阅。）

### 选项 B · 手动 SQL seed

在你不能改 `docker-compose.yaml` 或想用非默认 username / UID 时用这个。schema 在 `octo-server/modules/user/sql/20191106000003_user_legacy01.sql`（相关字段：`uid`、`username`、`name`、`password`、`role`、`status`）。

```bash
# 1. 主机上生成 bcrypt hash（cost ≥ 10）：
HTPASSWD_HASH=$(htpasswd -bnBC 10 "" '<你的密码>' | tr -d ':\n')
# 或 Python：
#   python3 -c 'import bcrypt; print(bcrypt.hashpw(b"<pw>", bcrypt.gensalt(10)).decode())'

# 2. 插入 user 行。role 必须是字符串 'superAdmin' 或 'admin'
#    —— 该字段是 VARCHAR(40)，不是 int enum。
docker compose exec mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" octo <<SQL
INSERT INTO \`user\`
  (uid, username, name, password, role, status, created_at, updated_at)
VALUES
  ('admin', 'superAdmin', 'OCTO Admin', '${HTPASSWD_HASH}', 'superAdmin', 1, NOW(), NOW());
SQL
```

然后 `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/admin/` 用 `superAdmin` 加你刚 hash 的密码登录。

> 占位 UID `'admin'` 对应 `account.adminUID` 的默认值。如果改了 `octo-server.yaml` 里的 `account.adminUID`，这里也用对应值，保证 A 的 re-seed 钩子和手动行一致。

---

## Hardening checklist

把栈对外暴露之前：

- 把 `.env` 里所有 `CHANGE_ME_*` / `CHG_ME*` 都轮换。`OCTO_MASTER_KEY` 故意短一字节让 octo-server 长度校验拒绝；`MINIO_ROOT_PASSWORD` 7 字符触发 MinIO ≥8 校验；`minio-init` 独立拒绝任何 `CHANGE_ME_*` / `CHG_ME*`（大小写不敏感）的 MinIO 凭据对；`preflight` 拒绝 `OCTO_NOTIFY_INTERNAL_TOKEN` 和 `OCTO_WUKONGIM_MANAGER_TOKEN` 的 `CHANGE_ME_*` / `CHG_ME*` 大小写形式；`init-extra-dbs.sh` 在第一次 MySQL volume init 时拒绝 `MYSQL_ROOT_PASSWORD` 是 `CHANGE_ME_*` / `CHG_ME*`、service-account 密码含 `[A-Za-z0-9._-]` 之外字符、或者三个 MySQL service-account 密码（`OCTO_MATTER_DB_PASSWORD`、`OCTO_SUMMARY_DB_PASSWORD`、`OCTO_SUMMARY_READER_PASSWORD`）仍是字面默认。OOTB 栈不再可能在 placeholder 凭据没换的情况下起来。
- `OCTO_MYSQL_BIND` / `OCTO_REDIS_BIND` / `OCTO_MINIO_API_BIND` / `OCTO_MINIO_CONSOLE_BIND` 保持 `127.0.0.1`。轮换凭据并加防火墙之后才覆盖。
- Redis 在本栈**无密码运行**——`redis` 服务 `command:` 里没有 `--requirepass`。把 `OCTO_REDIS_BIND` 改成 `0.0.0.0` 就会暴露无鉴权 Redis。改 bind 之前要么把 Redis 留在私网接口，要么给 `redis` 服务 `command:` 加 `--requirepass <secret>` 并把同一 secret 写到 `octo-server` 服务的 `TS_DB_REDISPASS` / `DM_REDIS_PASS` 让应用还能到 cache。（加 CLI-flag 驱动的 Redis 密码作为 follow-up；见 PR description。）
- MinIO console 是 loopback-only 且默认**不**通过 nginx 代理。通过 SSH 转发 `:29001`（见 "Network surface"）访问。如果你取消注释了 `nginx/conf.d/octo.conf.template` 里的 `/minio-console/` 块，先轮换 `MINIO_ROOT_PASSWORD`——否则公网 `OCTO_HTTP_PORT` 就是通往 `mc admin` 的路径。
- `OCTO_MINIO_API_BIND` 在单端口默认下是 `127.0.0.1`——客户端对象流量走 nginx bucket-name 路由。只有显式选了双端口 advanced override 才放开（见 Network surface · 双端口）。
- 进一步收窄 `OCTO_NETWORK_SUBNET`（已默认 `/24`）——如果跟现有 VPN / VPC 范围重叠。
- `OCTO_MASTER_KEY` 轮换坑：master key 是 octo-server 用来 AEAD 加密 at-rest 字段（server config 里 reference 的 per-user / per-tenant 加密素材）的。数据写入后再轮换会让之前加密的行无法解密——没有内建 re-encrypt pass。所以正确流程是首次部署选一个强 key（`openssl rand -hex 16`）固定不动，仅作为 full reset（drop 加密列 / re-onboard 用户）或协调好的迁移的一部分才换。这条仅适用于 `OCTO_MASTER_KEY`；`OCTO_NOTIFY_INTERNAL_TOKEN` 和 `OCTO_WUKONGIM_MANAGER_TOKEN` 是 HMAC-only，重启所有依赖服务即可安全轮换。
- 给 `OCTO_WUKONGIM_MANAGER_TOKEN` 设真值。WuKongIM 的 `tokenAuthOn` 在 `wk.yaml` 里是 `true`，但 token 通过 env `WK_MANAGERTOKEN` 绑定（Viper 自动把大写 `WK_<KEY>` 绑到 YAML key）。该 env 为空时，WuKongIM **和** octo-server 都会 short-circuit token 对比、接受任意字符串——manager API 在无 auth 前提下可达**且可用**，跟这一行文字曾经暗示的「安全默认」相反。wukongim 镜像 pin 到一个具体 release（`v2.2.4-20260313`）就是为了让 env 契约稳定；如果 bump `OCTO_WK_IMAGE`，要重新验证 `WK_MANAGERTOKEN` 是否仍然绑定、`tokenAuthOn: true` 是否在新 tag 上被拒。
- 接受入站 webhook 时设 `OCTO_WEBHOOK_SECRET_KEY`。
- 把 `OCTO_DOMAIN` 改成真域名并前置 TLS（取消注释 `docker-compose.yaml` 里 `443` 块和 `nginx/conf.d/octo.conf.template` 里 HTTPS server 块）。
- 等 `Mininglamp-OSS/octo-server#24` 里的 PresignedPutter fix 发 release 后，把每个 `mininglamposs/octo-*` 镜像 pin 到具体 tag。compose 文件目前对 `octo-server`、`octo-web`、`octo-admin`、`octo-matter` 和 smart-summary 镜像默认 `:latest`——笔记本上行，稳定部署不行。WuKongIM 和 `mc` 已经 pin。

---

## 故障排查

### `docker compose up` 报端口冲突

在 `.env` 里挑别的 host 端口——每个后端服务端口（`OCTO_MYSQL_PORT`、`OCTO_REDIS_PORT`、`OCTO_MINIO_API_PORT`…）和每个对外端口（`OCTO_HTTP_PORT`、`OCTO_SERVER_PORT`、`OCTO_ADMIN_PORT`、`OCTO_WEB_PORT`、`OCTO_MATTER_PORT`、`OCTO_SUMMARY_API_PORT`、`OCTO_WK_*_PORT`）都可以覆盖。

### nginx 显示默认 Welcome 页而不是 OCTO

`docker/nginx/empty-default.conf` 被挂在镜像里 `default.conf` 之上，让 OCTO vhost 胜出。如果你定制了 nginx mount，确保这个覆盖还在。

### `octo-server` 或 `wukongim` 重建后 nginx 502 直到 reload

随栈带的四个核心 upstream（`octo_api`、`octo_ws`、`octo_minio_api` → `octo-server` / `wukongim`）故意保留 `upstream {}` 块好让 nginx keepalive 池在稳态流量下不断。代价是 nginx 只在 worker 启动时解析一次主机名并缓存 IP——所以针对性的 `docker compose up -d --force-recreate octo-server` 或 `--force-recreate wukongim`（镜像 bump、配置改、IM-server 版本 pin 等）会让 nginx 一直路由到死 IP 直到 worker 被弹一次。

叶子 upstream（`admin`、`web`、`matter`、`summary-api`）用 variable + Docker DNS resolver 方案、自己能恢复。对那四个核心 upstream，重建 `octo-server` 或 `wukongim` 之后跑：

```bash
docker compose exec nginx nginx -s reload
```

reload 是在线的（不断连接），<1s。整栈通过 `docker compose up -d`（不带 `--force-recreate`）重启时不需要——nginx 跟着依赖一起重建并在 boot 时重新解析。

### 图片上传返回 500 / "PresignedPutter is nil"

OCTO 图片上传依赖 [`Mininglamp-OSS/octo-server#24`](https://github.com/Mininglamp-OSS/octo-server/issues/24) 里的 PresignedPutter 实现。把 `OCTO_SERVER_IMAGE` pin 到包含该 fix 的 commit（fix 发版后用 `:latest`）。

### 预签名 URL 访问 "connection refused" / 名称解析失败

症状：`/api/v1/file/*` 返回 200 的图片 / 文件上传成功后，浏览器在 fetch 预签名 URL 时挂死或 0 字节，**或者**聊天界面显示 `[图片]` chip 但接收方收到空气泡。

单端口形态（默认）下，预签名 URL 指向 nginx vhost（`${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`），bucket-name 正则 location 转发到 MinIO。按顺序检查：

1. 客户端网络能到 `OCTO_HTTP_PORT`（默认 `28080`）——`curl -v http://${OCTO_DOMAIN}:28080/_nginx_up` 应返回 `200`。
2. 客户端能解析 `${OCTO_DOMAIN}`（继续用 `octo.local` 的话，每台访问 UI 的机器都要有 `/etc/hosts` 条目，不只是 server 自己）。
3. `TS_MINIO_DOWNLOADURL` 和 `MINIO_SERVER_URL` 一致——都应默认 `http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`（无 path 前缀）。验证：`docker compose config | grep -E '(TS_MINIO_DOWNLOADURL|MINIO_SERVER_URL)'`。octo-server 在启动时拒绝带 path 前缀的 download URL。
4. nginx 配置里 bucket-name 正则 location 还在：`docker/nginx/conf.d/octo.conf.template` 中 `^/(file|chat|moment|sticker|report|chatbg|common|download|group|avatar)/.+`。如果你定制了 nginx，确认这一块没被删。

如果显式选了 legacy 双端口形态（`OCTO_MINIO_API_BIND=0.0.0.0` + `TS_MINIO_DOWNLOADURL=...:29000`），还要确认客户端网络能到 TCP `29000`。单端口形态**不需要**开 `29000`。

**不要**通过加 nginx rewrite 来 "修"（把 `/{bucket}/` 从 URI 里 strip 出来）—— SigV4 签名在任何路径 rewrite 下都会破。见上面 "为什么单端口对 MinIO 预签名 URL 也能成立"。

### `WuKongIM /route` 返回字面字符串 `${OCTO_DOMAIN}`

Compose 只插值 `.env` 一次——**不**会递归展开 `.env` 值里的 `${...}`。`OCTO_WK_WS_ADDR=` 留空让 `docker-compose.yaml` 里默认表达式从 `OCTO_DOMAIN` / `OCTO_HTTP_PORT` 拼地址。只在想覆盖自动拼出来的默认值时设字面值（如 `ws://1.2.3.4:28080/ws`）。

### MySQL 启动报 "ERROR 1396 (HY000): Operation CREATE USER failed"

`scripts/init-extra-dbs.sh` 只在第一次 volume init 时跑。如果已经用错密码启过：

```bash
docker compose down -v        # 删 mysql-data
# 改 .env 里密码
docker compose up -d
```

不能 drop volume 的话，直接对 live 容器跑手动 SQL——`scripts/init-extra-dbs.sh` 末尾就是 `CREATE USER` / `GRANT` 语句。

### Health 端点

栈报告 healthy 之后，默认（无 summary）部署下面这些都应返回 200：

| Path | 用途 |
| --- | --- |
| `/_nginx_up` | nginx 反代 probe |
| `/api/v1/health` | octo-server REST |
| `/matter/health` | octo-matter |
| `/` | octo-web SPA |

```bash
for p in /_nginx_up /api/v1/health /matter/health /; do
  printf '%-22s %s\n' "$p" "$(curl -fsS -o /dev/null -w '%{http_code}' "http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}$p")"
done
```

启用了 summary profile（`./setup.sh --summary` 或 `.env` 里 `COMPOSE_PROFILES=summary`）的话也 probe `/summary/health`：

```bash
curl -fsS "http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}/summary/health"
```

未启用 summary profile 时 `summary-api` 容器不启动，所以 `/summary/health` 通过 nginx 会 502——这是预期，不是 failure。

`summary-worker` 容器没有 public route——`/internal/healthz` 只在 `octo-net` 网络内 8082 端口提供。docker healthcheck 走的那个路径主机访问不到。要显式验证 worker（覆盖 `LLM_API_KEY` / `MYSQL_DSN` 验证，否则只会表现为卡在 `(starting)`）：

```bash
docker compose exec summary-worker \
  wget -qO- http://localhost:8082/internal/healthz
docker compose ps summary-worker   # 期望 (healthy)
```

容器卡 `(unhealthy)` / 重启的话，看 `docker compose logs summary-worker | tail -50` 找 `required environment variables not set`——OOTB 最常见原因是空 `LLM_API_KEY` 加上 `OCTO_SUMMARY_WORKER_IMAGE` pin 在 placeholder fallback 之前的版本。

---

## 目录结构

```
docker/
├── docker-compose.yaml       # 完整服务编排
├── .env.example              # 带注释的 env 模板
├── README.md                 # 英文文档
├── README.zh.md              # 本文（中文）
├── configs/
│   ├── octo-server.yaml      # mount 到 /home/configs/tsdd.yaml
│   ├── wk.yaml               # WuKongIM 运行时配置
│   └── minio-octo-app-policy.json  # minio-init 安装的 IAM policy
├── nginx/
│   ├── nginx.conf            # gzip + 主 http 块
│   ├── empty-default.conf    # 静默 nginx welcome vhost
│   └── conf.d/
│       └── octo.conf.template
└── scripts/
    └── init-extra-dbs.sh     # 一次性 MySQL bootstrap（matter / summary）
```

## 不在 scope 内

compose 文件**不**覆盖：clustering / HA、自动 TLS provisioning、log shipping、备份。生产部署用 kustomize overlay。
