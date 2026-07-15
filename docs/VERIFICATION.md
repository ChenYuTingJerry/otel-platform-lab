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
| Step 2c — OTel Collector (single ingress gateway) | Done (workload verified on k3d) |
| Step 2d — Auto-instrumentation + sample app | Done (workload verified on k3d) |
| Step 2e — One trace queryable end to end | Done (verified on k3d) |
| Step 3 — Loki (logs pipeline + trace correlation both ways) | Done (data path verified on k3d) |
| Step 4a — Mimir backend + Grafana datasource | Done (verified on k3d via Argo) |
| Step 4b — Metrics pipeline (span metrics + direct metrics) | Done (verified on k3d via Argo) |
| Step 5 — App RED alerting (ruler + Alertmanager) + RED dashboard | Done (verified on k3d via Argo) |
| Step 6a — Platform self-health (k8s_cluster metrics + alerts + dashboard) | Done (verified on k3d via Argo) |
| Step 6b — Opt-in node-local log-filtering agent (DaemonSet) | Done (verified on k3d via Argo) |

A full clean rebuild runs the done steps in order. The OTel Operator (Step 2a)
has no build target of its own: the root app-of-apps picks it up during
`make step1`, so it comes up in the same pass. Tempo (Step 2b) and the Collector
(Step 2c) are discovered the same way, but each has its own `make step2b` /
`make step2c` that waits for it to go Healthy.

```sh
make clean && make step0 && make step1 && make step2b && make step2c && make step2d && make step3 && make step4a && make step4b
make step5a && make test-rules && make step5b && make step5c && make step5d && make step6a
make verify        # asserts step0 + step1 + step2a..2e + step3 + step4a..b + step5a..d + step6a
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

Step 2 is split into sub-steps, each verified before the next. All are done:
the operator (2a), Tempo (2b), the Collector (2c), auto-instrumentation and the
sample app (2d), and one trace end to end (2e). The union of the sub-step
acceptance boxes below is the definition of done for the whole step.

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

### Step 2c — OTel Collector, single ingress gateway (Done)

The Collector runs as a central Deployment (gateway), deployed with the
`opentelemetry-collector` Helm chart, same chart+`$values` shape as Grafana and
Tempo. It receives OTLP on 4317/4318 and exports only to Tempo. This is the one
ingress: apps never talk to a backend directly (see ADR 002). It is not the
operator CR: a gateway needs none of the operator-only features (see ADR 009).
sync-wave 2, after the operator (wave 0) and Tempo (wave 1). The pipeline is
`memory_limiter` + `resource` + `batch`, traces only.

#### Build

```sh
make step2c       # applies the root app (idempotent); Argo syncs the Collector
```

The root app-of-apps discovers `k8s/argocd/applications/collector.yaml`, creates
the `collector` Application, and Argo syncs it: the Collector Deployment,
Service, and ConfigMap from the chart. The target waits for the `collector`
Application to go Healthy. Assumes Step 2b is up.

#### Verify

```sh
make verify-step2c    # asserts the checks below; exits non-zero on failure
```

It asserts: the `collector` Application Synced/Healthy, the Collector Deployment
available (an available replica means it passed its health_check readiness
probe), the Service exposes OTLP 4317 and 4318, and the rendered config exports
to the Tempo endpoint. The same checks by hand:

```sh
kubectl -n argocd get application collector \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
kubectl -n observability get deploy,svc otel-collector
kubectl -n observability get svc otel-collector -o jsonpath='{range .spec.ports[*]}{.name}={.port}{"\n"}{end}'
kubectl -n observability get cm otel-collector -o yaml | grep 'tempo.observability'
kubectl -n observability logs deploy/otel-collector | tail   # "Everything is ready", otlp on 4317/4318
```

Note on verification: the Collector workload was verified end to end on k3d by a
direct smoke test (render the chart into a throwaway namespace, push one OTLP
span, then read it back from Tempo through the Grafana datasource proxy). The
returned trace carried `deployment.environment=lab`, which proves the `resource`
processor runs. `make step2c` exercises the same workload through Argo once the
manifests are on the tracked branch (`main`).

Acceptance criteria:

- [x] OTel Collector is the only telemetry ingress.

### Step 2d — Auto-instrumentation + sample app (Done)

A FastAPI sample app (`apps/sample-api/`, treated as its own small project)
opts in to zero-code auto-instrumentation with a pod annotation. The operator
webhook injects a Python SDK init-container at pod creation and sets
`OTEL_EXPORTER_OTLP_ENDPOINT` to the Collector, never to a backend (ADR 002).

The `Instrumentation` CR is the injection template. It lives in
`k8s/manifests/otel-injection/`, delivered by the `otel-injection` Application
(directory source, `ServerSideApply`), into the app namespace `demo` (ADR 010).
The app is delivered by a second Application, `sample-app`, from
`apps/sample-api/deploy`. Waves: injection is 3, the app is 4, so the CR exists
before the pod is created.

The image is not pulled from a registry. `make sample-image` builds it and
imports it into k3d; the Deployment uses `imagePullPolicy: IfNotPresent`.

#### Build

```sh
make step2d       # build+import the image, then Argo syncs injection + app
```

`make step2d` runs `make sample-image` (docker build + `k3d image import`) then
applies the root app (idempotent). Argo discovers the `otel-injection` and
`sample-app` Applications and syncs them. The target waits for `sample-app` to
go Healthy. Assumes Step 2c is up.

#### Verify

```sh
make verify-step2d    # asserts the checks below; exits non-zero on failure
```

It asserts: the `otel-injection` and `sample-app` Applications Synced/Healthy,
the `Instrumentation` CR present in `demo`, the `sample-api` deployment
available, the injected init-container
(`opentelemetry-auto-instrumentation-python`), and the container's
`OTEL_EXPORTER_OTLP_ENDPOINT` pointing at the Collector. The same checks by
hand:

```sh
kubectl -n argocd get application otel-injection sample-app \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
kubectl -n demo get instrumentation python
kubectl -n demo get deploy sample-api                    # READY 1/1
kubectl -n demo get pod -l app=sample-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'  # opentelemetry-auto-instrumentation-python
kubectl -n demo get pod -l app=sample-api \
  -o jsonpath='{range .items[0].spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep OTEL_EXPORTER_OTLP_ENDPOINT
# OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4318
```

Note on verification: the workload was verified end to end on k3d by a direct
smoke test. The image was built and imported, the `Instrumentation` CR and the
app manifests applied into `demo` by hand, then traffic driven to `/rolldice`
and the trace read back from Tempo (see Step 2e below). The injected pod showed
the `opentelemetry-auto-instrumentation-python` init-container and the OTEL
endpoint pointing at the Collector. `make verify-step2d` exercises the same
workload through Argo once the manifests are on the tracked branch (`main`).

Acceptance criteria:

- [x] Zero-code auto-instrumentation injection works.
- [x] The sample app sends OTLP to the Collector only, never to a backend directly.

### Step 2e — One trace queryable end to end (Done)

The real delivery check. Drive traffic to the sample app, then query Tempo
through Grafana and find the trace. This closes Step 2.

#### Verify

```sh
make verify-step2e    # asserts the checks below; exits non-zero on failure
```

It drives a few requests to `sample-api.demo` from a short-lived in-cluster
curl pod, then queries Tempo through the Grafana datasource proxy with the
TraceQL `{ resource.service.name="sample-api" }` and asserts at least one trace
comes back (retried, since ingestion is async). The same check by hand:

```sh
kubectl -n demo run trace-gen --rm -i --restart=Never --image=curlimages/curl:latest --command -- \
  sh -c 'for i in 1 2 3 4 5; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done'

curl -s -u admin:otel-lab-admin -G \
  http://localhost:3000/api/datasources/proxy/uid/tempo/api/search \
  --data-urlencode 'q={ resource.service.name="sample-api" }' --data-urlencode 'limit=5'
