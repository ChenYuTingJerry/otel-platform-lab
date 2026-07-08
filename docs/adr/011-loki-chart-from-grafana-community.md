# ADR 011: Loki chart comes from grafana-community, not grafana

Status: Accepted
Date: 2026-07-08

## Context

Step 3 deploys Loki in SingleBinary mode from a Helm chart. There are two
charts to choose from, and they are the same chart family (both name `loki`,
both list `github.com/grafana/loki` as source, both support monolithic mode):

- `grafana/loki`, chart 7.0.0, appVersion 3.6.7. Home on the `grafana`
  Helm repo, maintained by Grafana Labs staff.
- `grafana-community/loki`, chart 18.4.2, appVersion 3.7.3. Home on the
  `grafana-community` Helm repo, community-maintained.

This is the same repository move that ADR-008 hit with Tempo: the community
Helm charts moved from `grafana/helm-charts` to `grafana-community/helm-charts`,
and the maintained line now lives in the new repo with a newer appVersion.

One difference from Tempo: `grafana/loki` 7.0.0 is **not** flagged
`deprecated: true` in its `Chart.yaml`, while `grafana/tempo` was. So there is
no deprecation warning forcing the move here. The choice is about consistency
and staying on the maintained line, not about dodging a warning.

Both charts render our SingleBinary values cleanly.

## Decision

Point the Loki Application at **`grafana-community/loki`** (repoURL
`https://grafana-community.github.io/helm-charts`), pinned to chart 18.4.2.

Do not use `grafana/loki`.

## Consequences

- Loki matches Tempo: both backends come from `grafana-community`, one repo, one
  mental model.
- We run a newer Loki (3.7.3 vs 3.6.7) that still receives updates.
- Same community-repo caveat as ADR-008: community-maintained, not vendor. Fine
  for a lab.
- The chart version is pinned, so nothing moves under us. Bumping it is a
  deliberate edit to the Application.
- Unlike the Tempo case, `grafana/loki` is not deprecated, so older tutorials
  pointing at it are not "wrong", just the frozen line. This ADR records why we
  still diverged.
