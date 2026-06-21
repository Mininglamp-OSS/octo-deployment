# Search pipeline (opt-in, standalone)

Kafka + OpenSearch (analysis-ik) + es-indexer for the OCTO message-search
pipeline. This kustomization is **intentionally not referenced** by
`kustomize/base` or any overlay — applying the default base/overlays deploys
zero search resources. It is additive and opt-in.

## Apply (owner-gated for shared environments)

```bash
kubectl apply -k kustomize/search -n <ns>
```

## Before applying

1. **OpenSearch image with IK**: build `docker/opensearch/Dockerfile`
   (OpenSearch + `analysis-ik`, versions pinned in lockstep), push to your
   registry, and set the `octo-search-opensearch-ik` image tag in
   `kustomization.yaml`.
2. **es-indexer / searchetl-producer image**: shared one image, two binaries.
   Already pinned in `kustomization.yaml` to a Tencent TCR **digest** (the
   registry the dmwork-test cluster pulls from) — see "Image: pinned to a TCR
   digest" below. Repoint the digest there to roll forward; do not use a
   floating tag for production.
3. **Private TCR pull secret**: the image lives in a **private** Tencent TCR, so
   the target namespace MUST already hold an image-pull Secret and the manifests
   MUST reference it (they do — see "Private TCR pull secret" below). Without it
   both pods `ImagePullBackOff` and never start.
4. **Topics**: created automatically by the `search-kafka-init` Job (the k8s
   equivalent of the compose init service) — required because broker
   auto-create is off and the indexer's DLQ producer uses
   `AllowAutoTopicCreation=false`. The Job waits for the broker, then creates
   `octo.message.v1` and `octo.message.v1.dlq` idempotently. To stage them
   manually instead (e.g. different partition counts):
   ```bash
   kubectl exec -n <ns> statefulset/search-kafka -- \
     /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
     --create --if-not-exists --topic octo.message.v1 --partitions 1 --replication-factor 1
   kubectl exec -n <ns> statefulset/search-kafka -- \
     /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
     --create --if-not-exists --topic octo.message.v1.dlq --partitions 1 --replication-factor 1
   ```

## Resources

- `search-kafka.yaml` — Kafka (KRaft single broker) StatefulSet + headless Service.
- `search-kafka-init.yaml` — one-shot Job creating the body + DLQ topics.
- `search-opensearch.yaml` — OpenSearch (single node, IK) StatefulSet + headless Service.
- `es-indexer.yaml` — es-indexer Deployment (DLQ spill on a PVC).
- `searchetl-producer.yaml` — standalone producer Deployment (opt-in, default OFF; no PVC, no probe).
- `search-pvc.yaml` — PVCs: OpenSearch data, Kafka data, DLQ spill.

The DLQ-spill PVC is required: without durable spill storage the indexer's
crash-resumable DLQ accounting is defeated on a pod restart.

## Standalone searchetl-producer (opt-in, default OFF)

`searchetl-producer.yaml` ships a standalone producer that reads MySQL and
writes the message-search topic (`octo.message.v1`). It is the **replacement
binary** for octo-server's built-in producer (the `TS_KAFKA_ON` toggle) — they
share the cursor and Redis lock, so running both double-writes Kafka. It shares
the `mininglamposs/octo-search-indexer` image with es-indexer (one image, two
binaries); the Deployment overrides the entrypoint to `searchetl-producer`.

It is shipped **OFF**: `replicas: 0` **and** `PRODUCER_ENABLED=false` (double
opt-in). Applying this directory creates the Deployment but no pod.

### Enable checklist (owner-gated)

Enabling is a deliberate, owner-gated action with data-layer consequences:

1. Create the dedicated Secret `searchetl-producer-secret` in the target
   namespace — copy `searchetl-producer-secret.example.yaml` to
   `searchetl-producer-secret.yaml`, fill in `PRODUCER_MYSQL_DSN` /
   `PRODUCER_REDIS_ADDR`, then `kubectl apply -f`. These are **required**
   `secretKeyRef`s and the pod will not start without them
   (`CreateContainerConfigError`). 🔴 The DSN MUST point at the **live message
   DB** the IM backend writes to (the DB whose `message` 5-shard tables the
   producer polls — NOT necessarily the DB octo-server itself points at), and
   `PRODUCER_REDIS_ADDR` MUST be the **same Redis the built-in producer uses**
   so the shared run-lock actually achieves mutual exclusion.
