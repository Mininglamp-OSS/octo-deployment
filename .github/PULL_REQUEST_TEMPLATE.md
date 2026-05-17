<!-- octo-deployment PR template -->

## Summary

<!-- 1–3 sentences: what changed and why. Link the tracking issue. -->

## Bilingual docs sync checklist

OOTB users land on the Chinese docs first. Any change to a `*.md` MUST
be reflected in the matching `*.zh.md` in the same PR.

- [ ] If I changed `README.md`, I updated `README.zh.md` (or it was not user-visible)
- [ ] If I changed `docker/README.md`, I updated `docker/README.zh.md`
- [ ] If I changed `kustomize/README.md`, I updated `kustomize/README.zh.md`
- [ ] If I added a new `.md` user-facing doc, I added the matching `.zh.md`
- [ ] N/A — this PR does not touch user-facing `*.md`

## OOTB doc audit (if this PR touches setup / nginx / compose / .env)

Paste the output (or "clean") so review can confirm no stale port /
URL / firewall references leaked through:

```bash
grep -rE "29000|OCTO_MINIO_API_PORT" --include="*.md" --include="*.yaml" --include="*.yml" --include="*.sh" --include="*.template" --include="*.env*"
grep -rE "TS_MINIO_DOWNLOADURL|MINIO_SERVER_URL" --include="*.md" --include="*.yaml" --include="*.yml" --include="*.template"
grep -rE "firewall|ufw allow|iptables" --include="*.md" --include="*.sh"
grep -rE "presign|SigV4|signed URL" --include="*.md"
grep -rE "127\.0\.0\.1|loopback|localhost" docker/ --include="*.env*" --include="*.yaml"
grep -rE "compose down -v|docker volume" --include="*.md" --include="*.sh"
```

- [ ] Audit clean / drift annotated above
- [ ] N/A — this PR does not touch deploy surface

## E2E

- [ ] Verified locally with `setup.sh --verify`
- [ ] Verified on a public-IP host (e.g. ephemeral GCP VM — **not** a
      live `im-test` / production stack; see INCIDENT-2026-05-16-001)
- [ ] Pure docs / CI / config change, no E2E required

## Notes

<!-- Anything reviewers should know: trade-offs, follow-ups, blocked-on. -->