# JSON with a "traces" array; each entry has a "traceID"
```

Note on verification: verified on k3d during the Step 2d smoke test. The
returned trace carried `service.name=sample-api`, `telemetry.sdk.language=python`
(the injected SDK), and `deployment.environment=lab`. That last attribute is
added by the Collector's `resource` processor, so it proves the span really
travelled app to Collector to Tempo, not straight to a backend.

Acceptance criteria:

- [x] A trace from the sample app is queryable in Grafana/Tempo, end to end.

## Step 3 — Loki, logs pipeline + trace correlation both ways (Done)

Loki is the logs backend, deployed as an Argo Application in SingleBinary mode
(`grafana-community/loki`, see docs/adr/011). The sample app emits its logs as
OTLP to the Collector, the same path its traces take (see docs/adr/012); the
Collector's logs pipeline exports them to Loki's native OTLP endpoint. Grafana
links logs and traces both ways: `trace_id` in a Loki log line jumps to the
Tempo trace (Loki datasource `derivedFields`), and a Tempo span jumps to the
request's logs (Tempo datasource `tracesToLogsV2`).

### Build

```sh
make step3        # applies the root app (idempotent); Argo syncs Loki
```

The root app-of-apps discovers `k8s/argocd/applications/loki.yaml`, creates the
`loki` Application, and Argo syncs it: the Loki StatefulSet plus the datasource
ConfigMap. The target waits for the `loki` Application to go Healthy. Loki is
sync-wave 1 (a backend, same as Tempo), so it is up before the Collector at
wave 2. Assumes Step 2 is up: the Collector now also carries logs, and the
sample app emits them (both land through a re-sync of the collector and
sample-app Applications once this branch is on `main`).

### Verify

```sh
make verify-step3    # asserts the checks below; exits non-zero on failure
```

It asserts: the `loki` Application Synced/Healthy, the Loki StatefulSet ready
(its readinessProbe hits `/ready` on 3100), a `type: loki` datasource in
Grafana, and end to end: drive `/rolldice`, then query Loki through the Grafana
proxy for a `sample-api` log line that carries a `trace_id`. The same checks by
hand:

```sh
kubectl -n argocd get application loki \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
kubectl -n observability get statefulset loki          # READY 1/1
curl -s -u admin:otel-lab-admin http://localhost:3000/api/datasources | grep -o '"type":"loki"'

kubectl -n demo run log-gen --rm -i --restart=Never --image=curlimages/curl:latest --command -- \
  sh -c 'for i in 1 2 3 4 5; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done'

# query_range needs a time window; the `| trace_id != ""` filter is the point.
END=$(( $(date +%s) * 1000000000 )); START=$(( ($(date +%s) - 3600) * 1000000000 ))
curl -s -u admin:otel-lab-admin -G \
  http://localhost:3000/api/datasources/proxy/uid/loki/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="sample-api"} | trace_id != ""' \
  --data-urlencode "start=$START" --data-urlencode "end=$END" --data-urlencode 'limit=5'
# JSON with a "result" stream; the log line reads "rolled a N"
```

Note on verification: the data path was verified end to end on k3d in an
isolated namespace (Argo reads `main`, so like Steps 2c/2d the Argo path goes
green only after push). A Loki + a Collector with the new logs pipeline were
installed, the app pointed at that Collector, and traffic driven. The log line
landed in Loki with `service_name=sample-api` and `deployment_environment=lab`
as index labels (the second from the Collector's `resource` processor, so logs
are enriched like traces), and `trace_id` as structured metadata (not an index
label, so no cardinality blow-up). That `trace_id` resolved to a real trace in
Tempo, which proves the correlation the pivots rely on. `make verify-step3`
exercises the same path through Argo once the manifests are on `main`.

Acceptance criteria:

- [x] Loki deployed via an Argo Application.
- [x] Logs flow through the Collector (single ingress holds).
- [x] Grafana has a Loki datasource; trace_id in a log line pivots to the trace
  (and a trace pivots back to its logs).
- [x] Logs carry high-cardinality context (`trace_id`, `span_id`, code location)
  as structured metadata, while the index labels stay low-cardinality.

## Step 4 — Mimir, span metrics + direct metrics (Done)

Mimir is the metrics backend, the last of the four signals. It runs as
`mimir-distributed` in the ingest-storage (Kafka) architecture, trimmed to a
single-node footprint (~12 pods incl. Kafka + MinIO, see docs/adr/013). Two
metric paths land in Mimir, both through the one Collector:

- **Span metrics**: RED metrics (rate, errors, duration) the Collector's
  `span_metrics` connector derives from the trace stream, no app change
  (docs/adr/015).
- **Direct metrics**: the app SDK's own OTLP metrics, the auto-instrumentation
  HTTP server metrics plus one custom `dice.rolls` counter (this is why
  `OTEL_METRICS_EXPORTER` went back to `otlp`, after being `none` in Step 3).

Both leave the Collector as OTLP to `mimir-gateway` `/otlp/v1/metrics`, not
Prometheus remote-write (docs/adr/014). Grafana gets a Mimir datasource (type
`prometheus`), so metrics are queryable next to traces and logs. Split into two
sub-steps: 4a is the backend + datasource, 4b is the pipeline + app change.

### Build

```sh
make step4a       # applies the root app (idempotent); Argo syncs Mimir
make step4b       # rebuild+import the image, Argo re-syncs collector + app
```

`make step4a` discovers `k8s/argocd/applications/mimir.yaml`, creates the `mimir`
Application, and Argo syncs it (the ~12-pod Mimir plus the datasource ConfigMap).
The wait timeout is longer than other steps because Mimir is the heaviest
backend. `make step4b` runs `make sample-image` (the `dice.rolls` counter is new
app code) then applies the root app; Argo re-syncs the collector (now with a
metrics pipeline) and the sample app (new image, `OTEL_METRICS_EXPORTER=otlp`).
Assumes Step 3 is up. Mimir is sync-wave 1 (a backend, same as Tempo and Loki),
so it is up before the Collector at wave 2.

### Verify

```sh
make verify-step4a    # Mimir synced + ingester ready + prometheus datasource
make verify-step4b    # a span metric + the app counter queryable in Mimir
```

`verify-step4a` asserts the `mimir` Application Synced/Healthy, the
`mimir-ingester` StatefulSet ready (the write-path core), and a
`type: prometheus` datasource in Grafana. `verify-step4b` drives `/rolldice`,
then queries Mimir through the Grafana proxy for two series, retried for async
ingestion. The same checks by hand:

```sh
kubectl -n argocd get application mimir \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers
kubectl -n observability get statefulset mimir-ingester   # READY 1/1
curl -s -u admin:otel-lab-admin http://localhost:3000/api/datasources | grep -o '"type":"prometheus"'

