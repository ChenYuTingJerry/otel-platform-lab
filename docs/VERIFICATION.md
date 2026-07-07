# Verification runbook

How to build and verify each step, end to end. Living document: each step has a
**Build** section (commands to bring that state up) and a **Verify** section
(checks that prove it works). Steps not yet implemented carry acceptance
criteria only, no commands yet.

The build model: one scaffold step (**Step 0**: k3d cluster + ArgoCD) followed
by **four signal steps**, one per LGTM backend:

- Step 1 — Grafana (the UI)
- Step 2 — Tempo (traces)
- Step 3 — Loki (logs)
- Step 4 — Mimir (metrics)

Each step is verified end to end before the next starts. Every implemented step
has an automated test (`make verify-stepN`) that asserts its state and exits
non-zero on failure, so it can run in CI. The **Verify** sections below lead
with that target and list the underlying checks for reference.

Conventions:

- All commands assume the `otel-lab` cluster and its context:
  `kubectl config use-context k3d-otel-lab`.
- Argo UI is on host port 8081 (not 8080: Docker Desktop reserves 8080 on
  macOS). Grafana UI is on host port 3000. Both are k3d host-port maps into
  NodePort services.
- Argo-managed workloads (Grafana, later Tempo/Loki/Mimir/Collector) are synced
  by ArgoCD from Application CRs. The ArgoCD bootstrap itself is installed with
  Helm, not Argo (see `docs/adr/004-bootstrap-argocd-with-helm.md`).
- Re-running a Build step is safe (idempotent): `make cluster` skips if the
  cluster exists, `make argocd` is `helm upgrade --install`, `make bootstrap`
  is `kubectl apply`.

Status at a glance:

| Step | State |
|------|-------|
| Step 0 — Scaffold (k3d cluster + ArgoCD) | Done (verified on k3d) |
| Step 1 — Grafana on k3d via ArgoCD | Done (verified on k3d) |
| Step 2a — OTel Operator (auto-instrumentation control plane) | Done (verified on k3d) |
| Step 2b — Tempo backend + Grafana datasource | Done (verified on k3d) |
| Step 2c — OTel Collector as single ingress | Not implemented |
| Step 2d — Auto-instrumentation + sample app | Not implemented |
| Step 2e — One trace queryable end to end | Not implemented |
| Step 3 — Loki (logs pipeline + trace_id to logs pivot) | Not implemented |
| Step 4 — Mimir (span metrics + direct metrics) | Not implemented |

A full clean rebuild runs the done steps in order. The OTel Operator (Step 2a)
has no build target of its own: the root app-of-apps picks it up during
`make step1`, so it comes up in the same pass. Tempo (Step 2b) is discovered
the same way, but has its own `make step2b` that waits for it to go Healthy.

```sh
make clean && make step0 && make step1 && make step2b
make verify        # asserts step0 + step1 + step2a + step2b
```

---

## Step 0 — Scaffold: k3d cluster + ArgoCD (Done)

The control plane. A k3d cluster with ArgoCD installed by Helm. No workloads
yet: this step just gets Argo up and reachable so it can manage everything else.

### Build

```sh
make step0        # cluster + argocd (helm)
```

Or the two underlying targets:

```sh
make cluster      # k3d cluster otel-lab, host ports 3000 and 8081, traefik off
make argocd       # helm upgrade --install argocd, wait for server rollout
```

### Verify

```sh
make verify-step0    # asserts the checks below; exits non-zero on failure
```

It asserts: a Ready node, `argocd-server` available, the Argo API responds, and
admin login returns 200. The same checks by hand:

```sh
kubectl config use-context k3d-otel-lab
kubectl get nodes                 # 1 node, Ready
kubectl -n argocd get pods        # all Running (redis-secret-init Completed is a Job)

# Argo UI reachable and admin login works:
curl -s http://localhost:8081/api/version                      # {"Version":"v3.4.4"}
AP=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/api/v1/session \
  -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$AP\"}"  # 200

# No workloads yet (namespace absent, no Applications):
kubectl get ns observability          # NotFound
kubectl -n argocd get applications    # No resources found

make argo-password    # prints the admin password for the browser
```

Acceptance:

