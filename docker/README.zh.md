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
sudo ./setup.sh --up                               # 起栈
sudo ./setup.sh --smoke-test                       # 端到端自检（admin 登录 + 文件预签名 PUT）。旧名 --verify 仍可用（deprecated）。

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
- **客户端流量只需要一个 TCP 端口对外开**：`28080`（nginx HTTP，`OCTO_HTTP_PORT`）。启用 HTTPS 后客户端端口变成 `28443`（`OCTO_HTTPS_PORT`）。其他所有端口（MinIO、MySQL、Redis、WuKongIM monitor、各服务直连 REST，以及 web/admin/WuKongIM API·TCP·WS）默认 loopback。WuKongIM 原生 chat 传输端口 `25100`（TCP）/ `25200`（WS）只在**原生 chat 客户端直连 WuKongIM** 时才需外露（覆盖 `OCTO_WK_TCP_BIND` / `OCTO_WK_WS_BIND`）；浏览器/SPA 的 chat 流量走 nginx `/ws`。WuKongIM 管理 API `25001` 是 admin / debug 接口（不是 chat 传输），任何客户端形态下都建议保持 loopback——见下面的网络端面表。
- ≥ 4 GiB RAM，≥ 10 GiB 空闲磁盘给 named volume。
- 出口网络能到 `docker.io`（或配置好的 mirror）拉镜像：`mininglamposs/*`、`mysql:8`、`redis:7-alpine`、`minio/minio`、`wukongim/wukongim`、`nginx:1.27-alpine`。
- **本机已经跑着另一份 OCTO 栈：** 先看上面那段前置警告，决定一个非默认的 `COMPOSE_PROJECT_NAME` 再继续。

推荐（交互式）：

```bash
git clone https://github.com/Mininglamp-OSS/octo-deployment.git
cd octo-deployment
./setup.sh                                  # 交互式向导
sudo ./setup.sh --up                        # 起栈
sudo ./setup.sh --smoke-test                # admin login + presign PUT 端到端检查（旧名 --verify 仍可用，已 deprecated）
```

`setup.sh` 通过 `ifconfig.me` 自动探测公网 IP。如果主机有公网 IP（云 VM、有公网 IPv4 的裸金属），交互向导会**打印**探测到的 IP 供参考，但 `OCTO_DOMAIN` 的**默认值是 `localhost`**（回车 = 仅在本机访问）。只有当你确实要让栈对外可达时，才在 prompt 里手动输入探测到的 IP，或者输入一个客户端能解析的真实 DNS 名。

非交互：

```bash
./setup.sh --non-interactive --domain octo.example.com --ip 1.2.3.4
sudo ./setup.sh --up
sudo ./setup.sh --smoke-test
```

或者，在全新机器上想最快跑通三步，把步骤 1 `--non-interactive` 跑、再接 start-only 的 `--up`（R6 / GH#33 引入，R8 / GH#43 加固契约）——`--up` 自己起栈，**阻塞直到每个长跑服务都 `(healthy)`、每个一次性 init job（`preflight`、`minio-init`）干净退出**。超时或启动失败时打印 `compose ps`、列出具体出问题的服务名、对每个失败服务给一条 `logs <svc>` 排查命令，然后 exit 1。`--up` 永远不会改写/重新生成步骤 1 写出的 `.env` 中的密钥（只会 `chown root:root` + `chmod 600`，做 owner/权限收紧），它是 start-only 子命令；如果 `docker/.env` 不存在，`--up` 会直接 exit 1 并给出具体的补救命令，**绝不会**默默重新生成密钥：

```bash
./setup.sh --non-interactive --ip 1.2.3.4         # 步骤 1：gen .env，不提示，无需 sudo
sudo ./setup.sh --up                              # 步骤 2：启栈（start-only）
sudo ./setup.sh --smoke-test                      # 步骤 3：端到端 verify
```

如果确实想用单条命令同时完成 bootstrap + 启栈（**会生成新密钥**——绝对不要在已经在生产里跑的 `.env` 主机上用），必须显式传 `--up --force`：

```bash
sudo ./setup.sh --non-interactive --ip 1.2.3.4 --up --force   # 显式 one-shot bootstrap
```

不带 `--force` 时，`docker/.env` 缺失就是 fatal——这是 R8（PR#36 Jerry-Xin CR）修的契约一致性问题：「`--up` 永远不会重新生成密钥」从「文档承诺」升级为「代码强制」。

`--up` 底层调 `docker compose up -d --wait --wait-timeout 240`（Compose < v2.20 上自动 fallback 到手动 health poll）。soft timeout 时 wrapper 自动重试一次（缓存已热，第二次通常 <10s），最坏情况是 2 × 240s。等待期间每 5 秒打一个 `.`，方便操作者看到脚本还活着——慢主机上 MySQL 冷启动可能要 60-90 秒。

启用可选的 LLM summary 服务加 `--summary`：

```bash
./setup.sh --summary --domain octo.example.com --ip 1.2.3.4
sudo ./setup.sh --up
```

启用可选的消息搜索流水线（Kafka + OpenSearch + es-indexer）加 `--search`
（它会写入 `COMPOSE_PROFILES=search`，与 `--summary` 同时给出时自动合并）：

```bash
./setup.sh --search --domain octo.example.com --ip 1.2.3.4
# 或同时：./setup.sh --summary --search ...
sudo ./setup.sh --up
```

`--search` 只部署搜索**基础设施**。要索引历史数据并把 reader 切到 OpenSearch，
请在栈起来后运行零停机升级：`cd docker && scripts/search-upgrade.sh`
（见下文 "Search profile" / "Turn search on"）。

`setup.sh` 写出含轮换随机密钥的 `docker/.env` 和自动生成的 `OCTO_ADMIN_PWD`，并**在最后打印 admin URL + 密码**，免得你回头去 grep `.env`。这是从空 checkout 到 `(healthy)` 栈无需手改任何东西的唯一路径。

栈起来后，通过 nginx 访问：`http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`（默认 `http://localhost:28080`）。默认 `localhost` 在运行栈的主机上不需要任何额外的 DNS / `/etc/hosts` 配置。如果你把 `OCTO_DOMAIN` 改成真实域名，则每台访问 UI 的客户端机器都要能解析这个域名（真实 DNS，或者 `/etc/hosts` 里指向本机 IP）。

### `setup.sh --smoke-test` 自检命令

`sudo ./setup.sh --up` 报告所有服务 healthy 之后，跑自检命令确认**外部表面**确实能用：

```bash
sudo ./setup.sh --smoke-test
```

> **为什么要 sudo？** `docker/.env` 由步骤 1（`./setup.sh`）生成。步骤 1 不带 sudo 跑时，文件 owner 是当前用户（mode 600）；带 sudo 跑时，owner 是 root。无论哪种，步骤 2（`sudo ./setup.sh --up`）需要 sudo 是因为要连 Docker daemon socket，而步骤 2 跑完后文件 owner 都会变成 root。`--up`（start-only 子命令，永远不会重新生成密钥）和 `--smoke-test` 都需要 sudo，因为这个文件装着全栈的高价值密钥——`MYSQL_ROOT_PASSWORD`、`MINIO_ROOT_PASSWORD`、`OCTO_MASTER_KEY`、`OCTO_ADMIN_PWD`、`OCTO_NOTIFY_INTERNAL_TOKEN`、`OCTO_WUKONGIM_MANAGER_TOKEN`——再加上 `COMPOSE_PROJECT_NAME` 这种会被下一次特权 `docker compose` 直接 consume 的 Compose 控制项。早先几轮 R1-R4 试过 chmod / chown / groupadd 让普通用户能跑 `--smoke-test`，但都会**扩大写权限**到一个 Compose 视为权威部署配置的文件上——R5 改成最简方案：".env 保持 root:600，`--up` 和 `--smoke-test` 都要 sudo，因为文件里全是 MySQL / MinIO / admin 凭据和 Compose 控制项"。忘 sudo 时 `env_get()` 会给一行清晰的 remediation（`Re-run as: sudo ./setup.sh --smoke-test`），而不是过去那 9 条让人摸不到头脑的 FAIL。