kubectl -n demo run metric-gen --rm -i --restart=Never --image=curlimages/curl:latest --command -- \
  sh -c 'for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done'

# The Mimir datasource URL ends in /prometheus, so the proxy path appends /api/v1/query.
# Span metric (RED, from the connector):
curl -s -u admin:otel-lab-admin -G \
  http://localhost:3000/api/datasources/proxy/uid/mimir/api/v1/query \
  --data-urlencode 'query=traces_span_metrics_calls_total{service_name="sample-api"}'
# Direct app counter:
curl -s -u admin:otel-lab-admin -G \
  http://localhost:3000/api/datasources/proxy/uid/mimir/api/v1/query \
  --data-urlencode 'query=dice_rolls_total'
# Each returns a "success" vector with a "metric" object in the result array.
```

Note on verification: verified twice. First the data path was smoke-tested on
k3d in an isolated `step4-smoke` namespace before merge (a real Mimir, a Collector
with the new metrics pipeline, and the injected sample app, traffic driven, both
metrics read back). Then, after the change merged to `main` and Argo deployed it,
the full path was verified through Argo: `make verify-step4a` and
`make verify-step4b` pass, and `make verify` (step0 through step4b + injection) is
green end to end. What the metrics carry:

- `traces_span_metrics_calls_total{service_name="sample-api"}` carries
  `http_method=GET`, `http_route=/rolldice`, `http_status_code=200` (the legacy
  HTTP semconv keys the Python SDK actually emits, so the dimensions are
  populated, not empty),
- `dice_rolls_total` carries the app's own counter value,
- both carry `deployment_environment=lab` as a real label, which proves the
  `promote_otel_resource_attributes` promotion works (without it the attribute
  would sit in a `target_info` series). The `_total` suffix confirms
  `otel_metric_suffixes_enabled` is on.

One operational note: after Step 4b rebuilds the image and Argo updates the
Instrumentation CR (`OTEL_METRICS_EXPORTER` now `otlp`), the running `sample-api`
pod does not pick either up on its own, because the Deployment manifest is
unchanged so Argo does not roll it. Run `kubectl rollout restart deploy/sample-api
-n demo` so a fresh pod gets the new image and is re-injected with the metrics
exporter on.

Acceptance criteria:

- [x] Mimir deployed via an Argo Application.
- [x] Span metrics derived from traces (Collector `span_metrics`) land in Mimir.
- [x] A direct metrics path works too (SDK OTLP + the custom `dice_rolls_total`).
- [x] Grafana has a Mimir datasource; metrics stay aggregate (low cardinality).


## Step 5 — App RED alerting (Mimir ruler + Alertmanager) + RED dashboard (Done)

Alerting on the app RED metrics, plus one dashboard to read them. Rules live in
the Mimir ruler in Prometheus format, in git, unit-tested with `promtool`, loaded
with `mimirtool` to tenant `anonymous` (docs/adr/017). Alerts route through the
bundled Alertmanager to an in-cluster webhook sink that just logs them. The
dashboard ships as code through Grafana's dashboards sidecar. Metrics are the ones
Step 4 already produces (`traces_span_metrics_*`), so no app change. Platform
self-health is deferred to Step 6. Split into four sub-steps.

### Build

```sh
make step5a       # enable the Mimir ruler + Alertmanager (mimir re-syncs)
make test-rules   # unit-test the RED rules with promtool, locally, before loading
make step5b       # rules ConfigMap + a PostSync-hook Job loads them with mimirtool
make step5c       # webhook sink for fired alerts
make step5d       # dashboards sidecar + the RED dashboard
```

`make step5a` flips `ruler.enabled` and `alertmanager.enabled` in the Mimir values
and adds an `alertmanager.fallbackConfig` routing all alerts to the sink; the
change rides the existing `mimir` Application, so Argo re-syncs the Helm release
and adds the `mimir-ruler` and `mimir-alertmanager` StatefulSets. `make step5b`
discovers the `mimir-rules` Application (plain manifests: a ConfigMap with the
rules inline, and a PostSync-hook Job that pushes them to the ruler through
`mimir-gateway` with mimirtool). `make step5c` and `make step5d` are backends like
the others, sync-wave 3. `make test-rules` extracts the rules from the ConfigMap
and runs `promtool test rules` in the `prom/prometheus` image, so nothing is
installed on the host.

### Verify

```sh
make verify-step5a    # ruler + Alertmanager StatefulSets ready, ruler API answers
make verify-step5b    # rules registered + a recording-rule series in the ruler
make verify-step5c    # sink up, ruler alerts API reachable
make verify-step5d    # RED dashboard imported into Grafana
```

`verify-step5a` asserts the `mimir` Application Synced/Healthy, both new
StatefulSets ready, and the ruler read API reachable through the Grafana proxy.
`verify-step5b` asserts the `mimir-rules` Application, that the ruler lists the
`app_red_alerts` group and the `AppHighErrorRatio` alert, then drives `/rolldice`
and reads back the `job:span_requests:rate5m` recording series (its presence
proves the ruler evaluates). `verify-step5c` asserts the sink Deployment and the
Alertmanager StatefulSet. `verify-step5d` asserts the dashboard imported at
`uid app-red`. The same checks by hand:

```sh
kubectl -n observability get deploy mimir-ruler              # READY 1/1 (ruler is a Deployment)
kubectl -n observability get statefulset mimir-alertmanager  # READY 1/1