- [x] Cluster `otel-lab` up, 1 node Ready.
- [x] ArgoCD pods Running.
- [x] Argo UI reachable on localhost:8081; admin login returns a session token.
- [x] No application workloads yet (`observability` namespace absent, zero Applications).

Notes:

- Argo UI is on 8081, not the usual 8080: Docker Desktop reserves 8080 on macOS.
- The `argocd-applicationset-controller` keeps running. The argo-cd 10.1.2 chart
  has no `applicationSet.enabled` key to switch it off. Expected, not a failure.

---

## Step 1 — Grafana on k3d via ArgoCD (Done)

ArgoCD syncs Grafana from an Application CR into the `observability` namespace.
Grafana comes up empty (no datasources yet, by design).

### Build

```sh
make step1        # bootstrap: apply the root app-of-apps, Argo syncs Grafana
```

`make step1` applies the root Application. The root app-of-apps discovers
`k8s/argocd/applications/grafana.yaml`, creates the `grafana` Application, and
Argo syncs it. The target waits for that Application to appear and go Healthy.
Assumes Step 0 is up.

### Verify

```sh
make verify-step1    # asserts the checks below; exits non-zero on failure
```

It asserts: `grafana` and `root` Applications Synced/Healthy, the Grafana
Service on NodePort 30300, the deployment available, `/api/health` ok, and
admin login works. It no longer checks the datasource count: Grafana starts
empty, but from Step 2b on each backend ships its own datasource, so that
check moved to `verify-step2b`. The same checks by hand:

```sh
# Both Applications Synced and Healthy:
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
# root      Synced   Healthy
# grafana   Synced   Healthy

# Grafana workload landed in the namespace, exposed on NodePort 30300:
kubectl -n observability get pods         # grafana-... Running
kubectl -n observability get svc grafana  # NodePort 80:30300/TCP

# Login actually works, and Grafana is empty (the real delivery check):
curl -s http://localhost:3000/api/health                              # database: ok
curl -s -u admin:otel-lab-admin http://localhost:3000/api/user        # login: admin, isGrafanaAdmin: true
curl -s -u admin:otel-lab-admin http://localhost:3000/api/datasources # Tempo datasource from Step 2b onward

make grafana-password    # otel-lab-admin (also in k8s/manifests/grafana/values.yaml)
```

Acceptance:

- [x] `grafana` Application is Synced and Healthy; `root` is Synced and Healthy.
- [x] Grafana pod Running in `observability`, service NodePort 30300.
- [x] Grafana UI reachable on localhost:3000, admin login works.
- [x] Grafana starts with no datasources; they arrive from Step 2b (checked in
  `verify-step2b`, not here).

---

## Step 2 — OTel Collector + Tempo, traces end to end

Step 2 is split into sub-steps, each verified before the next. The operator
(2a) is done. The rest are not built yet: they carry acceptance criteria and a
planned verify target, no commands. The union of the sub-step acceptance boxes
below is the definition of done for the whole step.

### Step 2a — OTel Operator (Done)

The control plane for auto-instrumentation. Installed as an Argo Application
(`k8s/argocd/applications/otel-operator.yaml`), multi-source like Grafana. It
has no build target of its own: the root app-of-apps picks it up during
`make step1`. sync-wave 0, so its CRDs exist before the Collector CR (wave 2).

#### Verify

```sh
make verify-step2a    # asserts the checks below; exits non-zero on failure
```

It asserts: the `otel-operator` Application Synced/Healthy, the operator
deployment available, both CRDs present, and the mutating webhook installed.
The same checks by hand:

```sh
kubectl -n argocd get application otel-operator \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
kubectl -n opentelemetry-operator-system get deploy opentelemetry-operator
kubectl get crd | grep opentelemetry.io          # opentelemetrycollectors + instrumentations
kubectl get mutatingwebhookconfiguration | grep opentelemetry
```

Acceptance:

- [x] `otel-operator` Application Synced and Healthy.
- [x] Operator deployment available in `opentelemetry-operator-system`.
- [x] CRDs `opentelemetrycollectors` and `instrumentations` present.
- [x] Mutating webhook for injection installed.

### Step 2b — Tempo backend + Grafana datasource (Done)

