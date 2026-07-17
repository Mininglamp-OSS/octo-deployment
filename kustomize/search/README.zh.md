# 搜索流水线（opt-in，独立）

> English: [README.md](./README.md)

OCTO 消息搜索流水线的 Kafka + OpenSearch（analysis-ik）+ es-indexer。本 kustomization **刻意不被** `kustomize/base` 或任何 overlay 引用——apply 默认的 base/overlays 会部署零个搜索资源。它是附加的、按需开启（opt-in）的。

## Apply（共享环境需 owner 放行）

```bash
kubectl apply -k kustomize/search -n <ns>
```

## Apply 之前

1. **带 IK 的 OpenSearch 镜像**：构建 `docker/opensearch/Dockerfile`（OpenSearch + `analysis-ik`，版本严格锁步），推到你的 registry，并在 `kustomization.yaml` 里设 `octo-search-opensearch-ik` 镜像 tag。
2. **es-indexer / searchetl-producer 镜像**：共享一个镜像、两个二进制。已在 `kustomization.yaml` 里固定到一个腾讯 TCR **digest**（参考集群拉取的 registry）——见下文"镜像：固定到 TCR digest"。向前滚动时在那里重新指向 digest；生产环境不要用浮动 tag。
3. **私有 TCR pull secret**：镜像在**私有**腾讯 TCR 里，所以目标 namespace 必须已经持有 image-pull Secret，且 manifest 必须引用它（它们确实引用了——见下文"私有 TCR pull secret"）。缺了它两个 pod 都会 `ImagePullBackOff` 永不启动。
4. **Topic**：由 `search-kafka-init` Job 自动创建（compose init 服务的 k8s 等价物）——必需，因为 broker 自动创建关闭，且 indexer 的 DLQ producer 用 `AllowAutoTopicCreation=false`。该 Job 等 broker 就绪后，幂等创建 `octo.message.v1` 和 `octo.message.v1.dlq`。若想手动分阶段创建（例如不同分区数）：
   ```bash
   kubectl exec -n <ns> statefulset/search-kafka -- \
     /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
     --create --if-not-exists --topic octo.message.v1 --partitions 1 --replication-factor 1
   kubectl exec -n <ns> statefulset/search-kafka -- \
     /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
     --create --if-not-exists --topic octo.message.v1.dlq --partitions 1 --replication-factor 1
   ```

## 资源

- `search-kafka.yaml` —— Kafka（KRaft 单 broker）StatefulSet + headless Service。
- `search-kafka-init.yaml` —— 创建消息体 + DLQ topic 的一次性 Job。
- `search-opensearch.yaml` —— OpenSearch（单节点，IK）StatefulSet + headless Service。
- `es-indexer.yaml` —— es-indexer Deployment（DLQ spill 落在 PVC 上）。
- `searchetl-producer.yaml` —— standalone producer Deployment（opt-in，默认 OFF；无 PVC，无 probe）。
- `search-pvc.yaml` —— PVC：OpenSearch data、Kafka data、DLQ spill。

DLQ-spill PVC 是必需的：没有持久 spill 存储，indexer 可崩溃恢复的 DLQ 记账会在 pod 重启时失效。

## Standalone searchetl-producer（opt-in，默认 OFF）

`searchetl-producer.yaml` 带一个 standalone producer，读 MySQL 并写消息搜索 topic（`octo.message.v1`）。它是 octo-server 内置 producer（`TS_KAFKA_ON` 开关）的**替代二进制**——两者共享 cursor 和 Redis lock，所以同时运行会双写 Kafka。它与 es-indexer 共享 `mininglamposs/octo-search-indexer` 镜像（一个镜像、两个二进制）；Deployment 把入口覆盖为 `searchetl-producer`。

它出厂即 **OFF**：`replicas: 0` **且** `PRODUCER_ENABLED=false`（双重 opt-in）。apply 本目录会创建 Deployment 但不起 pod。

### 延迟调优：安全默认 vs. 近实时 overlay