# Rules registered in the ruler (through the Grafana proxy):
curl -s -u admin:otel-lab-admin \
  http://localhost:3000/api/datasources/proxy/uid/mimir/api/v1/rules | grep -o '"name":"AppHighErrorRatio"'

# Drive traffic, then read back a recording-rule series:
kubectl -n demo run metric-gen --rm -i --restart=Never --image=curlimages/curl:latest --command -- \
  sh -c 'for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done'
curl -s -u admin:otel-lab-admin -G \
  http://localhost:3000/api/datasources/proxy/uid/mimir/api/v1/query \
  --data-urlencode 'query=job:span_requests:rate5m'

# Dashboard imported:
curl -s -u admin:otel-lab-admin http://localhost:3000/api/dashboards/uid/app-red | grep -o '"uid":"app-red"'
```

Firing a real alert end to end is a manual check, not part of `make verify`:
`AppHighErrorRatio` needs a sustained error ratio above 5% for 5m, which is slow
and flaky to force. To watch delivery, drive error traffic and tail the sink:

```sh
kubectl -n observability logs -f deploy/alert-sink   # the webhook POST prints as JSON
```

Note on verification: verified twice, like Step 4. First locally: `make test-rules`
passes (the three alerting rules behave as expected: error ratio 10%, p95 975ms,
no-requests fires). Then live on k3d through Argo: `make step5a`..`5d` and
`make verify` are green. Two bugs surfaced and were fixed on the way (commit
c027900): the ruler is a Deployment not a StatefulSet, and Mimir sets the job label
to `demo/sample-api` (namespace/service), not `sample-api`, which the AppNoRequests
alert had to key on `service_name` instead. Finally the full alert path was driven
end to end: the sample app's `/flaky` endpoint held the error ratio near 20%, which
took `AppHighErrorRatio` from pending to firing after its 5m `for`, and the Mimir
Alertmanager delivered it to the `alert-sink` webhook (seen in
`kubectl -n observability logs deploy/alert-sink`).

Acceptance criteria:

- [x] Ruler + Alertmanager enabled and Healthy via the existing `mimir` Application.
- [x] RED rules loaded into the ruler under tenant `anonymous`, unit-tested with `promtool`.
- [x] Alerts route through Alertmanager to the in-cluster webhook sink.
- [x] The RED dashboard loads into Grafana as code (dashboards sidecar).

---

## Step 6a — Platform self-health (k8s_cluster metrics + alerts + dashboard) (Done)

Step 5 watches the app. Step 6a watches the platform's own services: alert when
any important service is down or crash-looping. The signal is the Collector's
`k8s_cluster` receiver, which watches the Kubernetes API server and emits workload
state (`k8s_deployment_available`/`desired`, `k8s_statefulset_ready_pods`/
`desired_pods`, `k8s_container_restarts`) as OTLP metrics into Mimir. This is
OTLP-native: no scrape path, no kube-state-metrics, and it stays on the existing
single gateway Deployment (no DaemonSet). See `docs/adr/018`.

No new Argo Application. The change edits four existing releases: the collector
gains the receiver + a read-only ClusterRole, Mimir promotes the `k8s.*` resource
attributes to labels, `mimir-rules` gains a second rules ConfigMap (loaded by the
same PostSync Job as a separate `platform-health` ruler namespace), and
`grafana-dashboards` gains the platform-health dashboard. Alerts reuse the Step 5
path (ruler → Alertmanager catch-all → alert-sink).

### Build

```sh
make test-rules   # unit-test the RED + platform rules with promtool, locally
make step6a       # Argo re-syncs collector, mimir, mimir-rules, grafana-dashboards
```

### Verify

```sh
make verify-step6a
```

`verify-step6a` asserts the `collector` Application Synced/Healthy, the ClusterRole
binding targets the collector ServiceAccount, that `k8s_deployment_available` is
queryable in Mimir **and carries the promoted `k8s_deployment_name` label** (proof
the promotion worked), that the ruler lists the `platform_health_alerts` group and
the `PlatformDeploymentUnavailable` alert, and that the dashboard imported at
`uid platform-health`. The same checks by hand:

```sh
# Workload metrics reached Mimir with real workload identity as labels:
curl -s -u admin:otel-lab-admin -G \
  http://localhost:3000/api/datasources/proxy/uid/mimir/api/v1/query \
  --data-urlencode 'query=k8s_deployment_available{k8s_namespace_name="observability"}' | grep -o '"k8s_deployment_name"'

