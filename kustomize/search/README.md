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

1. Confirm the base Secret `octo-server-secret` already exists in the target
   namespace — the producer's `PRODUCER_MYSQL_DSN` / `PRODUCER_REDIS_ADDR` are
   **required** `secretKeyRef`s and the pod will not start without it.
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

Two limits this guard does **not** cover (operator responsibility):

- **Single-direction**: it only blocks *standalone start-up while the built-in
  is on*. It does **not** block the reverse — starting/rolling out octo-server
  with `TS_KAFKA_ON=true` while the standalone is already running. (True
  bidirectional guarding would require touching `kustomize/base`, out of scope.)
- **Point-in-time**: the init container runs only at pod start. Flipping
  `TS_KAFKA_ON` to on **while the producer is already Running** does not
  re-trigger the check — verify this manually before changing the toggle.

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

The producer is the first workload in this directory to consume
`DM_MYSQL_DSN`, so it gets DB privileges equivalent to octo-server. A
least-privilege Secret / RBAC narrowing is a follow-up, not done here.

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

1. `octo-server-secret` exists in the target namespace (provides
   `DM_MYSQL_DSN` / `DM_REDIS_ADDR` the producer needs).
2. Built-in producer is OFF: `TS_KAFKA_ON=false` in ConfigMap
   `octo-server-env` (the default shipped here). The init mutex guard reads
   this key — if it is truthy, the producer pod's init container exits 1.
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
