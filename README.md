# otel-platform-lab

An observability platform lab on Kubernetes. OpenTelemetry Collector as the
single telemetry ingress feeding an LGTM stack (Loki, Grafana, Tempo, Mimir).
Deployed on a local k3d cluster (Apple Silicon), managed by ArgoCD from
day one.

Current stage: Step 8 done. All three signals flow through the Collector to their
backends (traces to Tempo, logs to Loki, metrics to Mimir), a FastAPI sample app
is auto-instrumented by the operator, RED and platform-health alerts run in the
Mimir ruler, and KEDA scales the app on its request rate. As of Step 8 a second
backend rests at zero off-peak and wakes on the first request through the KEDA
HTTP Add-on. The platform both observes the app and acts on what it observes.

## Prerequisites

- Docker Desktop (running)
- k3d 5.x
- kubectl
- helm
- gh (for the initial GitHub push, one-off)

## Quickstart

The build has one scaffold step (Step 0), the signal pipeline (Steps 1-4), then
platform behaviour on top (alerting, self-health, autoscaling). Run them in
order; each is verified before the next. See
[docs/VERIFICATION.md](docs/VERIFICATION.md) for the per-step checks.

```
make step0    # scaffold: k3d cluster + ArgoCD
make step1    # bootstrap Grafana via ArgoCD (also brings up the OTel Operator)
make step2b   # Tempo backend + its Grafana datasource
make step2c   # OTel Collector, the single ingress gateway
make step2d   # sample app + auto-instrumentation, one trace end to end
make step3    # Loki logs backend, logs via the Collector, trace correlation
make step4a   # Mimir metrics backend + its Grafana datasource
make step4b   # Collector metrics pipeline + the app counter, metrics end to end
make step5a   # enable the Mimir ruler + Alertmanager
make step5b   # RED rules loaded into the ruler
make step5c   # webhook sink for fired alerts
make step5d   # dashboards sidecar + the RED dashboard
make step6a   # platform self-health (k8s_cluster metrics + alerts + dashboard)
make step6b   # opt-in node-local log-filtering agent (DaemonSet)
make step7    # KEDA autoscaler: scale the app on request rate
make step8    # KEDA HTTP Add-on: a second backend that scales to zero
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
apps/sample-api/            FastAPI sample service (Step 2d), its own mini-project:
                            app code, Dockerfile, and deploy/ manifests
apps/offpeak-api/           Scale-to-zero backend (Step 8), reuses sample-api's
                            image; deploy/ manifests only, incl. the HTTPScaledObject
k8s/manifests/otel-injection/  Operator injection templates (Instrumentation CRs)
config/                     Reserved. The Collector pipeline lives inline in
                            k8s/manifests/collector/values.yaml, not here.
docs/ARCHITECTURE.md        Overall architecture: diagrams + all ADRs at a glance
docs/scenarios.md           The same material indexed by problem, not by build order
docs/adr/                   Architecture decision records
docs/signal-strategy.md     How logs, metrics, and traces split work
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the runtime and GitOps
diagrams and a one-line summary of every decision.

See [docs/scenarios.md](docs/scenarios.md) if you arrived with a problem rather
than a build step. It indexes the same decisions by the shape of the problem they
solve, with the trade-off and the gotcha for each.

## Build order

Each step is verified end-to-end before the next one starts.

- [x] Step 0 - Scaffold: k3d cluster + ArgoCD
1. [x] Step 1 - Grafana UI reachable via ArgoCD
2. [x] Step 2 - OTel Collector + Tempo, traces from a sample app
3. [x] Step 3 - Loki logs pipeline with trace_id to logs pivot
4. [x] Step 4 - Mimir metrics (span metrics + direct)
5. [x] Step 5 - App RED alerting (Mimir ruler + Alertmanager) + RED dashboard
6. [x] Step 6a - Platform self-health (k8s_cluster workload alerts + dashboard)
7. [x] Step 6b - Opt-in node-local log-filtering agent (DaemonSet, Topology B)
8. [x] Step 7 - Autoscale the app on request rate (KEDA Prometheus scaler)
9. [x] Step 8 - Safe scale-to-zero for a second backend (KEDA HTTP Add-on)

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