# Platform alerts registered in the ruler:
curl -s -u admin:otel-lab-admin \
  http://localhost:3000/api/datasources/proxy/uid/mimir/api/v1/rules | grep -o '"name":"PlatformDeploymentUnavailable"'

# Dashboard imported:
curl -s -u admin:otel-lab-admin http://localhost:3000/api/dashboards/uid/platform-health | grep -o '"uid":"platform-health"'
```

Firing a real platform alert end to end is a manual check, like Step 5. Scale a
watched Deployment to break its replica count, wait past the 5m `for`, and tail
the sink:

```sh
kubectl -n observability scale deploy/alert-sink --replicas=0   # then restore to 1
kubectl -n observability logs -f deploy/alert-sink              # PlatformDeploymentUnavailable arrives as JSON
```

Note on verification: verified twice, like Steps 4 and 5. First pre-merge without
touching the live managed config. `make test-rules` passes (the three platform
rules fire as expected). And a throwaway collector with only the `k8s_cluster`
receiver, run in an isolated namespace exporting to the real Mimir, confirmed the
exact metric names and that the workload-identity attributes are resource
attributes that collapse to one unlabeled series unless promoted (which is why the
Mimir promotion is part of this step). Then live on k3d through Argo (commit
d6fb13d): the collector re-synced with the receiver + ClusterRole (the k8s_cluster
informer caches synced with no RBAC errors), Mimir re-synced the promotion, and
`make verify-step6a` is green (7/7). Full `make verify` is green; a single
transient miss on the Step 5b recording-rule check came from the collector restart
resetting the span_metrics cumulative counters right before the run, and it passed
on re-run once `rate[5m]` had history again.

Acceptance criteria:

- [x] `k8s_cluster` receiver on the gateway Collector, cluster-wide, no DaemonSet.
- [x] Platform rules unit-tested with `promtool` (deployment/statefulset/restart).
- [x] Workload metrics land in Mimir with promoted labels (`verify-step6a`).
- [x] Platform alerts loaded in the ruler and route to the sink.
- [x] The platform-health dashboard loads into Grafana as code.

---

## Step 6b — Opt-in node-local log-filtering agent (DaemonSet) (Done)

An optional second topology (Topology B): a node-local agent that filters unwanted
logs before they reach the gateway. A second Collector runs as a DaemonSet
(`otel-agent`, its own `collector-agent` Application), and the sample app routes
its OTLP **logs** to it. The agent drops DEBUG/probe noise and forwards the rest
to the gateway, which is unchanged. Traces and metrics still go straight to the
gateway. The default stays single-gateway (Topology A); this tier exists only
while the `collector-agent` Application and the app's log endpoint point at it.
Demonstration at lab scale, not a capacity need. See `docs/adr/019` (and `009`).

### Build

```sh
make step6b       # build the image (app emits a DEBUG line), sync the agent, roll the app
make verify-step6b
```

`make step6b` rebuilds the sample image (the app now emits one DEBUG "dice.debug"
line per `/rolldice`) and applies the root app. Argo discovers the
`collector-agent` Application (a DaemonSet Collector) and re-syncs `sample-app`,
which now carries `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` pointing at
`otel-agent.observability`. The env change rolls the pod, so it also picks up the
new image. To turn the topology off, delete
`k8s/argocd/applications/collector-agent.yaml` and the app's logs-endpoint env;
Argo prunes the agent and logs go straight to the gateway again.

### Verify

```sh
make verify-step6b    # agent up, app routed to it, DEBUG dropped, INFO kept in Loki
```

`verify-step6b` asserts the `collector-agent` Application Synced/Healthy, the
`otel-agent` DaemonSet has a ready pod, the `otel-agent` Service exposes 4318, and
the sample-api pod carries the logs endpoint pointing at the agent. Then it drives
`/rolldice` and checks Loki through the Grafana proxy: the INFO "rolled a" line IS
present (logs flow app to agent to gateway to Loki), and the DEBUG "dice.debug"
line is ABSENT (the agent dropped it). The positive is asserted first so the
negative is meaningful. The same checks by hand:

```sh
kubectl -n observability get daemonset otel-agent-agent  # NUMBER READY 1 (chart adds -agent in daemonset mode)
kubectl -n demo get pod -l app=sample-api \
  -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")].value}'