> **命名说明** —— 原拼写是 `--verify`，作为 deprecated alias 保留（跑起来会先打印一行黄色 deprecation note，行为与 `--smoke-test` 完全一致），至少保留 2 个 release，预计 v2.0+ 删除。新写的自动化优先用 `--smoke-test`。
>
> **为什么不是 "dry-run"？** 这条命令**不是只读的**：会发 1 POST（admin 登录）+ 1 GET（presign 签发）+ 1 PUT（在 MinIO `common` bucket 留下一个 1 字节哨兵对象 `octo-verify-<timestamp>-<pid>.txt`，因为 presign 请求带的是 `type=common`）。它走的是真实的 auth + 真实的 storage 路径，叫成 "verify" / "dry-run" 会低估副作用。

输出按失败域分组打印两个 banner，FAIL 时一眼能看出该排查哪一层：

- `[infra] container + nginx routing (step 1-7)` —— 容器健康、nginx vhost、octo-server REST、matter、MinIO health、admin SPA、web SPA。这一段 FAIL 是**平台问题**：某个容器掉了、nginx 没在反代、宿主端口被防火墙挡住——先看 `docker compose ps` / `docker compose logs`。
- `[user-path] auth + WS + presigned PUT (step 8-11)` —— WuKongIM `/ws`、admin 登录、presign 签发、签名 PUT。这一段 FAIL 是**契约问题**：平台是活的，但 auth 接错、MinIO IAM 凭据 desync、SigV4 签名对不上——看 octo-server + MinIO 这条线，别再去查 nginx。

11 个探测步骤（每步打印 PASS/FAIL）：

1. `docker compose ps` 没有 `(unhealthy)` 容器，也没有致命状态（`Exited (1)` / `Restarting` / `Dead`），且没有任何 expected service 缺失或已被 cleanly stop
2. nginx vhost up（`GET /_nginx_up`）
3. octo-server REST（`GET /api/v1/health`）
4. octo-matter（`GET /matter/health`）——**计入** 失败
5. 经 nginx 访问 MinIO（`GET /minio/health/live`）
6. admin SPA 可达（`GET /admin/`）
7. web SPA 可达（`GET /`）——确认用户侧 SPA 经同一 nginx vhost 端到端可达，与 `/api/`、`/ws` 同口承诺一致
8. WuKongIM `/ws` upgrade probe（`GET /ws`，用 `python3` raw socket 发一次真实的 RFC 6455 WebSocket-upgrade 握手）——专门捕获 `docker stop wukongim` 后容器残留为 `Exited (0)`、绕过 `(unhealthy)` 和致命状态集的场景；`101` / `400` / `426` 视为 healthy，`502` / `503` / `504` / `000` 以及其它 4xx-5xx 视为失败
9. **admin 登录**（`POST /api/v1/manager/login`，用 `.env` 里的
   `OCTO_ADMIN_PWD` 以 `superAdmin` 身份）——验证 octo-server + MySQL +
   bcrypt + Redis 缓存这条链
10. **预签名 PUT 凭据签发**（`GET /api/v1/file/upload/credentials`）——
    验证 octo-server 的 MinIO IAM 凭据路径
11. **1 字节 PUT 到预签名 URL**——验证 nginx 原样转发 SigV4 路径以及
    MinIO 接受签名（双端口形态下 29000 被防火墙挡时图片消息静默丢失走
    的就是这条路径，见 OOTB-BUG-2026-05-17-001）。

任何步骤失败 exit code 非 0。`python3` 是 `--smoke-test` 的**硬前置依赖**——
第 8 步（WuKongIM `/ws` 探测）用 python3 打 raw socket，第 9-11 步
（admin 登录、presign 签发、SigV4 PUT）用 `python3 -c 'import json'`
解析 JSON，过去 silently skip 这些 JSON 步骤正是 OOTB-BUG-2026-05-17-001
被掩盖的口子。现在缺失 `python3` 会 fail-fast 非 0 退出；装上
（所有 modern Linux 发行版 base image 都自带）再重跑。这是用来在新机器
上确认「端到端真的能用」的命令——区别于「容器起来了」。

第 11 步会在 `common` bucket 留下一个 1 字节哨兵对象
（`octo-verify-<timestamp>-<pid>.txt`）。bucket 由第 10 步发给
`GET /api/v1/file/upload/credentials` 的 `type=common` 决定 —— octo-server
的 MinIO 后端把 `type=` 映射到对象路径首段，再由 `splitBucketAndObject`
（octo-server `modules/file/helpers.go`）按 allow-list（`file`/`chat`/
`moment`/`sticker`/`report`/`chatbg`/`common`/`download`/`group`/`avatar`）
路由到对应 bucket，所以 `type=common` 就落在 `common`。哨兵对象是故意留下
的——本仓库使用的 `minio/minio` 镜像 **不带** `mc` 客户端（`mc` 在独立的
`minio/mc` 镜像里，只被一次性的 `minio-init` 容器用到），所以
`docker exec <project>-minio-1 mc rm ...` 这种命令必然报
`mc: executable file not found`。每次 `--smoke-test` 多 1 字节远低于噪声；
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
> OCTO_WK_WSS_ADDR=wss://${OCTO_DOMAIN}:${OCTO_HTTPS_PORT}/ws
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

## 生产 HTTPS 部署

OOTB 栈在 `OCTO_HTTP_PORT`（默认 `28080`）上只跑 HTTP。生产部署推荐
**在栈前面套一层反向代理**做 TLS 终结，而不是把 certbot 塞到栈里。
这样证书生命周期归反向代理层管（这是它该待的地方——见下面「为什么
不内置 certbot」），也能让你复用车间里已经在用的 Let's Encrypt /
Cloudflare / 内部 CA 任何 workflow。

下面给出三条经过实战的路径，**彼此独立——选一条匹配你环境的就行，
不需要三个都装**。