2. Confirm the producer cursor is seeded to the current high-water mark —
   otherwise the producer re-streams history (a full reload).
3. Flip **both** switches together: set `replicas: 1` **and**
   `PRODUCER_ENABLED=true`. Changing only one leaves you either with a
   Deployment that is Running but produces nothing, or a guard that passed but
   a workload idling — neither produces messages.

> **Single-pod design — `replicas > 1` is not supported.** This is a
> single-active-producer workload: the app-layer Redis run-lock + cursor CAS
> serialize work to one producer, so a second replica would idle on the lock at
> best (and any contention is wasted/risk). Keep `replicas: 1` when enabled.
> The Deployment uses `strategy: Recreate` (not the default RollingUpdate) so an
> image/env rollout tears the old pod down before starting the new one, instead
> of briefly running two producer pods — the init mutex guard only blocks the
> built-in producer, not a same-Deployment overlap.

### Mutual-exclusion guard (and its limits)

The pod runs an init container (`producer-mutex-guard`) that reuses the same
`is_on()` union truthy logic as the compose `search-producer-guard`
(`1|t|true|on|yes`, fail-closed). If the built-in producer (`TS_KAFKA_ON` in
ConfigMap `octo-server-env`) is also truthy, the init container exits 1 and the
producer pod never reaches Running.

Three limits this guard does **not** cover (operator responsibility):

- **Single-direction**: it only blocks *standalone start-up while the built-in
  is on*. It does **not** block the reverse — starting/rolling out octo-server
  with `TS_KAFKA_ON=true` while the standalone is already running. (True
  bidirectional guarding would require touching `kustomize/base`, out of scope.)
- **Point-in-time**: the init container runs only at pod start. Flipping
  `TS_KAFKA_ON` to on **while the producer is already Running** does not
  re-trigger the check — verify this manually before changing the toggle.
- **Depends on base's ConfigMap existing in the target namespace.** This
  overlay only *references* `octo-server-env` (an `optional: true`
  `configMapKeyRef`); it does **not** define it. `optional: true` means a
  missing ConfigMap/key is treated as `BUILTIN_ON=false`, so applying this
  directory **on its own** into a namespace that does not already have base's
  `octo-server-env` silently degrades the guard to a no-op — it logs
  `[guard] ok` and starts the producer regardless of the real built-in state.
  The guard only protects you if `octo-server-env` (from `kustomize/base`)
  already lives in the same namespace. **Before cut-over, confirm the
  ConfigMap is present and carries `TS_KAFKA_ON`:**
  ```bash
  kubectl get configmap octo-server-env -n <ns> -o jsonpath='{.data.TS_KAFKA_ON}'
  ```
  An empty/`NotFound` result means the guard is armed against nothing — apply
  base (or otherwise ensure `octo-server-env` exists in `<ns>`) first.

### 🔴 CDC double-write warning

dmwork-test runs `octo-messages-sync` (CDC binlog → Kafka) writing the **same**
topic `octo.message.v1`. That CDC pipeline is **not** in this kustomize tree, so
this guard cannot see it and cannot mechanically prevent a standalone↔CDC
double-write. **Do not enable this standalone producer in an environment where
CDC is running until you have stopped CDC or decided replace-vs-coexist.**

### 🔴 apply knock-on: es-indexer gets bounced

`kustomization.yaml` pins `mininglamposs/octo-search-indexer` to a Tencent TCR
digest (`tbj7-xtiao-tcr1.tencentcloudcr.com/xtiao-release/dmwork/octo-search-indexer@sha256:…`)
for the whole directory. Because the override is by image name, applying this
directory will also bounce any already-running **es-indexer** onto that digest
(one image, two binaries — they are meant to stay in lockstep).

### Rollback is data-layer, not k8s-layer

Once the producer has run and advanced the cursor / written Kafka, simply
scaling down or reverting the manifest does **not** roll back the Kafka / DLQ /
Redis cursor state. Data-layer rollback is a separate exercise.

### Credentials surface