# -> http://otel-agent.observability.svc.cluster.local:4318/v1/logs

kubectl -n demo run log-gen --rm -i --restart=Never --image=curlimages/curl:latest --command -- \
  sh -c 'for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done'

# INFO kept, DEBUG dropped (query Loki through the Grafana proxy):
curl -s -u admin:otel-lab-admin -G \
  http://localhost:3000/api/datasources/proxy/uid/loki/loki/api/v1/query_range \
  --data-urlencode '{service_name="sample-api"} |= "rolled a"' | grep -o 'rolled a'   # present
curl -s -u admin:otel-lab-admin -G \
  http://localhost:3000/api/datasources/proxy/uid/loki/loki/api/v1/query_range \
  --data-urlencode '{service_name="sample-api"} |= "dice.debug"'                       # empty
```

Note on verification: proven pre-push without touching the managed app or pushing
to `main`, in three isolated checks. (1) `helm template` renders the DaemonSet,
Service, and the logs-only pipeline with the `filter` processor. (2) An isolated
smoke: the agent deployed to a throwaway namespace, forwarding to the real
gateway, was sent one DEBUG and one INFO OTLP log record; Loki kept the INFO line
and the DEBUG line never arrived, so the filter drops DEBUG and keeps INFO end to
end through the gateway. (3) A server dry-run of an injected pod confirmed the
per-signal `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` (to the agent) survives operator
injection and coexists with the operator's general endpoint (to the gateway, for
traces/metrics). Then live on k3d through Argo (commit 2d03e74): the `collector-agent` Application
synced (the `otel-agent-agent` DaemonSet came up ready), the sample app rolled
onto the new image and its logs endpoint, and `make verify-step6b` is green (7/7),
including the same DEBUG-dropped / INFO-kept check through the managed app path.
Full `make verify` is green (74/74), so the single-gateway path did not regress
(traces and metrics still reach the gateway directly).

Acceptance criteria:

- [x] A node-local agent DaemonSet runs in front of the gateway, gateway unchanged.
- [x] Only the app's logs route through the agent; traces/metrics go direct
      (per-signal endpoint confirmed to survive injection).
- [x] The agent drops DEBUG/probe noise and keeps INFO/errors (verified in Loki).
- [x] The topology is opt-in: removing the Application + app env reverts to Topology A.
- [x] Argo-path green live (`make verify-step6b` 7/7, full `make verify` 74/74).

## Step 7 — Autoscale the app on request rate (KEDA Prometheus scaler) (Pending live)

The first capability that acts on telemetry instead of just showing it. KEDA runs
as its own Argo Application (`keda`, sync-wave -1) and installs the operator, the
metrics apiserver, the webhooks, and its CRDs. A `ScaledObject` ships with the
sample app and scales sample-api on a Mimir query
(`sum(rate(traces_span_metrics_calls_total{service_name="sample-api"}[5m]))`),
between 1 and 5 replicas. The Deployment no longer sets `replicas`: git owns the
scaling policy (the ScaledObject), the HPA KEDA creates owns the replica count, so
Argo `selfHeal` does not fight the autoscaler. No scale-to-zero (that would need
the HTTP Add-on). See `docs/adr/020`.

### Build

```sh
make step7        # sync the keda Application + the ScaledObject on the app
make verify-step7
```

`make step7` applies the root app. Argo discovers the `keda` Application (wave -1,
so the CRDs land before the app applies a ScaledObject) and re-syncs `sample-app`
with the new `scaledobject.yaml`. Assumes Step 4 is up: the scaler reads the span
metrics Mimir already stores.

### Verify

```sh
make verify-step7    # KEDA healthy, ScaledObject Ready, HPA created, scales up under load then back to 1
```

`verify-step7` asserts the `keda` Application Synced/Healthy, the `sample-api`
ScaledObject is `Ready=True`, and KEDA created the HPA `keda-hpa-sample-api`
targeting the Deployment. Then it drives background traffic at `/rolldice` and
polls the Deployment's replica count past its floor of 1, stops the load, and
waits for it to fall back to 1. Give it time on the way up: the span metric lands
in Mimir only ~every 2 min, and the rate() window is 5m, so scale-up trails the
traffic by ~3 to 4 minutes. Scale-down is quick (~45s): once traffic stops the
rate goes empty, KEDA reads that as 0, and the HPA scales down within its 30s
stabilization window. The same checks by hand:

```sh
kubectl -n demo get scaledobject sample-api \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'   # -> True
kubectl -n demo get hpa keda-hpa-sample-api                        # targets Deployment/sample-api
kubectl -n demo get deploy sample-api -o jsonpath='{.spec.replicas}'  # 1 at rest

