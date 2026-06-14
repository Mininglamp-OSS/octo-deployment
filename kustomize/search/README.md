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
3. **Topics**: the indexer's DLQ producer uses `AllowAutoTopicCreation=false`.
   Pre-create `octo.message.v1` and `octo.message.v1.dlq` once Kafka is up,
   e.g.:
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
- `search-opensearch.yaml` — OpenSearch (single node, IK) StatefulSet + headless Service.
- `es-indexer.yaml` — es-indexer Deployment (DLQ spill on a PVC).
- `search-pvc.yaml` — PVCs: OpenSearch data, Kafka data, DLQ spill.

The DLQ-spill PVC is required: without durable spill storage the indexer's
crash-resumable DLQ accounting is defeated on a pod restart.