The producer reads the live message DB directly, so its DSN
(`searchetl-producer-secret`) carries DB privileges over that data. It uses its
own dedicated Secret rather than borrowing octo-server-secret — this keeps the
producer's DB/Redis target explicit and decoupled from octo-server's own
connection (which may point at a different DB).

#### 🔴 Gotcha: the producer needs DDL on its cursor table — a SELECT-only account is NOT enough

The producer **owns** the cursor table `octo_etl_es_cursor` (it stores the
per-shard polling watermark). At startup `searchetl-producer` runs
`CREATE TABLE IF NOT EXISTS octo_etl_es_cursor` (`internal/producer/source.go`
`EnsureSchema`, called unconditionally from `cmd/searchetl-producer/main.go`),
then per shard `INSERT IGNORE` a seed row and `UPDATE ... SET last_id=...` to
advance. So the DB account needs more than read access:

| Producer operation (code) | SQL | Privilege |
|---|---|---|
| `EnsureSchema` (startup) | `CREATE TABLE IF NOT EXISTS octo_etl_es_cursor` | **CREATE** on the cursor table |
| `EnsureCursor` | `INSERT IGNORE INTO octo_etl_es_cursor` | **INSERT** on the cursor table |
| `AdvanceCursor` | `UPDATE octo_etl_es_cursor SET last_id=…` | **UPDATE** on the cursor table |
| `ReadStableBatchTx` | `SELECT … FOR UPDATE` (cursor) + `SELECT …` (message shards) | **SELECT** on `im_test.*` |

> **`CREATE TABLE IF NOT EXISTS` still requires the CREATE privilege even when
> the table already exists** — MySQL checks the privilege before evaluating
> `IF NOT EXISTS`. So you cannot drop CREATE just because a prior run created the
> table.

This is the trap that bit YUJ-5206 acceptance: reusing the CDC replication
account (`cdc_repl`, which has only `SELECT ON im_test.*` + REPLICATION) made the
pod crash on startup with `Error 1142 (42000): CREATE command denied to user
'cdc_repl'@'…' for table 'octo_etl_es_cursor'`. REPLICATION privileges are
irrelevant here — the standalone producer is a SQL poller, **not** a binlog
replica.

#### Least-privilege account (run on the LIVE message DB instance — owner/DBA only)

> 🔴 **Titan does not execute this.** Creating the user and granting privileges
> on the message DB (`10.208.14.23:3306`) is an owner/DBA action — Yu (or the
> DBA) runs it manually after review. The SQL below is the spec, not a step this
> repo performs.

```sql
-- Run as a MySQL admin on the LIVE message DB instance (10.208.14.23:3306).
-- Dedicated least-privilege account for searchetl-producer.
-- Do NOT reuse cdc_repl (replication account, SELECT-only — no DDL) and do NOT
-- leave root in the Secret (blast radius too large).
CREATE USER 'searchetl_prod'@'%' IDENTIFIED BY '<STRONG_PASSWORD>';

-- Read the message shard tables (message, message1..message4) the producer polls.
-- This also covers the SELECT/FOR-UPDATE read of octo_etl_es_cursor.
GRANT SELECT ON im_test.* TO 'searchetl_prod'@'%';

-- The producer OWNS its cursor table octo_etl_es_cursor:
--   CREATE -> EnsureSchema: CREATE TABLE IF NOT EXISTS at startup
--   INSERT -> EnsureCursor: INSERT IGNORE seed row per shard
--   UPDATE -> AdvanceCursor: UPDATE ... SET last_id=...
--   (SELECT already covered by the im_test.* grant above)
GRANT CREATE, INSERT, UPDATE ON im_test.octo_etl_es_cursor TO 'searchetl_prod'@'%';

FLUSH PRIVILEGES;
```

Nothing else is needed (`宁缺勿滥`): no `ALTER`, `INDEX`, `DROP`, `DELETE`, or
any `REPLICATION` privilege. If you prefer to scope reads more tightly than
`im_test.*`, replace that line with table-level `SELECT` on the five message
shards (`message`, `message1`..`message4`) plus the cursor table; `'%'` host can
likewise be narrowed to the cluster's pod CIDR.

#### Switching the Secret to the dedicated account

