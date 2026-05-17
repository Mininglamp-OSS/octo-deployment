# OCTO · Kubernetes (kustomize)

Multi-node Kubernetes deployment for the OCTO platform. This directory
is the canonical reference for running OCTO with a real ingress
controller, multi-replica workloads, and externally-provisioned
backing services (MySQL / Redis / WuKongIM / S3-compatible object
storage).

> 中文版：[README.zh.md](./README.zh.md)
>
> For a **single-node Docker Compose** trial, use the [`../docker/`](../docker/)
> tree at the repo root instead — it bundles everything into one
> `docker compose up -d`. This `kustomize/` tree is the multi-node
> Kubernetes path.

## Quick start

Full walkthrough lives in the [top-level `README.md`](../README.md)
under "Quick Start (Kubernetes path)". The short version:

```bash
kubectl create namespace octo

cd kustomize/base
for f in *-secret.example.yaml; do cp "$f" "${f/.example/}"; done
$EDITOR octo-*-secret.yaml         # replace every CHANGE_ME_*

kubectl apply -n octo \
  -f octo-server-secret.yaml \
  -f octo-matter-secret.yaml \
  -f octo-smart-summary-secret.yaml

kubectl apply -n octo -k .
```

For environment-specific overrides:

```bash
kubectl apply -n octo-dev  -k kustomize/overlays/dev
kubectl apply -n octo-prod -k kustomize/overlays/prod
```

Preview the rendered manifests without applying:

```bash
kubectl kustomize kustomize/base
```

## Layout

```
kustomize/
├── base/                       Generic OSS templates (canonical reference)
│   ├── kustomization.yaml      Pulls all resources, applies image transformer
│   ├── octo-*.yaml             Deployments + Services
│   ├── octo-*-config.yaml      ConfigMaps (non-sensitive)
│   └── octo-*-secret.example.yaml
│                               Secret templates with CHANGE_ME_* placeholders
└── overlays/
    ├── dev/                    Image tag = "dev"
    └── prod/                   Multi-replica production overlay
```

## Open items

- [ ] Ingress / Gateway example for `octo-web` + `octo-admin`
- [ ] In-cluster MinIO + WuKongIM sample manifests
- [ ] APNS `.p8` key mounting documentation

See the [top-level `README.md`](../README.md) for the full secrets
contract, image-registry override pattern, and component reference.