本 base manifest 固定**安全**的 producer 节奏：`PRODUCER_LAG_SECONDS=600` / `PRODUCER_TICK_SECONDS=60`。cursor 只推进到 `DB_NOW - lag`，所以 lag 必须超过源 DB 最长的单条消息 INSERT 事务，否则长事务里的低 id 会被静默漏掉（C1 可见性闸门）。600（10 分钟）对任何环境都有充裕余量。**apply base（`kubectl apply -k kustomize/search`）永远拿到这个安全默认值。**

要做秒级延迟验证，opt-in **近实时 overlay**（`LAG=10` / `TICK=5`，端到端约 5-16 秒），它在结构上隔离，激进值绝不会泄漏进普通 base apply：

```
kubectl apply -k kustomize/overlays/search-near-real-time -n <ns>
```

**只**在你已确认源 DB 没有分钟级长事务的地方 apply 该 overlay；其它地方一律 apply base。（`TICK` 被二进制 clamp 到 `[5, 3600]`。）

### 启用清单（owner 放行）

启用是一个刻意的、owner 放行的动作，有数据层后果：

1. 在目标 namespace 创建专用 Secret `searchetl-producer-secret`——把 `searchetl-producer-secret.example.yaml` 拷成 `searchetl-producer-secret.yaml`，填入 `PRODUCER_MYSQL_DSN` / `PRODUCER_REDIS_ADDR`，再 `kubectl apply -f`。这些是**必需**的 `secretKeyRef`，缺了 pod 起不来（`CreateContainerConfigError`）。🔴 DSN 必须指向 IM 后端写入的**在线消息 DB**（producer 轮询其 `message` 5-shard 表的那个 DB——不一定是 octo-server 自己指向的 DB），且 `PRODUCER_REDIS_ADDR` 必须是**内置 producer 用的同一个 Redis**，这样共享 run-lock 才能真正互斥。
2. 确认 producer cursor 已 seed 到当前高水位——否则 producer 会重新推流历史（完全重载）。
3. **两个**开关一起翻转：设 `replicas: 1` **且** `PRODUCER_ENABLED=true`。只改一个会让你要么有个 Running 但不产出的 Deployment，要么有个通过守卫却空转的 workload——两者都不产消息。

> **单 pod 设计——不支持 `replicas > 1`。** 这是单活 producer workload：应用层 Redis run-lock + cursor CAS 把工作串行化到一个 producer，所以第二个副本最好情况也只是在 lock 上空转（任何争用都是浪费/风险）。启用时保持 `replicas: 1`。Deployment 用 `strategy: Recreate`（不是默认 RollingUpdate），这样镜像/env 滚动会先拆旧 pod 再起新 pod，而不是短暂跑两个 producer pod——init 互斥守卫只拦内置 producer，不拦同 Deployment 的重叠。

### 互斥守卫（及其局限）

pod 跑一个 init 容器（`producer-mutex-guard`），复用与 compose `search-producer-guard` 相同的 `is_on()` 并集 truthy 逻辑（`1|t|true|on|yes`，fail-closed）。如果内置 producer（ConfigMap `octo-server-env` 里的 `TS_KAFKA_ON`）也为真，init 容器 exit 1，producer pod 永不到 Running。

这个守卫**不**覆盖的三个局限（运维人员责任）：

- **单向**：它只拦*内置开着时 standalone 的启动*。它**不**拦反向——在 standalone 已经运行时，用 `TS_KAFKA_ON=true` 启动/滚动 octo-server。（真正的双向守卫需要动 `kustomize/base`，超出范围。）
- **时间点**：init 容器只在 pod 启动时跑。在 **producer 已经 Running 时**把 `TS_KAFKA_ON` 翻成开，不会重新触发检查——改开关前手动核实。
- **依赖 base 的 ConfigMap 存在于目标 namespace。** 本 overlay 只*引用* `octo-server-env`（一个 `optional: true` 的 `configMapKeyRef`）；它**不**定义它。`optional: true` 意味着缺失的 ConfigMap/key 被当作 `BUILTIN_ON=false`，所以把本目录**单独** apply 进一个还没有 base `octo-server-env` 的 namespace，会静默把守卫降级成 no-op——它记 `[guard] ok` 并无视真实内置状态直接起 producer。守卫只有在 `octo-server-env`（来自 `kustomize/base`）已在同一 namespace 时才保护你。**切换前，确认 ConfigMap 存在且带 `TS_KAFKA_ON`：**
  ```bash
  kubectl get configmap octo-server-env -n <ns> -o jsonpath='{.data.TS_KAFKA_ON}'
  ```
  空 / `NotFound` 结果意味着守卫在对空气设防——先 apply base（或以其它方式确保 `octo-server-env` 存在于 `<ns>`）。