# drive load, then watch it scale (allow ~3-4 min up, ~1 min back down):
make load                                  # 8 workers for LOAD_SECONDS (default 180; use 420 for a full cycle)
kubectl -n demo get deploy sample-api -w   # replicas climb above 1, then back to 1 after load stops
```

Confirm the scaling signal itself in Grafana Explore (`mimir` datasource):
`sum(rate(traces_span_metrics_calls_total{service_name="sample-api"}[5m]))` rises
under load. This is the exact query the ScaledObject reads. Note the window: a
shorter one (`[1m]`, `[2m]`) returns empty here because the metric arrives only
~every 2 min, so the rate has too few samples to compute.

Note on verification: the scaling mechanism was proven live pre-push, in an
isolated `keda-verify` namespace so the Argo-managed sample-api was left untouched.
KEDA was installed with the exact chart + lab values (`kedacore/keda` 2.20.1, three
pods ready); the real `scaledobject.yaml` passed a server-side dry-run against the
live CRD; and a throwaway Deployment with a ScaledObject carrying the real Mimir
query scaled 1 -> 3 under load (HPA read ~800 calls/s, threshold 5, capped at max)
and back to 1 within ~45s of the load stopping. This run is what caught the window
bug: with a `[1m]` window the rate was always empty (the metric lands ~every 2 min),
so it was changed to `[5m]`. What is NOT yet done is the Argo path: `make step7`
syncing `keda` + the ScaledObject from `main`, and the `replicas`-removal not being
reverted by `selfHeal` on the managed app. That needs the change on `main`; this
section flips to Done once `make step7` + `make verify-step7` are green and full
`make verify` still passes.

Acceptance criteria:

- [x] KEDA installs and reconciles a ScaledObject to Ready; the HPA it creates scales a Deployment up under load and back down (proven live, isolated namespace).
- [x] The real `scaledobject.yaml` validates against the live CRD (server dry-run).
- [ ] Argo path: `make step7` syncs `keda` (wave -1) + the ScaledObject on the app.
- [ ] `deployment.yaml` no longer pins `replicas`; Argo `selfHeal` does not revert a scale.
- [ ] Argo-path green live (`make verify-step7`, full `make verify`).
