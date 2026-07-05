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

Each step is verified end to end before the next starts.

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
| Step 2 — OTel Collector + Tempo (traces end to end) | Not implemented |
| Step 3 — Loki (logs pipeline + trace_id to logs pivot) | Not implemented |
| Step 4 — Mimir (span metrics + direct metrics) | Not implemented |

A full clean rebuild runs the two done steps in order:

```sh
make clean && make step0 && make step1
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
curl -s -u admin:otel-lab-admin http://localhost:3000/api/datasources # []  (empty until Step 2+)

make grafana-password    # otel-lab-admin (also in k8s/manifests/grafana/values.yaml)
```

Acceptance:

- [x] `grafana` Application is Synced and Healthy; `root` is Synced and Healthy.
- [x] Grafana pod Running in `observability`, service NodePort 30300.
- [x] Grafana UI reachable on localhost:3000, admin login works.
- [x] Grafana has zero datasources (they arrive in Steps 2-4).

---

## Step 2 — OTel Collector + Tempo, traces end to end (Not implemented)

Build/Verify commands: TODO when built.

Acceptance criteria:

- [ ] OTel Operator installed; zero-code auto-instrumentation injection works.
- [ ] OTel Collector is the only telemetry ingress; the sample app sends OTLP to
      the Collector only, never to a backend directly.
- [ ] Tempo deployed via an Argo Application (same pattern as Grafana).
- [ ] Grafana has a Tempo datasource.
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