Only the credential part of `PRODUCER_MYSQL_DSN` changes — **host, database, and
query params stay identical** (same live message DB, same `octo_etl_es_cursor`):

```
# before (temporary, retire this):
PRODUCER_MYSQL_DSN: "root:<pwd>@tcp(10.208.14.23:3306)/im_test?charset=utf8mb4&parseTime=true&loc=Local"
# after:
PRODUCER_MYSQL_DSN: "searchetl_prod:<pwd>@tcp(10.208.14.23:3306)/im_test?charset=utf8mb4&parseTime=true&loc=Local"
```

Apply the updated Secret, then restart the producer so it picks up the new env:

```bash
kubectl apply -n <ns> -f searchetl-producer-secret.yaml
kubectl rollout restart deploy/searchetl-producer -n <ns>   # only if a pod is running
```

After verification, retire the temporary root credential: scale the producer to
`replicas: 0` + `PRODUCER_ENABLED=false`, and remove the root DSN from the
Secret entirely (do not leave root in `searchetl-producer-secret`).

### Image: pinned to a TCR digest

`kustomization.yaml` pins `mininglamposs/octo-search-indexer` to a Tencent TCR
digest:

```
tbj7-xtiao-tcr1.tencentcloudcr.com/xtiao-release/dmwork/octo-search-indexer@sha256:97c781154e1c9588deab7af29d6b7cb041188a072621122821391ac90272c7a0
```

- **Why TCR, not Docker Hub**: the dmwork-test (xiaotiao-tke) cluster pulls from
  Tencent TCR; the es-indexer already running there is pinned by digest the same
  way. Docker Hub (`mininglamposs/*`) is the GitHub `docker-publish.yml` track
  and is a *separate* lane the cluster does not pull from.
- **Why a digest, not a tag**: immutable + reproducible. The registry also
  carries the human-readable `:v0.1.0` (git release) and `:94864fc`
  (commit-hash) tags pointing at this same digest, but the manifest pins the
  digest so a tag re-push can never silently change what is deployed.
- **What it is**: the image built from octo-search-indexer origin/main `94864fc`
  (git tag `v0.1.0`), containing all four binaries (es-indexer +
  searchetl-producer among them).

To roll the image forward, repoint the digest here (and, if needed, push a new
`:vX.Y.Z` / `:<commit>` tag to TCR) — do not switch back to a floating tag.

### Private TCR pull secret

