# ADR 004: Bootstrap ArgoCD with Helm install, not Kustomize Helm inflation

Status: Accepted
Date: 2026-07-05

## Context

ArgoCD is the one component Argo cannot manage itself, so it is installed by
hand from the Makefile. We considered two ways to run that install:

- `helm upgrade --install` with a values file.
- Kustomize's Helm chart inflation (`kustomize build --enable-helm | kubectl
  apply -f -`), with the chart vendored into git. This is the pattern used in
  our other project, camino.

The difference that matters: Kustomize inflation uses Helm only as a
build-time template renderer. No Helm release is stored in the cluster.
`helm list` shows nothing, and `helm rollback` and `helm history` are not
available. Helm is decoupled from the runtime.

## What is NOT a reason (rejected decision points)

Both approaches put everything in git. Both are reconciled the same way once
Argo is up. "One repo is more GitOps than the other" is not a real difference,
so it was rejected as a decision point. The ArgoCD bootstrap sits outside
Argo's reconcile loop in either case, by definition, because Argo cannot
install itself. We record this rejection on purpose, so the reasoning trail is
clear and nobody re-opens the choice on the wrong grounds.

## The actual decision axes

1. Reproducibility across machines, CI, or offline. Vendored Kustomize+Helm
   gives deterministic, offline-capable builds. This lab is applied from one
   laptop, one environment, no CI, no air-gap. The benefit is close to zero
   here.
2. Tool consistency within this repo. The workloads Argo manages (Grafana,
   later Tempo, Loki, Mimir, the Collector) use Argo's own Helm source, not
   Kustomize. Using Kustomize for the bootstrap would make it the one odd
   component that pulls in a second tool. Helm install keeps the tool count
   lower.
3. The bootstrap is hand-run and repeated on every reset (`make clean` then
   `make step1`). For that one imperative step, `helm upgrade --install` is
   idempotent and `helm rollback` is available while iterating.
4. Learning focus. This repo exists to learn OpenTelemetry and the LGTM stack.
   Vendoring the ArgoCD chart (100+ files) and adding Kustomize spends the
   repo's complexity budget on GitOps plumbing instead of observability.

## When to use which

This generalises the choice so it is reusable, not tied to this one repo.

Reach for `helm upgrade --install` when:

- The component is bootstrap or imperative, run by hand or a simple script,
  and sits outside a GitOps reconcile loop. ArgoCD installing itself is the
  classic case. So are cluster addons you need up before Argo exists.
- You want release lifecycle in the cluster: `helm rollback`, `helm history`,
  atomic upgrades (`--atomic`), and a single `helm list` view of what is
  installed.
- The chart relies on Helm hooks for correctness (pre-install jobs, CRD
  install ordering, secret generation, test hooks). Hooks only run under real
  Helm.
- The environment is single or disposable and reproducibility across machines
  or CI is not a concern.
- The rest of the stack is not Kustomize-based, so Helm keeps the tool count
  low.

Reach for Kustomize + Helm inflation when:

- The whole platform is already rendered through Kustomize and you want one
  tool and one build command across every component.
- You need deterministic, offline or air-gapped, reproducible builds. The
  chart is vendored into git and applied from CI or several machines.
- You want the rendered output diffable in pull requests (chart changes show
  up on upgrade).
- You want git to be the single source of truth with no in-cluster Helm
  release state to reconcile against. Rollback becomes git revert plus
  reapply.
- You need to patch chart output in ways the chart's values do not expose
  (strategic-merge or JSON6902 patches on the rendered manifests).
- The resource is reconciled by a controller (for example an Argo Application
  pointing at a Kustomize directory), so the missing `helm rollback` does not
  matter.

The one hard caveat: Kustomize inflation does not run Helm hooks as hooks.
They become plain manifests. For a hook-heavy chart this can silently break
install ordering or secret generation. When a chart leans on hooks, prefer
real Helm.

## Decision

Install ArgoCD with `helm upgrade --install` from the Makefile (`make
argocd`), values in `k8s/argocd/install/values.yaml`. Do not vendor the chart.
Do not use Kustomize Helm inflation for the bootstrap.

This decision is about this repo's constraints, not about camino being right or
wrong. Camino's Kustomize+Helm choice fits camino's own constraints. If those
constraints ever appear here (multiple environments, CI applying the bootstrap,
a need for offline builds, or a deliberate choice to match camino's house
style), revisit this. The switch is mechanical: replace the helm install with a
kustomization.yaml using `helmCharts` and change the Makefile target.

## Consequences

- The bootstrap depends on the argo-helm repo being reachable at install time.
  Acceptable for a local lab.
- A Helm release for ArgoCD exists in the cluster; `helm rollback` is available
  for the bootstrap.
- Argo-managed workloads are unaffected. How the bootstrap is installed is a
  separate concern from how Argo syncs Grafana and the rest.

## Addendum (2026-07): re-evaluated for the whole stack, still pure Helm

Step 5 nearly pulled Kustomize into the stack (a `configMapGenerator` for the
ruler rules). That prompted a wider re-check: should the platform move to
Kustomize + Helm inflation for the flexibility of patching rendered chart output?

Conclusion: no, stay pure Helm plus raw manifests. The reasoning that decided it:

- **The flexibility is real but unused here.** Through Steps 0 to 5, no component
  needed a field that its chart's `values.yaml` does not expose. Every backend was
  configured through values alone.
- **These charts already cover the usual gaps.** The LGTM charts and the Collector
  chart expose `extraContainers`, `extraVolumes`, env, resources, nodeSelector, and
  even raw snippets (for example `gateway.nginx.config.serverSnippet` on
  mimir-distributed, or `grafana.ini` fully open). Most "the chart blocks me" cases
  are really "the value exists, not found yet."
- **Adopting it now would be over-design.** Bringing in a second render tool for a
  need that has not appeared trades a concrete cost (a second layer per component,
  plus the hook-semantics caveat above) for a hypothetical benefit.
- **Half-way is the worst option.** One Kustomize app among Helm and raw-manifest
  apps is the odd tool out this ADR warns about. So the rules ship as a raw
  ConfigMap (rules inline, the same as the datasource and dashboard ConfigMaps),
  not through Kustomize.

### When it IS worth switching to Helm + Kustomize

Reach for it when a real need appears, not before. Concretely, switch when:

- **You need to change a field a chart hardcodes and does not expose**, and there
  is no `extra*` value or snippet that reaches it. Confirm by rendering the chart
  first (`helm template`) and checking the value surface, so the switch is driven
  by a real gap, not a guess.
- **You need subtractive edits.** Removing a field, annotation, or resource the
  chart always emits. Values can only add or override, not delete; Kustomize
  `$patch: delete` or a JSON6902 `remove` can.
- **You need one label or annotation across every rendered object, including
  subchart output** (for a NetworkPolicy selector, OPA, or cost allocation). Charts
  only label what their own templates label; Kustomize `labels:` /
  `commonAnnotations:` blanket the whole build, subcharts included.
- **A subchart value the parent does not pass through** must be set (for example a
  minio or kafka field mimir-distributed does not surface).

If one of these lands, switch that component (or, if several land close together,
the whole stack) deliberately, and record it. Two operational preconditions:
ArgoCD needs `kustomize.buildOptions: --enable-helm` in its config to inflate
charts, and any hook-dependent chart (cert-manager is the likely one here) must be
rendered and checked, because inflation turns Helm hooks into plain manifests.
