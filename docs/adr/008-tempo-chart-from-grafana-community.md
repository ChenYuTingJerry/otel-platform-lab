# ADR 008: Tempo chart comes from grafana-community, not grafana

Status: Accepted
Date: 2026-07-06

## Context

Step 2b deploys Tempo in single-binary mode from a Helm chart. The obvious
source is the `grafana/tempo` chart, which the verification runbook named when
Step 2 was first written.

While building the step, `helm template` printed `this chart is deprecated`. The
chart's `Chart.yaml` sets `deprecated: true`. The reason is not that
single-binary mode is going away. It is a repository move: the chart migrated
from `grafana/helm-charts` to `grafana-community/helm-charts`. The chart's own
README says updates and support move to the new repository after 2026-01-30.
Today is past that date, so `grafana/tempo` is frozen at chart 1.24.4 (Tempo
2.9.0), and the maintained chart lives at `grafana-community/tempo` (2.2.3,
Tempo 2.10.7 at the time of writing).

Both charts are the same single-binary Tempo. Our values render cleanly against
either.

## Decision

Point the Tempo Application at **`grafana-community/tempo`** (repoURL
`https://grafana-community.github.io/helm-charts`), pinned to chart 2.2.3.

Do not use the deprecated `grafana/tempo` chart.

## Consequences

- Argo syncs Tempo without a deprecation warning, and we get a newer Tempo
  (2.10.7 vs 2.9.0) that still receives updates.
- This is a new chart repository, so it is less battle-tested as a URL and
  carries the usual community-repo caveat (community-maintained, not vendor).
  For a lab that trade is fine.
- The chart version is pinned, so nothing moves under us. Bumping it is a
  deliberate edit to the Application, same as every other pinned chart here.
- Anyone following older Tempo tutorials will see `grafana/tempo`. This ADR is
  the record of why we diverged, so the deprecated reference does not creep
  back in.