### 🔴 CDC 双写警告

有些集群跑 `octo-messages-sync`（CDC binlog → Kafka）写**同一个** topic `octo.message.v1`。那条 CDC 流水线**不**在本 kustomize 树里，所以这个守卫看不到它，也无法机械地防止 standalone↔CDC 双写。**在 CDC 正在运行的环境里，不要启用这个 standalone producer，除非你已经停掉 CDC 或做了替换-vs-共存的决策。**

### 🔴 apply 连带效应：es-indexer 被重启

`kustomization.yaml` 把 `mininglamposs/octo-search-indexer` 对整个目录固定到一个腾讯 TCR digest（`tbj7-xtiao-tcr1.tencentcloudcr.com/xtiao-release/dmwork/octo-search-indexer@sha256:…`）。因为覆盖是按镜像名的，apply 本目录也会把任何已在运行的 **es-indexer** 重启到那个 digest（一个镜像、两个二进制——它们本就该保持锁步）。

### 回滚是数据层的，不是 k8s 层的

一旦 producer 跑过并推进了 cursor / 写了 Kafka，单纯 scale down 或还原 manifest **不会**回滚 Kafka / DLQ / Redis cursor 状态。数据层回滚是另一件单独的事。

### 凭据面

producer 直接读在线消息 DB，所以它的 DSN（`searchetl-producer-secret`）携带对那份数据的 DB 权限。它用自己专用的 Secret 而非借用 octo-server-secret——这让 producer 的 DB/Redis 目标显式、与 octo-server 自己的连接解耦（后者可能指向不同的 DB）。

#### 🔴 坑：producer 需要对其 cursor 表有 DDL 权限——只读账号不够

