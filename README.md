# otel-platform-lab

An observability platform lab on Kubernetes. OpenTelemetry Collector as the
single telemetry ingress feeding an LGTM stack (Loki, Grafana, Tempo, Mimir).
Deployed on a local k3d cluster (Apple Silicon), managed by ArgoCD from
day one.

Current stage: Step 1 (Grafana only). Tempo, Loki, and Mimir land in later
steps.

## Prerequisites

- Docker Desktop (running)
- k3d 5.x
- kubectl
- helm
- gh (for the initial GitHub push, one-off)

## Quickstart (Step 1)

```
make step1
```

This runs:

1. `make cluster`   -  creates a k3d cluster called `otel-lab` with host
   ports 3000 (Grafana) and 8080 (Argo UI) mapped in.
2. `make argocd`    -  helm installs ArgoCD into the `argocd` namespace with
   values from `k8s/argocd/install/values.yaml`.
3. `make bootstrap` -  applies the root Application (`k8s/argocd/root-app.yaml`).
   Argo then discovers the Grafana Application under
   `k8s/argocd/applications/` and syncs it into the `observability` namespace.

After sync:

- Argo UI:    http://localhost:8080  (user `admin`, password from `make argo-password`)
- Grafana UI: http://localhost:3000  (user `admin`, password `otel-lab-admin`
  or from `make grafana-password`)

## Layout

```
k8s/argocd/install/         Helm values for the ArgoCD install itself
k8s/argocd/root-app.yaml    App-of-apps, applied by `make bootstrap`
k8s/argocd/applications/    One Argo Application CR per platform component
k8s/manifests/<component>/  Helm values.yaml files that Argo reads
apps/                       Sample instrumented services (added in Step 2)
config/                     OTel Collector pipelines (added in Step 2)
docs/adr/                   Architecture decision records
docs/signal-strategy.md     How logs, metrics, and traces split work
```

## Build order

Each step is verified end-to-end before the next one starts.

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
