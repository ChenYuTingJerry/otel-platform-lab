# otel-platform-lab

An observability platform lab on Kubernetes. OpenTelemetry Collector as the
single telemetry ingress feeding an LGTM stack (Loki, Grafana, Tempo, Mimir).
Deployed on a local k3d cluster (Apple Silicon), managed by ArgoCD from
day one.

Current stage: Step 2 in progress. The OTel Operator (2a), Tempo with its
Grafana datasource (2b), and the Collector as the single ingress gateway (2c)
are in; the sample app and end-to-end trace (2d-2e) are next. Loki and Mimir
land in later steps.

## Prerequisites

- Docker Desktop (running)
- k3d 5.x
- kubectl
- helm
- gh (for the initial GitHub push, one-off)

## Quickstart

The build has one scaffold step (Step 0) plus four signal steps (1-4). Run them
in order; each is verified before the next. See
[docs/VERIFICATION.md](docs/VERIFICATION.md) for the per-step checks.

```
make step0    # scaffold: k3d cluster + ArgoCD
make step1    # bootstrap Grafana via ArgoCD (also brings up the OTel Operator)
make step2b   # Tempo backend + its Grafana datasource
make step2c   # OTel Collector, the single ingress gateway
```

- `make step0` runs `make cluster` (k3d cluster `otel-lab`, host ports 3000 for
  Grafana and 8081 for Argo, traefik off) then `make argocd` (helm installs
  ArgoCD). Argo lives on 8081 rather than 8080 because Docker Desktop reserves
  8080 on macOS.
- `make step1` runs `make bootstrap` (applies the root Application
  `k8s/argocd/root-app.yaml`). Argo then discovers the Grafana Application under
  `k8s/argocd/applications/` and syncs it into the `observability` namespace.

After Step 1:

- Argo UI:    http://localhost:8081  (user `admin`, password from `make argo-password`)
- Grafana UI: http://localhost:3000  (user `admin`, password `otel-lab-admin`
  or from `make grafana-password`)

## Layout

```
k8s/argocd/install/         Helm values for the ArgoCD install itself
k8s/argocd/root-app.yaml    App-of-apps, applied by `make bootstrap`
k8s/argocd/applications/    One Argo Application CR per platform component
k8s/manifests/<component>/  Helm values.yaml files that Argo reads
apps/                       Sample instrumented services (added in Step 2d)
config/                     Reserved. The Collector pipeline lives inline in
                            k8s/manifests/collector/values.yaml, not here.
docs/adr/                   Architecture decision records
docs/signal-strategy.md     How logs, metrics, and traces split work
```

## Build order

Each step is verified end-to-end before the next one starts.

- [x] Step 0 - Scaffold: k3d cluster + ArgoCD
1. [x] Step 1 - Grafana UI reachable via ArgoCD
2. [ ] Step 2 - OTel Collector + Tempo, traces from a sample app
3. [ ] Step 3 - Loki logs pipeline with trace_id to logs pivot
4. [ ] Step 4 - Mimir metrics (span metrics + direct)

## Design constraints (deliberate)

- Signal routing: logs carry high-cardinality context, metrics stay
  aggregate, traces handle latency and per-request performance.
- OTel Collector is the only telemetry ingress. Apps never talk to backends
  directly.
- Zero-code auto-instrumentation via the OTel Operator is preferred over
  manual SDK setup.
- GitOps-friendly, Argo-managed. See `docs/adr/003-argocd-from-day-one.md`.

## Cleaning up

```
make clean   # deletes the k3d cluster
```

## Admin credentials

These are lab-only, not real secrets. They are checked in on purpose so the
lab is easy to reset.

- Grafana admin password: `otel-lab-admin` (also in `k8s/manifests/grafana/values.yaml`)
- Argo admin password: auto-generated on first install, see `make argo-password`