producer **拥有** cursor 表 `octo_etl_es_cursor`（存每 shard 的轮询水位）。启动时 `searchetl-producer` 跑 `CREATE TABLE IF NOT EXISTS octo_etl_es_cursor`（`EnsureSchema`，见 [`internal/producer/source.go`](https://github.com/Mininglamp-OSS/octo-search-indexer/blob/main/internal/producer/source.go)，由 `cmd/searchetl-producer/main.go` 无条件调用），然后每 shard `INSERT IGNORE` 一个 seed 行、`UPDATE ... SET last_id=...` 推进。shard 集合是 [`internal/producer/config.go`](https://github.com/Mininglamp-OSS/octo-search-indexer/blob/main/internal/producer/config.go) 里固定的五张 `message` 表（`message`、`message1`..`message4`）。所以 DB 账号需要的不止读权限：

| Producer 操作（代码） | SQL | 权限 |
|---|---|---|
| `EnsureSchema`（启动） | `CREATE TABLE IF NOT EXISTS octo_etl_es_cursor` | cursor 表上的 **CREATE** |
| `EnsureCursor` | `INSERT IGNORE INTO octo_etl_es_cursor` | cursor 表上的 **INSERT** |
| `AdvanceCursor` | `UPDATE octo_etl_es_cursor SET last_id=…` | cursor 表上的 **UPDATE** |
| `ReadStableBatchTx` | `SELECT … FOR UPDATE`（cursor）+ `SELECT …`（message shards） | 5 张 message shard **和** cursor 表上的 **SELECT** |

> **即使表已存在，`CREATE TABLE IF NOT EXISTS` 仍需要 CREATE 权限**——MySQL 在求值 `IF NOT EXISTS` 之前先检查权限。所以不能因为上次跑已建过表就去掉 CREATE。

这就是首次验收跑踩中的坑：复用 CDC 复制账号（`<cdc-account>`，在消息 DB 上只有 `SELECT` + REPLICATION）导致 pod 启动崩溃，报 `Error 1142 (42000): CREATE command denied to user '<cdc-account>'@'…' for table 'octo_etl_es_cursor'`。REPLICATION 权限在这里无关——standalone producer 是 SQL 轮询器，**不是** binlog 副本。

#### 最小权限账号（在**在线**消息 DB 实例上执行——仅 owner/DBA）

> 🔴 **这不由本仓库执行。** 在消息 DB 实例上创建用户、授权是 owner/DBA 动作——审阅后手动执行。下面的 SQL 是规格，不是本仓库执行的步骤。
>
> 把占位符替换成真实值（不放进这个公开仓库）：`<mysql-host>` = 在线消息 DB host:port，`<db-name>` = 消息数据库，`<cdc-account>` = 已有的 CDC 复制账号。

```sql
-- 以 MySQL admin 身份在在线消息 DB 实例（<mysql-host>）上执行。
-- searchetl-producer 的专用最小权限账号。
-- 不要复用 <cdc-account>（复制账号，只读——无 DDL），也不要
-- 把 root 留在 Secret 里（爆炸半径太大）。
CREATE USER 'searchetl_prod'@'%' IDENTIFIED BY '<STRONG_PASSWORD>';

-- 读 producer 轮询的 5 张 message shard 表（message、message1..message4）。
-- 表级授权把账号范围锁死在它读的东西上。
GRANT SELECT ON `<db-name>`.message  TO 'searchetl_prod'@'%';
GRANT SELECT ON `<db-name>`.message1 TO 'searchetl_prod'@'%';
GRANT SELECT ON `<db-name>`.message2 TO 'searchetl_prod'@'%';
GRANT SELECT ON `<db-name>`.message3 TO 'searchetl_prod'@'%';
GRANT SELECT ON `<db-name>`.message4 TO 'searchetl_prod'@'%';

-- producer 拥有它的 cursor 表 octo_etl_es_cursor：
--   CREATE -> EnsureSchema：启动时 CREATE TABLE IF NOT EXISTS
--   INSERT -> EnsureCursor：每 shard INSERT IGNORE seed 行
--   UPDATE -> AdvanceCursor：UPDATE ... SET last_id=...
--   SELECT -> ReadStableBatchTx：SELECT last_id ... FOR UPDATE
GRANT CREATE, INSERT, UPDATE, SELECT ON `<db-name>`.octo_etl_es_cursor TO 'searchetl_prod'@'%';

FLUSH PRIVILEGES;
```

其它都不需要（最小权限）：不需要 `ALTER`、`INDEX`、`DROP`、`DELETE` 或任何 `REPLICATION` 权限。若想进一步收窄账号，`'%'` host 可以缩到集群的 pod CIDR。

#### 把 Secret 切到专用账号

只有 `PRODUCER_MYSQL_DSN` 的凭据部分变——**host、database、query 参数保持不变**（同一在线消息 DB，同一 `octo_etl_es_cursor`）：

```
# 之前（临时，退役掉）：
PRODUCER_MYSQL_DSN: "root:<pwd>@tcp(<mysql-host>)/<db-name>?charset=utf8mb4&parseTime=true&loc=Local"
# 之后：
PRODUCER_MYSQL_DSN: "searchetl_prod:<pwd>@tcp(<mysql-host>)/<db-name>?charset=utf8mb4&parseTime=true&loc=Local"
```

apply 更新后的 Secret，再滚动 producer 让它拿到新 env：

```bash
kubectl apply -n <ns> -f searchetl-producer-secret.yaml
kubectl rollout restart deploy/searchetl-producer -n <ns>
```

> **这是凭据轮换，不是拆除——保持 producer 运行。** 一旦切过去，standalone producer **就是**在线搜索摄入路径（它替代了 octo-server 的内置 producer），所以把它 scale 到 `replicas: 0` 会停掉实时摄入，而不是退役一个凭据。退役 root：在 Secret 里把 `PRODUCER_MYSQL_DSN` 从 root 账号换成 `searchetl_prod`，重新 apply，`rollout restart`（pod 重读 Secret 时有一次短暂重启抖动）。然后把 root DSN 从 `searchetl-producer-secret` 里彻底删掉，不留 root 凭据。`replicas: 0` + `PRODUCER_ENABLED=false` 属于*退役 producer* 路径（见下文 Rollback），**不**属于凭据轮换——别把两者混为一谈。

### 镜像：固定到 TCR digest

`kustomization.yaml` 把 `mininglamposs/octo-search-indexer` 固定到一个腾讯 TCR digest：

```
tbj7-xtiao-tcr1.tencentcloudcr.com/xtiao-release/dmwork/octo-search-indexer@sha256:97c781154e1c9588deab7af29d6b7cb041188a072621122821391ac90272c7a0
```

- **为什么用 TCR 而非 Docker Hub**：参考集群从腾讯 TCR 拉取；那里已在跑的 es-indexer 也是同样按 digest 固定的。Docker Hub（`mininglamposs/*`）是 GitHub `docker-publish.yml` 轨道，是集群**不**拉取的另一条 lane。
- **为什么用 digest 而非 tag**：不可变 + 可复现。registry 里也带指向同一 digest 的人类可读 `:v0.1.0`（git release）和 `:94864fc`（commit-hash）tag，但 manifest 固定 digest，这样 tag 重推绝不会静默改变已部署的东西。
- **它是什么**：从 octo-search-indexer origin/main `94864fc`（git tag `v0.1.0`）构建的镜像，含全部四个二进制（es-indexer + searchetl-producer 在内）。

向前滚动镜像时，在这里重新指向 digest（如需，向 TCR 推一个新的 `:vX.Y.Z` / `:<commit>` tag）——不要切回浮动 tag。

**OSS / 非 dmwork 用户**：上面的 TCR digest 是**私有**镜像，没有 TCR pull 凭据会 `ImagePullBackOff`。要改从公共 Docker Hub 拉，把 `kustomization.yaml` 里 `mininglamposs/octo-search-indexer` 的 `newName`/`digest` 对换成浮动/固定 tag，例如 `newTag: "latest"`（或固定 `:vX.Y.Z` 以求可复现）并去掉 `newName` override。见 `kustomization.yaml` 里的 escape-hatch 注释。TCR digest 保持为默认。

### 私有 TCR pull secret

镜像在**私有**腾讯 TCR（`tbj7-xtiao-tcr1.tencentcloudcr.com/...`）里，所以每个跑它的 pod 都需要 image-pull Secret。`es-indexer.yaml` 和 `searchetl-producer.yaml` 都声明了：

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: tcr-image-xtiao
```

- **为什么必需**：没有 pull secret，kubelet 无法向私有 registry 认证——pod `ImagePullBackOff` 永不启动。这正是参考集群上发现的 P1：那里跑的原始 `es-indexer` manifest 带了 `imagePullSecrets`（`tcr-image-xtiao` secret），而 kustomize render 没带，所以 kustomize 管理的 producer 本来永远起不来。
- **默认 `tcr-image-xtiao`**：这是参考集群上存在的 secret——就是上面 digest 固定所针对的那个集群——所以默认自洽。
- **🔴 按集群覆盖**：secret 名是**集群特定**的。在任何其它集群你必须 (a) 在目标 namespace 创建 pull secret，(b) 在这里覆盖名字。优先用 overlay patch 而非改这个 base，例如：
  ```yaml
  # kustomize/overlays/<cluster>/imagepullsecret-patch.yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: es-indexer          # 对 searchetl-producer 重复一遍
  spec:
    template:
      spec:
        imagePullSecrets:
          - name: <your-cluster-tcr-secret>
  ```
  创建 secret，例如：
  ```bash
  kubectl create secret docker-registry <your-cluster-tcr-secret> \
    --docker-server=tbj7-xtiao-tcr1.tencentcloudcr.com \
    --docker-username=<user> --docker-password=<token> -n <ns>
  ```

## 切换 runbook（owner 放行；本 PR 不做切换）

> ⚠️ 本目录出厂 **double-OFF**（`replicas: 0` **且** `PRODUCER_ENABLED=false`），且 `octo-server-env` 出厂 `TS_KAFKA_ON=false`。这里不 apply 也不 rollout 任何东西。下面的步骤是**在**显式授权**后**运维人员走的路径——它们是文档，不是本 PR 执行的动作。

### 前置条件

1. `searchetl-producer-secret` 存在于目标 namespace（提供 `PRODUCER_MYSQL_DSN` / `PRODUCER_REDIS_ADDR`——producer 需要的在线消息 DB DSN 和共享锁 Redis 地址）。见启用清单。
2. 内置 producer 是 OFF。init 互斥守卫从 ConfigMap `octo-server-env` 读 `TS_KAFKA_ON`（这里出厂默认 `false`）。**ConfigMap 必须真的存在于 `<ns>`**——本 overlay 只引用它（`optional: true`），所以缺 `octo-server-env` 会让守卫成 no-op（见上文"互斥守卫"）。确认：
   ```bash
   kubectl get configmap octo-server-env -n <ns> -o jsonpath='{.data.TS_KAFKA_ON}'
   # 期望：false（空 / NotFound => 先 apply base；守卫在对空气设防）
   ```
   🔴 但 `TS_KAFKA_ON` 只是 OSS octo-server 的开关。在 fork/dmwork 部署里，真正运行的内置 producer 可能是另一个 workload（例如 IM 后端自己 `tsdd.yaml` 里的 `kafka.on`），守卫**看不到**——启用前确认每一个内置 producer 都关了，不只是 `TS_KAFKA_ON`。
3. CDC（`octo-messages-sync`）已停或已做替换-vs-共存决策——见上文 CDC 双写警告。守卫看不到 CDC。
4. producer cursor 已 seed 到当前高水位，否则 producer 会重新推流历史（完全重载）。
5. 私有 TCR image-pull Secret 存在于目标 namespace 且被 manifest 引用。默认是 `tcr-image-xtiao`（参考集群上存在）；在任何其它集群创建 secret 并用 overlay patch 覆盖名字——见上文"私有 TCR pull secret"。缺了它 → `ImagePullBackOff`，pod 永不启动。

### Apply（初始，仍 OFF）

```bash
kubectl apply -k kustomize/search -n <ns>
```

这会创建 `replicas: 0` 的 `searchetl-producer` Deployment（无 pod）并**把 es-indexer 重启到固定的 TCR digest**（一个镜像、两个二进制——见上文 apply 连带效应）。继续前确认 es-indexer 恢复 healthy。

### 启用（真正的切换）

在 `searchetl-producer.yaml` 里**两个**开关一起翻转，再重新 apply：

```bash
# searchetl-producer.yaml: spec.replicas: 0 -> 1
#                          PRODUCER_ENABLED: "false" -> "true"
kubectl apply -k kustomize/search -n <ns>
kubectl rollout status deploy/searchetl-producer -n <ns>
```

scale up 时 `producer-mutex-guard` init 容器先跑：若 `TS_KAFKA_ON` 为真它 exit 1，pod 永不到 Running（fail-closed 互斥）。`TS_KAFKA_ON=false` 时它记 `[guard] ok` 并起 producer。

### 回滚路径

- **producer 还没写任何东西前**（或要停止产出）：scale down——`kubectl scale deploy/searchetl-producer --replicas=0 -n <ns>`（或设 `replicas: 0` + `PRODUCER_ENABLED=false` 再 apply）。pod 停止。
- **数据层状态不由 k8s 回滚。** 一旦 producer 推进了 cursor / 写了 Kafka / DLQ / Redis，scale down 或还原 manifest **不会**撤销它。数据层回滚（cursor reset、topic purge）是另一件单独、刻意的事。
- **es-indexer 联动**：还原 `kustomization.yaml` 里的镜像 digest 并重新 apply 也会把 es-indexer 一起重启——共享镜像 digest 每次变更都要预留一次短暂的 es-indexer 重启。

### es-indexer 共动（提示）

因为 producer 和 es-indexer 共享一个镜像名覆盖，**每次 `kubectl apply -k kustomize/search` 也会重新 reconcile es-indexer**。改 digest、apply、回滚都意味着一次 es-indexer pod 重启。这是刻意的（两个二进制必须锁步），但意味着 es-indexer 从来不是 producer 切换的无副作用旁观者。
