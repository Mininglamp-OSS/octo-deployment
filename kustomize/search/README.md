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
2. **es-indexer image**: published only on `v*` tags / manual dispatch in
   octo-search-indexer — pin a real tag in `kustomization.yaml` (not a
   floating `latest` for production).
3. **Topics**: created automatically by the `search-kafka-init` Job (the k8s
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

`kustomization.yaml` pins `mininglamposs/octo-search-indexer` to `yuj5184` for
the whole directory. Because the override is by image name, applying this
directory will also bounce any already-running **es-indexer** onto `yuj5184`
(one image, two binaries — they are meant to stay in lockstep).

### Rollback is data-layer, not k8s-layer

Once the producer has run and advanced the cursor / written Kafka, simply
scaling down or reverting the manifest does **not** roll back the Kafka / DLQ /
Redis cursor state. Data-layer rollback is a separate exercise.

### Credentials surface

The producer is the first workload in this directory to consume
`DM_MYSQL_DSN`, so it gets DB privileges equivalent to octo-server. A
least-privilege Secret / RBAC narrowing is a follow-up, not done here.

### Not pinned to a digest

`yuj5184` is a tag (mutable), not a digest. A reproducible digest pin belongs
to the CICD (`v*` tag) work, not this manifest.