三条路径的 upstream 都是栈内 nginx 的 `http://<host>:28080`。把栈内
nginx 限制到 loopback 上（见下面 [HTTPS 防火墙规则](#https-防火墙规则)）
让 `28080` 不直接出公网——反向代理是唯一对外监听端口。

> 💡 **三条路径都必须在 `docker/.env` 里设这几个 HTTPS URL 变量。**
> TLS 在反向代理终结后，octo-server 仍然按下面这些变量给客户端返回
> **绝对 URL**（预签名 MinIO PUT/GET、admin baseURL、WS 地址）。
> 请把字面 hostname 写进去（`.env` 不做 `${...}` 二次插值）：
>
> ```bash
> # docker/.env —— 套反向代理时必填
> MINIO_SERVER_URL=https://octo.example.com
> TS_MINIO_DOWNLOADURL=https://octo.example.com
> TS_EXTERNAL_BASEURL=https://octo.example.com
> OCTO_WK_WSS_ADDR=wss://octo.example.com/ws       # 浏览器走 WSS（映射到 WK_EXTERNAL_WSSADDR）
> ```
>
> 三个 URL 的 scheme + host + port 必须一致——SigV4 对这个完整 URL
> 签名，octo-server 在启动时也会校验 `TS_MINIO_DOWNLOADURL` 是 host:port
> only（不带 path 前缀）。背景见上面 Network surface 章节的 [HTTPS 形态](#https-形态tls-终结)。

### 路径 A —— Cloudflare Tunnel（推荐「我就想快速搞个 HTTPS」）

零 DNS 改动、零防火墙入站端口、自动 HTTPS、白送 DDoS + CDN。唯一
前置是域名在 Cloudflare 上（免费版就够）。

```bash
# 1. 装 cloudflared（Debian/Ubuntu）
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb

# 2. 登录 —— 会弹浏览器选 Cloudflare zone
cloudflared tunnel login

# 3. 创建 tunnel（UUID + credentials JSON 落到 ~/.cloudflared/）
cloudflared tunnel create octo

# 4. 路由 DNS —— Cloudflare 自动给你建 CNAME
cloudflared tunnel route dns octo octo.example.com

# 5. 写 /etc/cloudflared/config.yml（把 step 3 输出的 UUID 替进去——
#    `cloudflared tunnel list` 可以查到）。同时把 ~/.cloudflared/ 下的
#    凭证 JSON 拷贝到 service 拥有的路径，让 root 启动的 systemd 单元
#    能读到（否则会因为 /root/.cloudflared/<uuid>.json 不存在启动失败）。
sudo install -d -m 0755 /etc/cloudflared
sudo cp ~/.cloudflared/*.json /etc/cloudflared/
sudo tee /etc/cloudflared/config.yml >/dev/null <<'YML'
tunnel: <TUNNEL-UUID>
credentials-file: /etc/cloudflared/<TUNNEL-UUID>.json

ingress:
  - hostname: octo.example.com
    service: http://localhost:28080
    originRequest:
      connectTimeout: 30s
  - service: http_status:404
YML

# 6. 纯语法校验（不发 Cloudflare 请求）
#    cloudflared 在不传 --config 时自动读 /etc/cloudflared/config.yml
sudo cloudflared --config /etc/cloudflared/config.yml tunnel ingress validate

# 7. 装 systemd 服务并启动
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Cloudflare tunnel 在 edge 上终结 TLS，把 `https://octo.example.com/*`
（包括 `/ws` WebSocket upgrade 和 `/{bucket}/{key}` MinIO presign PUT/GET）
经一条出站 mTLS 隧道转发回你的 host——**主机防火墙完全不需要开任何
入站端口**。栈内 nginx 仍然负责 bucket-name 路由，因为 Cloudflare
原样转发 path（不 rewrite、不破签）。

**请求体大小**：Cloudflare Free 版请求体上限 100 MB；Pro 200 MB；
Business 500 MB。OOTB 的聊天图片 / 文件消息 100 MB 够用。要更大就在
Cloudflare dashboard 里调（Rules → Configuration Rules → "Upload size
limit"），或升 plan。

**WebSocket**：`cloudflared` 自动转发 `Upgrade` / `Connection` 头——
`/ws` 和 `/api/*` 的 long-poll fallback 直接就能用，不用配。

### 路径 B —— host nginx + certbot（最常见的自托管形态）

经典「这台机器上本来就跑 nginx」路径。certbot 的 `--nginx` 插件
一并搞定证书签发 + 自动续期 + nginx reload，配完之后证书生命周期
完全无人值守。

```bash
# 1. 装 nginx + certbot
sudo apt-get update
sudo apt-get install -y nginx python3-certbot-nginx

# 2. 在 http{} 作用域里定义 WebSocket-upgrade map。
#    Debian/Ubuntu 的 /etc/nginx/nginx.conf 默认 include
#    /etc/nginx/conf.d/*.conf 进 http{}，所以扔一个小文件过去就行：
sudo tee /etc/nginx/conf.d/connection_upgrade.conf >/dev/null <<'NGINX'
# proxy_set_header Connection $connection_upgrade 必须配这个 map。
# 把入站 Upgrade 头映射成 per-request 的 Connection 值：
#   WS 握手 → "upgrade"，其它请求 → "close"。
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINX

# 3. 写 OCTO vhost
sudo tee /etc/nginx/sites-available/octo.conf >/dev/null <<'NGINX'
upstream octo_backend {
    server 127.0.0.1:28080;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name octo.example.com;

    # certbot --nginx 会在加完 443 server 块之后把这一段改写成 301 到 https://。
    # ACME HTTP-01 和 80→443 redirect 都需要 80 端口可达。
    location / {
        proxy_pass http://octo_backend;
        proxy_http_version 1.1;

        # 把客户端身份转发给栈内 nginx 和应用
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;

        # WebSocket upgrade —— /ws 和 /api long-poll fallback 都要。
        # 不配这两行 WS 握手会静默退化到 200，聊天客户端永远连不上。
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;

        # MinIO presign PUT —— 聊天图片 / 文件附件上传可能 10-100 MB。
        # 这个拓扑里先卡住请求的是**主机** nginx；栈内 nginx 默认已经够宽松。
        client_max_body_size               100M;

        # 长连聊天 WebSocket。OOTB 聊天会话一开几个小时；默认 60s
        # read_timeout 会过早断开。
        proxy_read_timeout                 3600s;
        proxy_send_timeout                 3600s;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/octo.conf /etc/nginx/sites-enabled/octo.conf

# 4. 让 certbot 动 vhost 之前先 validate 语法
sudo nginx -t

# 5. 一次性：签证书 + 装证书 + 加 443 块 + 设自动续期
sudo certbot --nginx -d octo.example.com \
  --non-interactive --agree-tos -m admin@example.com --redirect

# 6. 确认续期 timer 已就位（Debian/Ubuntu 出厂启用）
sudo systemctl status certbot.timer
sudo certbot renew --dry-run
```

`certbot --nginx` 会加上 `listen 443 ssl` 块、指向
`/etc/letsencrypt/live/octo.example.com/` 里签好的 LE 证书、给 80 块
加 `return 301 https://...`，并装上 `certbot.timer` 在过期前约 30 天
自动续期。配完之后运维要做的只剩 `nginx` 和 `certbot` 包打补丁。

**WebSocket 关键**：`proxy_set_header Upgrade` / `proxy_set_header
Connection` 这一对加上 http{} 作用域的 `map $http_upgrade
$connection_upgrade` 是 nginx WebSocket 的标准配方。`$http_upgrade`
在普通 REST 请求上为空、在 WS upgrade 上是 `websocket`；`map` 把它
翻译成对应的 `Connection` 值（REST 为 `""`，WS 为 `upgrade`）。
真正要躲的坑是把 `proxy_set_header Connection "upgrade"` 写死——
那会让每个请求都强制 `Connection: upgrade`，REST 的 HTTP/1.1
keepalive 会被打断。`Connection` 一定要走 `map`，不能写字面
`"upgrade"`。

**请求体大小**：`client_max_body_size 100M` 覆盖聊天 / 文件消息的
MinIO presign PUT。用户要传更大的就再往上调——栈内 nginx 不会成为
瓶颈。

### 路径 C —— Caddy（单 binary，最少零件）

Caddy 用一个非常短的 Caddyfile 自动签 + 自动续 Let's Encrypt 证书。
没有 certbot、没有 timer、没有单独的 vhost-enable 仪式。

```bash
# 1. 装 Caddy（Debian/Ubuntu —— 官方签名 apt 仓库）
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update
sudo apt-get install -y caddy

# 2. 写 Caddyfile
sudo tee /etc/caddy/Caddyfile >/dev/null <<'CADDY'
octo.example.com {
    # Caddy 在第一次请求时自动给 LE 申请证书并在过期前约 30 天续期。
    # WebSocket upgrade 是自动的 —— reverse_proxy 指令本身就转发
    # Upgrade / Connection 头。
    reverse_proxy 127.0.0.1:28080 {
        # Caddy 的 reverse_proxy 自动设 Host + X-Forwarded-For /
        # -Proto / -Host。唯一值得显式加的是 X-Real-IP，Caddy 默认
        # 不设，但栈内 nginx + octo-server 的 access log 会读。
        header_up X-Real-IP {remote_host}

        # 长连聊天 WebSocket。OOTB 聊天一开几个小时；把超时调到默认
        # 30s/2m 之上。
        transport http {
            read_timeout  1h
            write_timeout 1h
        }
    }

    # MinIO presign PUT —— 聊天图片 / 文件附件上传。
    # Caddy 在 HTTP 层默认 request body 上限 10 MiB；调到跟上面两条
    # 路径同档。
    request_body {
        max_size 100MB
    }
}
CADDY

# 3. 校验
sudo caddy validate --config /etc/caddy/Caddyfile

# 4. reload（Caddy 是热 reload —— 不掉连接）
sudo systemctl reload caddy
```

Caddy 在一个 binary 里帮你做：

- 第一次入站请求时申请 LE 证书（HTTP-01 走 :80、TLS-ALPN-01 走 :443；
  签发期间两个端口必须公网可达）。
- 过期前约 30 天自动续期。无 timer、无 cron。
- 默认讲 HTTP/2 和 HTTP/3。
- 自动转发 `Upgrade` / `Connection` 头——不用像 nginx 那样配 `map` 块。

**请求体大小**：Caddy HTTP 层默认 body cap 10 MiB，比一张稍大点的
图片小，MinIO presign PUT 直接会被卡。`request_body { max_size 100MB }`
把它放到跟另外两条路径同档。

### 为什么不在本仓库内置 certbot

两个理由：

1. **证书生命周期归反向代理层管，不归应用层。** 已经成规模的运维
   都在前门有反向代理（host nginx、Caddy、Cloudflare、Traefik、云
   LB），现成的 TLS 终结点已经在那。在这个栈里再塞 certbot 容器要么
   (a) 跟那个前门抢 80/443、要么 (b) 走
   `--standalone-with-cert-forward` 那种比「让现有前门 proxy 到 :28080」
   严格更脆的方案。OOTB 的最佳点就是「我给你一个 `:28080` 上能用的 HTTP
   栈，TLS 你用自己习惯的工具套」。
2. **全自动 DNS-01 需要写 DNS 的凭据**，这个没办法 portable 地 ship。
   Cloudflare API token、Route53 key、阿里云 AccessKey、内部 DNS——
   每家配法都不一样。我们不想要一个会问你 zone 写权限的 setup 脚本。

如果你确实有强需求把 TLS 终结在栈里（比如无前置代理的离线机房），
`nginx/conf.d/octo.conf.template` 里 HTTPS server 块仍在，配套手动
流程见 [`docker/certs/README.md`](certs/README.md)。除此之外推荐用
上面三条反向代理路径。

### HTTPS 防火墙规则

套反向代理后：

| 端口 | 方向 | 谁需要开 | 用途 |
| ---- | ---- | -------- | ---- |
| `443/tcp` | 入站 | 路径 B/C 的反向代理主机（路径 A：不需要） | 客户端 HTTPS |
| `80/tcp`  | 入站 | 路径 B/C 的反向代理主机（路径 A：不需要） | LE HTTP-01 ACME 挑战 + HTTP→HTTPS redirect |
| `28080/tcp` | **只限 loopback** | 栈内 nginx | upstream —— 通过 `OCTO_NGINX_BIND` 绑到 `127.0.0.1`，不让出公网 |

路径 A（Cloudflare Tunnel）**完全不需要入站端口**——隧道是出站的，
反向代理主机的防火墙入站可以全关。

#### 主方案 —— 把栈内 nginx 绑到 loopback（唯一可靠的方式）

编辑 `docker/.env`，加：

```bash
OCTO_NGINX_BIND=127.0.0.1
```

然后重启 nginx：

```bash
sudo docker compose up -d nginx
```

`28080` 会只绑在 loopback 接口上——同主机上的反向代理才能到达。
外部客户端访问 `http://<public-IP>:28080/` 在内核层就被拒绝/超时，
根本到不了 Docker 或任何容器。

验证（在跑 compose 的主机上）：

```bash
curl -fsS http://127.0.0.1:28080/_nginx_up           # → "ok" (200)
curl --max-time 5 http://<public-IP>:28080/_nginx_up # → connection refused / timeout
```

#### 副方案 —— 纵深防御，**不能**替代 OCTO_NGINX_BIND

> ⚠️ **不要只靠 `ufw deny 28080/tcp`。** Docker 发布端口走 iptables
> `DOCKER` chain，**在 ufw 的 `INPUT` / `ufw-*` chain 之前**就被求值。
> 外部流量仍能到达 Docker 发布的端口，ufw 规则起不到作用——
> `ufw status` 里看着对，实际上不挡。参考：
> https://github.com/docker/for-linux/issues/690
>
> `ufw deny 28080/tcp` 可以做纵深防御（belt-and-suspenders），但
> `OCTO_NGINX_BIND=127.0.0.1` 才是唯一可靠的限制方式。

路径 B / C 通常需要的主机防火墙规则（这些**确实有效**——管的是
host nginx 自己的 `443` / `80`，不是 Docker 发布的端口）：

```bash
# Debian/Ubuntu + ufw —— 路径 B / C（栈内 nginx 已经通过上面的
# OCTO_NGINX_BIND=127.0.0.1 限定到 loopback；下面这些是开反向代理
# 自己的监听端口）
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp     # 路径 B/C 才需要（Cloudflare Tunnel 不需要）
sudo ufw enable
```

### 反向代理上的 WebSocket

OCTO 在 `/ws` 上跑 WebSocket（WuKongIM 浏览器传输，聊天数据面）。
`/api/*` 是纯 REST，**也** 必须经过不会破 HTTP/1.1 keepalive 的代理
——long-poll fallback 假设连接保持打开。上面三条路径都覆盖了这两点：

- **路径 A**（Cloudflare Tunnel）：`cloudflared` 自动转发
  `Upgrade` / `Connection` 头——`/ws` upgrade 不用配、`/api/*`
  keepalive 不用配。
- **路径 B**（host nginx）：`proxy_set_header Upgrade $http_upgrade`
  + `proxy_set_header Connection $connection_upgrade` 这一对，加上
  http{} 作用域的 `map $http_upgrade $connection_upgrade`，是 nginx
  的标准 WebSocket 配方。`$http_upgrade` 在 REST 上为空、在 WS
  upgrade 上是 `websocket`；`map` 把它翻译成对应的 `Connection`
  值（REST 为 `""`、WS 为 `upgrade`）。要躲的坑是把
  `proxy_set_header Connection "upgrade"` 写死——那会让每个请求
  都强制 `Connection: upgrade`，破 REST 的 HTTP/1.1 keepalive。
  上面的 step 2 把 `map` 放在
  `/etc/nginx/conf.d/connection_upgrade.conf` 里，在任何 vhost 之前
  就加载到 http{} 作用域。
- **路径 C**（Caddy）：`reverse_proxy` 指令自动转发 `Upgrade` /
  `Connection`，不用显式配。

如果 `/ws` 连接握手成功（`101 Switching Protocols`）但 ~60s 后就断
开，问题在 `proxy_read_timeout`（nginx）或
`transport http { read_timeout }`（Caddy）——OOTB 聊天会话开几个小
时，3600s 是安全值。

### 内部端口 vs 外部端口映射

套反向代理后，把 OOTB 栈合在一起的两个端口被拆开了：

| 层 | 监听 | 谁能到达 |
| --- | ---- | -------- |
| 反向代理（host nginx / Caddy / Cloudflare edge） | `:443`（+ `:80` 给 ACME / redirect） | 公网 |
| 栈内 nginx（`OCTO_HTTP_PORT`） | `127.0.0.1:28080`（按上面防火墙 / 端口绑定限制后） | 只有主机 loopback |
| 后端服务（MinIO API、MySQL、Redis、WuKongIM monitor…） | `127.0.0.1:<port>`（`OCTO_*_BIND` 默认值） | 只有主机 loopback |

反向代理是**唯一**对外监听点。其它都按
[Backing-service host bindings](#backing-service-host-bindings) 和
[Network surface](#network-surface) 里写的待在 loopback 上。OOTB 默认
把 `28080` 绑到 `0.0.0.0`（`OCTO_NGINX_BIND=0.0.0.0`）是给笔记本上
单端口部署用的——只要前面套了反向代理，就在 `docker/.env` 里改成
`OCTO_NGINX_BIND=127.0.0.1` 然后 `docker compose up -d nginx`（为什么
单靠 ufw 不够见上面 [HTTPS 防火墙规则](#https-防火墙规则)）。

> 💡 **为什么不直接把栈内 nginx 绑到 `:443`？** 两个理由：(1) 那会
> 把所有 TLS 旋钮（证书路径、cipher suite、HTTP/2、HSTS）都塞进
> `nginx/conf.d/octo.conf.template`，那个文件本来就该是单租户的应用
> 层关注点；(2) 这样会把证书私钥放进一个生命周期绑定到应用发版的
> 容器里。反向代理拆出来让应用层保持「无证书」，让证书生命周期待在
> 它该待的地方。

---

## Speech profile（语音转写）

语音转写流水线 — `octo-speech`（转写 API）+ `octo-speech-admin`（API Key
管理控制台）— 通过 Docker Compose 的 `speech` profile **按需启用**：

- 默认 `docker compose up -d` **不会**启动任何语音服务。
- 所有语音相关环境变量均有空默认值，非语音部署不会因缺少变量而失败。
- 管理控制台默认绑定 `127.0.0.1:28088`（仅限 loopback，与 MinIO 控制台相同）。
  远程访问请使用 SSH 转发：`ssh -L 28088:127.0.0.1:28088 user@host`

### 启动 speech profile

运行引导脚本：

```bash
cd docker
scripts/speech-setup.sh
```

脚本会依次完成：校验密钥、创建 `octo_speech` 数据库及专属用户、启动语音容器、
重建 nginx、通过管理控制台（直接访问 loopback 端口 28088）创建 API Key、
写入 `.env` 并重启 `octo-server`。

从指定步骤恢复执行（例如部分执行后重试）：

```bash
scripts/speech-setup.sh --from 3   # 从步骤 3 恢复（0..5）
```

### 语音引擎配置

默认引擎为 `qwen`（推荐用于中文）。在 `.env` 中设置 `VOICE_ENGINE` 切换：

| 引擎     | 需要的变量                                        |
|----------|---------------------------------------------------|
| `qwen`   | `VOICE_QWEN_URL`, `VOICE_QWEN_KEY`, `VOICE_QWEN_MODELS` |
| `gpt`    | `VOICE_LITELLM_URL`, `VOICE_LITELLM_KEY`, `VOICE_GPT_MODELS` |
| `gemini` | `VOICE_LITELLM_URL`, `VOICE_LITELLM_KEY`, `VOICE_MODELS` |

详见 `.env.example`。

---

## Docs profile（协同文档）

协同文档后端 — `octo-docs-backend`（Hocuspocus + Yjs 实时同步）— 通过 Docker
Compose 的 `docs` profile **按需启用**：

- 默认 `docker compose up -d` **不会**启动任何文档服务。
- 所有文档相关环境变量均有空默认值，非文档部署不会因缺少变量而 preflight 失败。
- nginx 同时代理 REST（`/docs-api/` → port 3000）和 WebSocket（`/docs-ws/` →
  port 1234）——无需额外主机端口。

### 前置条件

在将 `docs` 加入 `COMPOSE_PROFILES` 之前，先在 `docker/.env` 中设置四个必填密钥：

| 变量 | 用途 | 生成方式 |
|---|---|---|
| `OCTO_DOCS_DB_PASSWORD` | `octo_docs` 数据库专属 MySQL 用户密码 | `openssl rand -hex 16` |
| `OCTO_DOCS_COLLAB_SECRET` | Hocuspocus collab token 的 JWT 签名密钥（≥32 字符） | `openssl rand -hex 32` |
| `OCTO_DOCS_ATTACHMENT_SECRET` | 附件预签名 URL 的 HMAC 签名密钥（≥32 字符） | `openssl rand -hex 32` |
| `OCTO_DOCS_COLLAB_WS_URL` | 浏览器可访问的 WebSocket URL，例如 `ws://10.201.0.101:28080/docs-ws/` | 手动填写 |

同时将 `OCTO_DOCS_WEB_ORIGIN`、`OCTO_DOCS_S3_ENDPOINT`、`OCTO_DOCS_CORS_ORIGINS`
设置为与你的部署 URL 一致。详见 `.env.example`。

### 启动 docs profile

```bash
cd docker
# 将 "docs" 并入已有的 COMPOSE_PROFILES（防止重复追加）
existing="$(grep -E '^COMPOSE_PROFILES=' .env | tail -1 | cut -d= -f2-)"
if ! echo "$existing" | grep -qw "docs"; then
  sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${existing:+$existing,}docs|" .env
fi

docker compose --profile docs up -d octo-docs-backend
docker compose up -d --force-recreate nginx
```

### 数据库与 MinIO

`init-extra-dbs.sh` 只在 MySQL volume **首次初始化**时运行，因此全新部署时
`octo_docs` 和 `docs` 用户会自动创建。

**在已运行的集群上**（大多数按需启用的场景）需要手动对在线 MySQL 执行。先在 `.env`
中设好 `OCTO_DOCS_DB_PASSWORD`，然后运行：

```bash
DOCS_PASS="$(grep -E '^OCTO_DOCS_DB_PASSWORD=' docker/.env | cut -d= -f2-)"
docker exec -i octo-mysql-1 \
  mysql -uroot -p"$(grep -E '^MYSQL_ROOT_PASSWORD=' docker/.env | cut -d= -f2-)" <<SQL
CREATE DATABASE IF NOT EXISTS octo_docs CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'docs'@'%' IDENTIFIED BY '${DOCS_PASS}';
ALTER USER IF EXISTS      'docs'@'%' IDENTIFIED BY '${DOCS_PASS}';
GRANT ALL PRIVILEGES ON octo_docs.* TO 'docs'@'%';
FLUSH PRIVILEGES;
SQL
```

`octo-docs-backend` 启动时会自行运行 schema migration——无需手动导入 SQL。

`octo-docs-attachments` MinIO bucket 由 `minio-init` 在 `OCTO_DOCS_DB_PASSWORD`
非空时自动创建。若 `minio-init` 已在你添加 docs 之前运行过，重跑一次即可：

```bash
docker compose up --force-recreate minio-init
```

### 开启 octo-server 中的文档功能开关

文档模块受 `system_setting` 表控制。`octo-server` 启动后执行一次：

```bash
docker exec -i octo-mysql-1 \
  mysql -uroot -p"$(grep MYSQL_ROOT_PASSWORD docker/.env | cut -d= -f2-)" octo <<'SQL'
INSERT INTO system_setting (category, key_name, value, value_type, description)
VALUES ('docs', 'enabled', '1', 'bool', 'Enable docs module in octo-web')
ON DUPLICATE KEY UPDATE value = '1';
SQL

docker compose restart octo-server
```

### 验证

```bash
# REST 健康检查
curl http://127.0.0.1:28080/docs-api/healthz
# → {"ok":true}

# 服务状态
docker compose ps octo-docs-backend
```

---

## Search profile（消息搜索流水线）

消息搜索流水线——Kafka + OpenSearch（带 `analysis-ik` 中文分词器）+ `es-indexer` 消费者——通过 Docker Compose 的 `search` profile **按需开启（opt-in）**，和 smart-summary 的 `summary` profile 完全一样。不设 profile 时它完全惰性、零副作用：

- 默认的 `docker compose up -d`（或 `setup.sh`）启动**零个**搜索服务。默认 profile 渲染出的配置在加不加这些新增内容时逐字节完全一致。
- `.env` 里每个搜索变量都有默认值（或只在搜索服务内部被引用），所以非搜索部署绝不会因为缺某个搜索变量而 preflight 失败。
- 新增的主机端口默认绑定 loopback（`127.0.0.1:29200` OpenSearch、`127.0.0.1:29092` Kafka）；新增的命名卷（`opensearch-data`、`kafka-data`、`search-dlq-spill`）与栈其余部分带同样的 `COMPOSE_PROJECT_NAME` 前缀。拆除时务必**显式点名这些搜索卷**（见下文"拆除"），**绝不要**用项目级的 `docker compose down -v`——那会无视 `COMPOSE_PROFILES`，把核心数据卷也一并删掉。

> 合并这些 manifest 本身不部署任何东西。把 profile 起起来是运维人员的显式动作；在任何共享 / staging / 生产环境里，都需 owner 签字放行。

> **快捷方式：** `./setup.sh --search` 会替你把 `COMPOSE_PROFILES=search` 写进 `docker/.env`（与 `--summary` 同传时自动合并），省得手改 `COMPOSE_PROFILES`。它只部署基础设施；之后运行 `scripts/search-upgrade.sh` 来索引历史并切换 reader（见下文"打开搜索"）。

### 为本地验证构建 es-indexer 镜像

`mininglamposs/octo-search-indexer` 镜像只在 `v*` tag / 手动触发时发布。本地验证时，从 [octo-search-indexer](https://github.com/Mininglamp-OSS/octo-search-indexer) 仓库的 checkout 构建一个 tag，并让栈指向它：

```bash
# 在 octo-search-indexer 的 checkout 里
docker build -t octo-search-indexer:local .

# 在本仓库的 docker/.env 里
OCTO_SEARCH_INDEXER_IMAGE=octo-search-indexer:local
```

这一个镜像携带全部三个流水线二进制——`es-indexer`（长驻消费者，默认入口）、`backfill`（一次性历史加载器）、`reconcile`（正确性校验闸门）——所以下面的升级流程不需要单独的 Go 工具链或第二个镜像。

> **镜像可用性（社区部署）。** 发布的 `mininglamposs/octo-search-indexer:latest` tag 只有在切过 release tag 后才存在，而带 IK 的 OpenSearch 镜像（`octo-search-opensearch-ik`）是从 `docker/opensearch/Dockerfile` 本地构建的（不推送到公共 registry）。对于从零开始的社区部署，请把两者都当作**前置依赖**：如上所示从 checkout 构建 indexer 镜像（或在有 `v*` tag 后固定到该 tag），并让 Compose 在首次 `up` 时构建 OpenSearch+IK 镜像（`--build`）。IK 插件在构建时从 `release.infinilabs.com` 下载，所以构建所在主机必须能访问该地址。

带 IK 插件的 OpenSearch 镜像会在首次 `up` 时从 `docker/opensearch/Dockerfile` 自动构建（无需手动步骤）。

### 把 search profile 起起来

```bash
cd docker
# 为当前 shell 启用该 profile（或在 .env 里持久化 COMPOSE_PROFILES=search）
export COMPOSE_PROFILES=search
docker compose up -d --build search-opensearch search-kafka search-kafka-init es-indexer
```

`search-kafka-init` 预建正文 + DLQ topic（`octo.message.v1`、`octo.message.v1.dlq`）——这是必需的，因为 indexer 的 DLQ producer 以 `AllowAutoTopicCreation=false` 运行。`es-indexer` 会等它加上一个 healthy 的 OpenSearch，然后用内嵌的 IK mapping 自动创建 `octo-message` 索引（索引侧 `ik_max_word`，查询侧 `ik_smart`）。

把 profile 起起来只是搭起了**基础设施**（Kafka、OpenSearch、消费者）。它**不会**开始索引你的消息历史，也**不会**把 octo-server 切到 OpenSearch——那是下面"打开搜索"的升级步骤。此刻全新的 `octo-message` 索引是空的、alias 未绑定；octo-server 保持在 `OCTO_SEARCH_BACKEND=disabled`，直到你完成升级。

### 打开搜索（对运行中的栈做零停机升级）

这一步把一个一直 **search-off** 运行的栈升级为在线搜索部署，不中断核心 IM 服务。步骤顺序是刻意设计的——**先把 cursor seed 到消息高水位，再打开实时 producer，然后才回填历史**——这样加载期间不会漏任何在线消息，历史流也绝不会被重复摄入。回填与实时流能安全并存，因为每次 ES 写入都是以 `message_id` 为 key 的幂等 upsert。

整个流程用脚本编排，每步后带一个退出码闸门（`G1`..`G5`）：

```bash
cd docker
scripts/search-upgrade.sh                    # 从头跑全部 6 步
# 或中途续跑：  scripts/search-upgrade.sh --from 4
# 或只针对当前状态重跑闸门校验：--check
```

脚本**在做每一次状态翻转时就把它持久化进 `docker/.env`**（先 `COMPOSE_PROFILES=search`，再 `OCTO_SEARCH_PRODUCER_ON=true`，再 `OCTO_SEARCH_BACKEND=es`），这样之后普通的 `docker compose up -d` 会保持搜索开启，而不是悄悄回退到 search-off 默认值。无需手改 `.env`。

脚本做了什么，以及证明每步成功的闸门：

| 步骤 | 动作 | 闸门（退出码为准） |
|------|--------|---------------------------|
| 1 | `--profile search up -d` —— Kafka + OpenSearch + es-indexer | OpenSearch 集群报 green/yellow |
| 2 | 按 shard seed `octo_etl_es_cursor.last_id = MAX(id)`（`search-cursor-seed` 一次性任务） | **G1**：每个 shard cursor ≥ 其 `MAX(id)` |
| 3 | 打开 producer（`OCTO_SEARCH_PRODUCER_ON=true`，重建 octo-server） | **G2**：octo-server 起来且 `TS_KAFKA_ON=true` |
| 4 | 一次性历史回填 + 内联 reconcile（`search-backfill`） | **G3**：backfill 退出 0（reconcile 计数+采样通过） |
| 5 | 绑定读 alias → 物理 `octo-message` 索引（原子、single-pointing） | **G4**：alias 恰好解析到一个索引 |
| 6 | 把 reader 切到 `es`（`OCTO_SEARCH_BACKEND=es`，重建 octo-server） | **G5**：reader 在 `es` 上且经 alias 的搜索成功 |

成功跑完后，`docker/.env` 最终带上：

```dotenv
COMPOSE_PROFILES=search
OCTO_SEARCH_BACKEND=es
OCTO_SEARCH_PRODUCER_ON=true
```

> `G5` 断言的是经 alias 的搜索**成功**（alias 解析成功且 OpenSearch 应答），而不是语料非空——一个全新、零消息的安装也能正确升级并通过。

**为什么每步都重要**

- **第 2 步先于第 3 步（先 seed cursor 再开 producer）：** searchetl cursor 默认为 `0`。如果 producer 从那里启动，它会把整个消息历史在一次性回填之上重新推进 Kafka——完全的双重摄入。先把每个 shard cursor seed 到当前 `MAX(id)`，意味着 producer 只携带比切换点更新（id 更靠后）的消息。seed 是幂等且单调的（`GREATEST`），所以重跑绝不会把 cursor 倒回去。
- **第 3 步先于第 4 步（先 producer 再回填）：** 先打开实时流保证历史加载**期间**写入的消息不会丢；重叠是安全的，因为有 `_id=message_id` 幂等。
- **第 5 步在第 4 步之后（reconcile 通过后才绑 alias）：** 读 alias `wukongim-messages-read` 是 reader 查询的对象；indexer/backfill 写的是**物理** `octo-message` 索引，并刻意**不**自动绑 alias。只在 reconcile 闸门（G3）通过后才绑定，保证 reader 绝不会看到半加载的语料。
- **第 6 步最后（reader 最后切）：** octo-server 只有在 `OCTO_SEARCH_BACKEND=es` 后才读 OpenSearch。在那之前搜索入口在客户端侧是隐藏的，语料可以后台构建，对用户零可见影响。

> 两个升级任务藏在**独立**的 `search-tools` profile 后面，所以日常的 `--profile search up -d` 绝不会顺带触发历史重载或 cursor 变更。它们只在脚本显式调用时才运行（`--profile search-tools run --rm …`）。

#### 手动逐步操作（如果你不用脚本）

如果你手动跑这些步骤，下面的内联 env 覆盖只影响那一次重建。**把翻转持久化进 `docker/.env`**（`COMPOSE_PROFILES=search`、`OCTO_SEARCH_PRODUCER_ON=true`、`OCTO_SEARCH_BACKEND=es`），这样之后的 `docker compose up -d` 不会回退到 search-off 默认值——脚本会自动替你做这件事。

> ⚠️ **`COMPOSE_PROFILES` 是单个逗号分隔列表——要并集，绝不要覆盖。** 如果你已经在跑另一个 profile（比如 `summary`），一个裸的 `COMPOSE_PROFILES=search`（在这里 export，或追加进 `.env`）会悄悄把它丢掉，因为 Compose 取某个 key 的**最后**一次赋值。请把 `search` 加进已有值里，而不是替换它。脚本的 `persist_profile` 替你做这个合并；下面的手动步骤展示等价的手工做法。

```bash
cd docker
# 把 `search` 并进你已在跑的任何 profile（比如 summary），不要覆盖。
# 只从 .env 读 COMPOSE_PROFILES 那一行——绝不要 `source` .env（里面有
# 密码 / DSN，作为 shell eval 不安全）。
existing="$(grep -E '^COMPOSE_PROFILES=' .env | tail -1 | cut -d= -f2-)"
export COMPOSE_PROFILES="${existing:+$existing,}search"

# 1. 基础设施
docker compose up -d --build search-opensearch search-kafka search-kafka-init es-indexer

# 2. 把 cursor seed 到高水位  (G1)
COMPOSE_PROFILES=search-tools docker compose run --rm search-cursor-seed

# 3. 打开 producer  (G2)
OCTO_SEARCH_PRODUCER_ON=true docker compose up -d octo-server

# 4. 回填 + 内联 reconcile 闸门  (G3 —— 非零退出会在此 STOP)
COMPOSE_PROFILES=search-tools docker compose run --rm search-backfill

# 5. 原子绑定 alias  (G4)
docker compose exec -T search-opensearch curl -sS -XPOST \
  http://localhost:9200/_aliases -H 'Content-Type: application/json' -d '{
    "actions":[
      {"remove":{"index":"*","alias":"wukongim-messages-read","must_exist":false}},
      {"add":{"index":"octo-message","alias":"wukongim-messages-read"}}
    ]}'

# 6. reader -> es  (G5)
OCTO_SEARCH_BACKEND=es OCTO_SEARCH_PRODUCER_ON=true docker compose up -d octo-server

# 7. 持久化终态，让 `up -d` 保持搜索开启。
#    注意：OCTO_SEARCH_* 可以随意追加，但 COMPOSE_PROFILES 必须是 MERGE 合并，
#    不能追加——第二行 COMPOSE_PROFILES=search 会覆盖（丢掉）.env 里已有的
#    任何 profile。就地重写那一行 COMPOSE_PROFILES（用可移植的 awk，
#    避免 sed -i 各平台差异）：
printf 'OCTO_SEARCH_PRODUCER_ON=true\nOCTO_SEARCH_BACKEND=es\n' >> .env
if grep -qE '^COMPOSE_PROFILES=' .env; then
  awk -F= 'BEGIN{OFS="="}
    $1=="COMPOSE_PROFILES" && $0 !~ /(,|=)search(,|$)/ {$0=$0",search"}
    {print}' .env > .env.tmp && mv .env.tmp .env
else
  echo 'COMPOSE_PROFILES=search' >> .env
fi
```

> ⚠️ **互斥守卫现已双向生效 —— 在 standalone 仍在跑时单独 `up -d octo-server` 会让 octo-server 短暂宕机**
>
> `search-producer-guard` 已升格为无 profile 的共享守卫：`octo-server`（内置 producer）与 `search-producer`（standalone）都 `depends_on` 它。任一方在「两个 producer 同时为真」的禁忌态下启动/重建都会被守卫 `exit 1` 拦下。
>
> 具体到本 runbook 上面第 3/6 步的 `OCTO_SEARCH_PRODUCER_ON=true docker compose up -d octo-server`：**如果 standalone producer（`OCTO_SEARCH_STANDALONE_PRODUCER_ON=true` + `search-producer` profile）此刻仍在运行**，这条命令不仅会被守卫 fail-fast 拒绝，**还会先把正在运行的 octo-server 一起拆掉**——因为 `OCTO_SEARCH_PRODUCER_ON` 同时改了 octo-server 自身的 `TS_KAFKA_ON`，compose 会 recreate octo-server：旧的 running 实例被销毁，新实例因守卫失败卡在 `Created` 永不 running。**净结果：octo-server 直接下线**，不是「旧实例继续跑、只是拒绝新配置」。
>
> 这是 **fail-closed 的预期行为**（宕机优于两个 producer 双写共享 cursor + Kafka），只在 both-on 禁忌态触发，默认路径 / 单开任一路径都不受影响。但操作时务必知道这一点。
>
> **正确切流顺序：先关 standalone，再开内置。**
> ```bash
> cd docker
> # 1. 关掉 standalone producer
> docker compose stop search-producer
> # 2. 在 docker/.env 把 standalone toggle 关掉，并从 COMPOSE_PROFILES 去掉 search-producer
> #    OCTO_SEARCH_STANDALONE_PRODUCER_ON=false
> # 3. 再开内置 producer
> OCTO_SEARCH_PRODUCER_ON=true docker compose up -d octo-server
> ```
>
> **如果已经手滑撞了守卫（octo-server 已经 down）：** 把冲突的 toggle 改回去再 `up` 即可**干净恢复**——守卫会重跑并 `exit 0`，octo-server 回到 running/healthy（实测无残留、无不可恢复状态）。二选一：
> ```bash
> cd docker
> # (a) 仍想用 standalone → 把内置关回去，octo-server 以 builtin=off 恢复
> OCTO_SEARCH_PRODUCER_ON=false docker compose up -d octo-server
>
> # (b) 想切到内置 → 先停 standalone（并在 .env 关掉 standalone toggle），再开内置
> docker compose stop search-producer
> OCTO_SEARCH_PRODUCER_ON=true docker compose up -d octo-server
> ```

#### 回滚

搜索可以关掉（或回滚到旧的 Zinc 路径）而不丢数据，因为 MySQL 是权威源，OpenSearch 可重建：

- **Reader 回滚（最快）：** 在 `docker/.env` 里设 `OCTO_SEARCH_BACKEND=disabled`（搜索关闭、入口隐藏）或 `=zinc`（旧路径），然后 `docker compose up -d octo-server`。OpenSearch 语料保留完好，供之后重试。
- **Alias 回滚：** 如果你保留了较旧的物理索引，用同样的原子 `_aliases` 调用把 alias 重新指过去（换 `add` 的目标）。分阶段 reindex/alias 模式见 octo-search-indexer 仓库里的 `scripts/forward-migrate.sh`。
- **停掉 producer：** 设 `OCTO_SEARCH_PRODUCER_ON=false` 并重建 octo-server；searchetl 调度器随即空转（零开销）。cursor 被保留，所以重新启用时从中断处续跑（无需重新 seed）。

### 资源基线（有搜索 vs 无搜索）

`search` profile 在核心栈之上加了三个长驻容器。单节点大致占用（空闲到轻载；通过所注 `.env` 变量调节）：

| 组件 | 额外内存（默认） | 说明 |
|-----------|------------------------|-------|
| OpenSearch（单节点，IK） | ~1 GiB | JVM 堆为 `-Xms512m -Xmx512m`（`OCTO_SEARCH_OPENSEARCH_JAVA_OPTS`）；机器大约需要 2× 堆的余量。语料更大时调高堆。 |
| Kafka（KRaft 单 broker） | ~0.5–1 GiB | 单 broker，RF=1；单主机部署够用。 |
| es-indexer（消费者） | ~50–100 MiB | 轻量 Go worker。 |

外加三个命名卷的磁盘（`opensearch-data`、`kafka-data`、`search-dlq-spill`）以及一个用于 backfill checkpoint 的临时 `search-backfill-state` 卷。search-off 部署**不带**这些——核心栈（server/nginx/mysql/redis/minio/wukongim）逐字节不变。

### 端到端检查（本地）

```bash
# 1. OpenSearch 起来了，且索引已由 indexer 创建
curl -s localhost:29200/_cluster/health | grep -o '"status":"[a-z]*"'
curl -s localhost:29200/octo-message/_count

# 2. 向 Kafka 产一条 contract 消息并确认它落进 OpenSearch。
#    octo-search-indexer 仓库正好带了个 seed 工具：
#      （在那个 checkout 里）
#      KAFKA_BROKERS=localhost:29092 go run ./harness/seed -mode suite
#    然后重新查计数 / 搜索：
curl -s -XPOST localhost:29200/octo-message/_search \
  -H 'Content-Type: application/json' \
  -d '{"query":{"match":{"content":"公园"}}}'
```

### 可观测性

- **消费者 lag**（indexer 落后多远）：
  ```bash
  docker compose exec search-kafka \
    /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
    --describe --group octo-search-indexer
  ```
- **DLQ 积压**（毒丸 topic 深度）：
  ```bash
  docker compose exec search-kafka \
    /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 \
    --topic octo.message.v1.dlq
  ```
- **DLQ spill**（DLQ topic 不可写时的持久本地兜底）：
  ```bash
  docker compose exec es-indexer ls -la /var/lib/es-indexer/dlq-spill
  ```
- **Reconciliation diff**（MySQL 源行 vs ES 文档）：从 octo-search-indexer 仓库跑 `cmd/reconcile` 工具，针对 `localhost:29200`——见那个仓库的 `docs/backfill.md`。
- **Indexer 日志**：`docker compose logs -f es-indexer`。

### 拆除（干净拆除）

> ⚠️ **危险 —— 绝不要用 `docker compose down` 或 `docker compose down -v` 来拆搜索 profile。** 这些命令**无视 `COMPOSE_PROFILES`**——profile 过滤只对 `up` / `create` / `run` 生效，**不对** `down`。因此 `docker compose down` 会作用于**整个 `octo` project**，停掉每个核心服务（server / nginx / mysql / redis / minio / wukongim …）；`down -v` 还会额外**删除核心数据卷**（mysql-data、redis-data、minio-data、wukongim-data）。用它来"清理搜索"会抹掉整个栈及其数据。

拆搜索 profile 时**精确点名搜索服务**，然后只删**搜索专属的命名卷**——绝不用项目级 `down`：

```bash
cd docker
# 1. 只停 + 删搜索 profile 的容器（按名）。-p octo 把 project pin 死，
#    这样绝不会碰到别的栈；核心服务没被列出，因此保持运行、毫发无伤。
docker compose -p octo rm -sf search-kafka search-kafka-init search-opensearch es-indexer search-cursor-seed search-backfill

# 2. （仅本地验证）只删搜索专属的命名卷。
#    核心卷（mysql-data、redis-data、...）没被列出，也不会被碰。
#    卷名遵循 compose 文件里的 `name: ${COMPOSE_PROJECT_NAME:-octo}_*`；
#    默认 project 即 `octo_` 前缀。如果你用了非默认 COMPOSE_PROJECT_NAME，
#    在这里替换成对应值。
docker volume rm octo_opensearch-data octo_kafka-data octo_search-dlq-spill octo_search-backfill-state
```

如果你设了自定义 `COMPOSE_PROJECT_NAME`（比如 `octo-fz`），第 1 步用 `-p <name>`，第 2 步用对应的 `<name>_opensearch-data` 等。

`docker volume rm` 在卷从未创建时（比如你只跑了 OpenSearch）会无害地报 "no such volume"，可安全忽略。它会拒绝删除仍在使用的卷，所以务必先做第 1 步。

### Kubernetes

k8s manifest 放在一个独立、按需开启的 kustomization `kustomize/search/` 里，base/overlays **不**引用它。显式 apply（共享环境下，仅在 owner 签字后）：

```bash
kubectl apply -k kustomize/search -n <ns>
```

它加上 Kafka + OpenSearch StatefulSet（各带一个 PVC）、一个 es-indexer Deployment，以及一个专用的 DLQ-spill PVC（必需，这样 indexer 可崩溃恢复的 spill 记账能在 pod 重启后存活）。请先构建/推送带 IK 的 OpenSearch 镜像，并在 `kustomize/search/kustomization.yaml` 里固定一个真实的 `octo-search-indexer` tag。

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
2. 客户端能解析 `${OCTO_DOMAIN}`。OOTB 默认（`localhost`）在运行栈的同一台机器上自动可用；如果你把 `OCTO_DOMAIN` 改成真实域名，则每台访问 UI 的客户端都要能解析这个域名（真实 DNS 或 `/etc/hosts` 条目）。
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
