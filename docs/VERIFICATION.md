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
| Step 4a — Mimir backend + Grafana datasource | Done (data path verified on k3d) |
| Step 4b — Metrics pipeline (span metrics + direct metrics) | Done (data path verified on k3d) |

A full clean rebuild runs the done steps in order. The OTel Operator (Step 2a)
has no build target of its own: the root app-of-apps picks it up during
`make step1`, so it comes up in the same pass. Tempo (Step 2b) and the Collector
(Step 2c) are discovered the same way, but each has its own `make step2b` /
`make step2c` that waits for it to go Healthy.

```sh
make clean && make step0 && make step1 && make step2b && make step2c && make step2d && make step3 && make step4a && make step4b
make verify        # asserts step0 + step1 + step2a..2e + step3 + step4a + step4b
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

Note on verification: the data path was verified end to end on k3d in an
isolated `step4-smoke` namespace (Argo reads `main`, so like Steps 2c/3 the Argo
path goes green only after push). A real Mimir, a Collector with the new metrics
pipeline, and the injected sample app were brought up there, traffic driven, and
both metrics read back from Mimir's Prometheus query API:

- `traces_span_metrics_calls_total{service_name="sample-api"}` carried
  `http_method=GET`, `http_route=/rolldice`, `http_status_code=200` (the legacy
  HTTP semconv keys the Python SDK actually emits, so the dimensions are
  populated, not empty),
- `dice_rolls_total` carried the app's own counter value,
- both carried `deployment_environment=lab` as a real label, which proves the
  `promote_otel_resource_attributes` promotion works (without it the attribute
  would sit in a `target_info` series). The `_total` suffix confirms
  `otel_metric_suffixes_enabled` is on.

The Grafana proxy query path in the checks above was validated against that same
data. `make verify-step4a` / `verify-step4b` exercise the same workload through
Argo once the manifests are on `main`.

Acceptance criteria:

- [x] Mimir deployed via an Argo Application.
- [x] Span metrics derived from traces (Collector `span_metrics`) land in Mimir.
- [x] A direct metrics path works too (SDK OTLP + the custom `dice_rolls_total`).
- [x] Grafana has a Mimir datasource; metrics stay aggregate (low cardinality).