Tempo runs as an Argo Application in single-binary mode, same multi-source
shape as Grafana. The chart comes from `grafana-community`, not the deprecated
`grafana/tempo` (see `docs/adr/008`). The Grafana datasource is not baked into
Grafana's values: the Tempo Application ships a labelled ConfigMap that
Grafana's datasource sidecar loads at runtime, so each backend owns its own
datasource (see `docs/adr/007`).

#### Build

```sh
make step2b       # applies the root app (idempotent); Argo syncs Tempo
```

The root app-of-apps discovers `k8s/argocd/applications/tempo.yaml`, creates the
`tempo` Application, and Argo syncs it: the Tempo StatefulSet plus the datasource
ConfigMap. The target waits for the `tempo` Application to go Healthy. Assumes
Step 1 is up. sync-wave 1, so Tempo is up before the Collector (wave 2, Step 2c).

#### Verify

```sh
make verify-step2b    # asserts the checks below; exits non-zero on failure
```

It asserts: the `tempo` Application Synced/Healthy, the Tempo StatefulSet ready
(its readinessProbe hits `/ready` on 3200, so a ready replica proves `/ready`
responds), the Service exposes OTLP 4317, and Grafana has a `type: tempo`
datasource. The same checks by hand:

```sh
kubectl -n argocd get application tempo \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
kubectl -n observability get statefulset tempo   # READY 1/1
kubectl -n observability get svc tempo -o jsonpath='{range .spec.ports[*]}{.name}={.port}{"\n"}{end}'
curl -s -u admin:otel-lab-admin http://localhost:3000/api/datasources  # includes "type":"tempo"
```

Acceptance criteria:

- [x] Tempo deployed via an Argo Application.
- [x] Grafana has a Tempo datasource.

### Step 2c — OTel Collector as single ingress (Not implemented)

Run the Collector as an `OpenTelemetryCollector` CR (deployment mode). It
receives OTLP on 4317/4318 and exports only to Tempo. This is the one ingress:
apps never talk to a backend directly (see ADR 002). sync-wave 2, after the
operator CRDs exist.

Planned verify target: `make verify-step2c`. It should assert:

- The `OpenTelemetryCollector` CR exists and reports ready.
- The Collector deployment available; service exposes OTLP 4317/4318.
- The Collector exports to the Tempo endpoint.

Acceptance criteria:

- [ ] OTel Collector is the only telemetry ingress.

### Step 2d — Auto-instrumentation + sample app (Not implemented)

Create an `Instrumentation` CR and deploy a sample app that opts in via
annotation. The operator webhook injects an init-container and sets
`OTEL_EXPORTER_OTLP_ENDPOINT` to the Collector, never to a backend.

Planned verify target: `make verify-step2d`. It should assert:

- The `Instrumentation` CR present.
- The sample app pod shows the injected init-container and OTEL env pointing at
  the Collector.
- The sample app Running.

Acceptance criteria:

- [ ] Zero-code auto-instrumentation injection works.
- [ ] The sample app sends OTLP to the Collector only, never to a backend directly.

### Step 2e — One trace queryable end to end (Not implemented)

The real delivery check. Drive traffic to the sample app, then query Tempo
through Grafana and find the trace. This closes Step 2.

Planned verify target: `make verify-step2` (the full end-to-end check). It
should send a request to the sample app, then search Tempo (via the Grafana
datasource proxy or the Tempo API) and assert at least one matching trace.

Acceptance criteria:

- [ ] A trace from the sample app is queryable in Grafana/Tempo, end to end.

## Step 3 — Loki, logs pipeline + trace pivot (Not implemented)

Build/Verify commands: TODO when built.

Acceptance criteria:

- [ ] Loki deployed via an Argo Application.
- [ ] Logs flow through the Collector (single ingress holds).
- [ ] Grafana has a Loki datasource; trace_id in a log line pivots to the trace.
- [ ] Logs carry high-cardinality context (per the signal-routing model).

## Step 4 — Mimir, span metrics + direct metrics (Not implemented)

Build/Verify commands: TODO when built.

Acceptance criteria:

- [ ] Mimir deployed via an Argo Application.
- [ ] Span metrics derived from traces (Collector spanmetrics) land in Mimir.
- [ ] A direct metrics path works too.
- [ ] Grafana has a Mimir datasource; metrics stay aggregate (low cardinality).