The image lives in a **private** Tencent TCR
(`tbj7-xtiao-tcr1.tencentcloudcr.com/...`), so every pod that runs it needs an
image-pull Secret. Both `es-indexer.yaml` and `searchetl-producer.yaml` declare:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: tcr-image-xtiao
```

- **Why it is required**: without a pull secret the kubelet cannot authenticate
  to the private registry — the pod `ImagePullBackOff`s and never starts. This is
  exactly the P1 found on dmwork-test: the raw `es-indexer` manifest running there
  carried `imagePullSecrets` (the `tcr-image-xtiao` secret) while the kustomize
  render did not, so the kustomize-managed producer would never have come up.
- **Default `tcr-image-xtiao`**: this is the secret that exists on the
  dmwork-test (xiaotiao-tke) cluster — the same cluster the digest above is
  pinned for — so the default is self-consistent.
- **🔴 Per-cluster override**: the secret name is **cluster-specific**. On any
  other cluster you MUST (a) create the pull secret in the target namespace and
  (b) override the name here. Prefer an overlay patch rather than editing this
  base, e.g.:
  ```yaml
  # kustomize/overlays/<cluster>/imagepullsecret-patch.yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: es-indexer          # repeat for searchetl-producer
  spec:
    template:
      spec:
        imagePullSecrets:
          - name: <your-cluster-tcr-secret>
  ```
  Create the secret with, for example:
  ```bash
  kubectl create secret docker-registry <your-cluster-tcr-secret> \
    --docker-server=tbj7-xtiao-tcr1.tencentcloudcr.com \
    --docker-username=<user> --docker-password=<token> -n <ns>
  ```

## Cut-over runbook (owner-gated; this PR does NOT cut over)

> ⚠️ This directory ships **double-OFF** (`replicas: 0` **and**
> `PRODUCER_ENABLED=false`) and `octo-server-env` ships `TS_KAFKA_ON=false`.
> Nothing here applies or rolls anything out. The steps below are the path Yu
> takes **after** explicit authorization — they are documentation, not an action
> this PR performs.

### Preconditions

1. `searchetl-producer-secret` exists in the target namespace (provides
   `PRODUCER_MYSQL_DSN` / `PRODUCER_REDIS_ADDR` — the live message DB DSN and
   the shared-lock Redis addr the producer needs). See the Enable checklist.
2. Built-in producer is OFF. The init mutex guard reads `TS_KAFKA_ON` from
   ConfigMap `octo-server-env` (the default shipped here is `false`).
   **The ConfigMap must actually exist in `<ns>`** — this overlay only
   references it (`optional: true`), so a missing `octo-server-env` makes the
   guard a no-op (see "Mutual-exclusion guard" above). Confirm:
   ```bash
   kubectl get configmap octo-server-env -n <ns> -o jsonpath='{.data.TS_KAFKA_ON}'
   # expect: false  (empty / NotFound => apply base first; the guard is armed against nothing)
   ```
   🔴 But `TS_KAFKA_ON` is only the OSS octo-server's toggle. In a fork/dmwork
   deployment the real running built-in producer may be a different workload
   (e.g. the IM backend's own `kafka.on` in its `tsdd.yaml`) that the guard
   CANNOT see — confirm every built-in producer is off before enabling, not
   just `TS_KAFKA_ON`.
3. CDC (`octo-messages-sync`) is stopped or a replace-vs-coexist decision is
   made — see the CDC double-write warning above. The guard cannot see CDC.
4. The producer cursor is seeded to the current high-water mark, otherwise the
   producer re-streams history (full reload).
5. The private-TCR image-pull Secret exists in the target namespace and is
   referenced by the manifests. The default is `tcr-image-xtiao` (present on
   dmwork-test); on any other cluster create the secret and override the name
   via an overlay patch — see "Private TCR pull secret" above. Missing this →
   `ImagePullBackOff`, the pod never starts.

### Apply (initial, still OFF)

```bash
kubectl apply -k kustomize/search -n <ns>
```

This creates the `searchetl-producer` Deployment at `replicas: 0` (no pod) and
**bounces es-indexer onto the pinned TCR digest** (one image, two binaries — see
the apply knock-on note above). Confirm es-indexer comes back healthy before
proceeding.

### Enable (the actual cut-over)

Flip **both** switches together in `searchetl-producer.yaml`, then re-apply:

```bash
# searchetl-producer.yaml: spec.replicas: 0 -> 1
#                          PRODUCER_ENABLED: "false" -> "true"
kubectl apply -k kustomize/search -n <ns>
kubectl rollout status deploy/searchetl-producer -n <ns>
```

On scale-up the `producer-mutex-guard` init container runs first: if
`TS_KAFKA_ON` is truthy it exits 1 and the pod never reaches Running (fail-closed
mutual exclusion). With `TS_KAFKA_ON=false` it logs `[guard] ok` and the
producer starts.

### Rollback path

- **Before the producer has written anything** (or to stop producing): scale
  down — `kubectl scale deploy/searchetl-producer --replicas=0 -n <ns>` (or set
  `replicas: 0` + `PRODUCER_ENABLED=false` and re-apply). The pod stops.
- **Data-layer state is NOT rolled back by k8s.** Once the producer has advanced
  the cursor / written Kafka / DLQ / Redis, scaling down or reverting the
  manifest does **not** undo that. Data-layer rollback (cursor reset, topic
  purge) is a separate, deliberate exercise.
- **es-indexer linkage**: reverting the image digest in `kustomization.yaml` and
  re-applying will also bounce es-indexer back — plan for a brief es-indexer
  restart whenever the shared image digest changes.

### es-indexer co-movement (call-out)

Because producer and es-indexer share one image-name override, **every
`kubectl apply -k kustomize/search` re-reconciles es-indexer too**. Changing the
digest, applying, or rolling back all imply an es-indexer pod restart. This is
intentional (the two binaries must stay in lockstep) but means es-indexer is
never a no-op bystander of a producer cut-over.
