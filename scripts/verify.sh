#!/usr/bin/env bash
#
# Automated verification for otel-platform-lab.
# Asserts the expected state of each build step. Exits non-zero if any check
# fails, so it can run in CI. Usage:
#
#   scripts/verify.sh step0   # scaffold: cluster + ArgoCD
#   scripts/verify.sh step1   # Grafana synced and reachable
#   scripts/verify.sh all     # every implemented step, in order
#
# Overridable via env: CTX, ARGO_URL, GRAFANA_URL, GRAFANA_PW.

set -uo pipefail

CTX="${CTX:-k3d-otel-lab}"
ARGO_URL="${ARGO_URL:-http://localhost:8081}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_PW="${GRAFANA_PW:-otel-lab-admin}"
KUBECTL="kubectl --context ${CTX}"

FAILED=0

pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILED=$((FAILED + 1)); }

# assert_eq <desc> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# assert_contains <desc> <needle> <haystack>
assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1 (missing '$2')" ;;
  esac
}

# assert_ge <desc> <min> <actual>
assert_ge() {
  if [ "${3:-0}" -ge "$2" ] 2>/dev/null; then pass "$1"; else fail "$1 (expected >= $2, got '${3:-}')"; fi
}

verify_step0() {
  echo "Step 0 - scaffold (cluster + ArgoCD):"

  local ready_nodes
  ready_nodes=$($KUBECTL get nodes --no-headers 2>/dev/null | grep -c ' Ready ')
  assert_ge "cluster has a Ready node" 1 "$ready_nodes"

  local argo_ready
  argo_ready=$($KUBECTL -n argocd get deploy argocd-server -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  assert_ge "argocd-server deployment available" 1 "$argo_ready"

  local ver
  ver=$(curl -s "${ARGO_URL}/api/version" 2>/dev/null)
  assert_contains "Argo API /api/version responds" '"Version"' "$ver"

  local ap code
  ap=$($KUBECTL -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  code=$(curl -s -o /dev/null -w '%{http_code}' "${ARGO_URL}/api/v1/session" \
    -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"${ap}\"}" 2>/dev/null)
  assert_eq "Argo admin login returns 200" "200" "$code"
}

verify_step1() {
  echo "Step 1 - Grafana via ArgoCD:"

  local gstate
  gstate=$($KUBECTL -n argocd get application grafana \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "grafana Application Synced/Healthy" "Synced/Healthy" "$gstate"

  local rstate
  rstate=$($KUBECTL -n argocd get application root \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "root Application Synced/Healthy" "Synced/Healthy" "$rstate"

  local np
  np=$($KUBECTL -n observability get svc grafana -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
  assert_eq "grafana Service NodePort is 30300" "30300" "$np"

  local avail
  avail=$($KUBECTL -n observability get deploy grafana -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  assert_ge "grafana deployment available" 1 "$avail"

  local health
  health=$(curl -s "${GRAFANA_URL}/api/health" 2>/dev/null)
  assert_contains "Grafana /api/health database ok" '"database": "ok"' "$health"

  local user
  user=$(curl -s -u "admin:${GRAFANA_PW}" "${GRAFANA_URL}/api/user" 2>/dev/null)
  assert_contains "Grafana admin login works" '"isGrafanaAdmin":true' "$user"

  # Datasources are no longer asserted here. Grafana starts empty, but from
  # Step 2b on, each backend ships its own datasource via the sidecar. The
  # Tempo datasource is checked in verify_step2b.
}

verify_step2a() {
  echo "Step 2a - OTel Operator:"

  local appstate
  appstate=$($KUBECTL -n argocd get application otel-operator \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "otel-operator Application Synced/Healthy" "Synced/Healthy" "$appstate"

  local avail
  avail=$($KUBECTL -n opentelemetry-operator-system get deploy opentelemetry-operator \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  assert_ge "operator deployment available" 1 "$avail"

  if $KUBECTL get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1; then
    pass "CRD opentelemetrycollectors present"
  else
    fail "CRD opentelemetrycollectors present"
  fi

  if $KUBECTL get crd instrumentations.opentelemetry.io >/dev/null 2>&1; then
    pass "CRD instrumentations present"
  else
    fail "CRD instrumentations present"
  fi

  local mwh
  mwh=$($KUBECTL get mutatingwebhookconfiguration -o name 2>/dev/null | grep -c opentelemetry)
  assert_ge "mutating webhook for opentelemetry present" 1 "$mwh"
}

verify_step2b() {
  echo "Step 2b - Tempo backend + Grafana datasource:"

  local appstate
  appstate=$($KUBECTL -n argocd get application tempo \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "tempo Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # Tempo runs as a StatefulSet. Its readinessProbe hits /ready on 3200, so a
  # ready replica already proves /ready responds; no port-forward needed.
  local ready
  ready=$($KUBECTL -n observability get statefulset tempo \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  assert_ge "tempo StatefulSet ready (readinessProbe hits /ready)" 1 "$ready"

  # OTLP gRPC ingress is exposed. The Collector (Step 2c) pushes traces here.
  local otlp
  otlp=$($KUBECTL -n observability get svc tempo \
    -o jsonpath='{.spec.ports[?(@.port==4317)].port}' 2>/dev/null)
  assert_eq "tempo Service exposes OTLP 4317" "4317" "$otlp"

  # The datasource sidecar loaded the Tempo datasource into Grafana.
  local ds
  ds=$(curl -s -u "admin:${GRAFANA_PW}" "${GRAFANA_URL}/api/datasources" 2>/dev/null)
  assert_contains "Grafana has a Tempo datasource" '"type":"tempo"' "$ds"
}

verify_step2c() {
  echo "Step 2c - OTel Collector (single ingress gateway):"

  local appstate
  appstate=$($KUBECTL -n argocd get application collector \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "collector Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # Gateway is a Deployment. An available replica proves it started and passed
  # its health_check readiness probe.
  local avail
  avail=$($KUBECTL -n observability get deploy otel-collector \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  assert_ge "collector deployment available" 1 "$avail"

  # OTLP ingress is exposed on both gRPC (4317) and HTTP (4318). Apps (Step 2d)
  # send here; nothing talks to a backend directly (ADR 002).
  local grpc http
  grpc=$($KUBECTL -n observability get svc otel-collector \
    -o jsonpath='{.spec.ports[?(@.port==4317)].port}' 2>/dev/null)
  assert_eq "collector Service exposes OTLP gRPC 4317" "4317" "$grpc"
  http=$($KUBECTL -n observability get svc otel-collector \
    -o jsonpath='{.spec.ports[?(@.port==4318)].port}' 2>/dev/null)
  assert_eq "collector Service exposes OTLP HTTP 4318" "4318" "$http"

  # The rendered config exports to Tempo. Proves the pipeline is wired without
  # needing a live trace (that is Step 2e).
  local cfg
  cfg=$($KUBECTL -n observability get cm otel-collector -o yaml 2>/dev/null)
  assert_contains "collector exports to Tempo" 'tempo.observability.svc.cluster.local:4317' "$cfg"
}

verify_step2d() {
  echo "Step 2d - auto-instrumentation + sample app:"

  # Both Applications Synced/Healthy.
  local injstate appstate
  injstate=$($KUBECTL -n argocd get application otel-injection \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "otel-injection Application Synced/Healthy" "Synced/Healthy" "$injstate"

  appstate=$($KUBECTL -n argocd get application sample-app \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "sample-app Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # The Instrumentation CR is present in the app namespace.
  if $KUBECTL -n demo get instrumentation python >/dev/null 2>&1; then
    pass "Instrumentation CR present in demo"
  else
    fail "Instrumentation CR present in demo"
  fi

  # The sample app is running.
  local avail
  avail=$($KUBECTL -n demo get deploy sample-api \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  assert_ge "sample-api deployment available" 1 "$avail"

  # The webhook injected the auto-instrumentation init-container...
  local initc
  initc=$($KUBECTL -n demo get pod -l app=sample-api \
    -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null)
  assert_contains "auto-instrumentation init-container injected" "opentelemetry-auto-instrumentation" "$initc"

  # ...and pointed the exporter at the Collector, never a backend (ADR 002).
  local endpoint
  endpoint=$($KUBECTL -n demo get pod -l app=sample-api \
    -o jsonpath='{.items[0].spec.containers[0].env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}' 2>/dev/null)
  assert_contains "OTEL endpoint points at the Collector" "otel-collector.observability" "$endpoint"
}

verify_step2e() {
  echo "Step 2e - one trace queryable end to end:"

  # Drive a few requests so the app emits traces. Short-lived in-cluster pod.
  if $KUBECTL -n demo run trace-gen --rm -i --restart=Never \
    --image=curlimages/curl:latest --command -- \
    sh -c 'for i in 1 2 3 4 5; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done' \
    >/dev/null 2>&1; then
    pass "drove traffic to sample-api /rolldice"
  else
    fail "drove traffic to sample-api /rolldice"
  fi

  # Query Tempo through the Grafana datasource proxy. Traces are ingested
  # asynchronously (Collector batch + Tempo write), so retry a few times.
  local resp=""
  for attempt in 1 2 3 4 5 6; do
    resp=$(curl -s -u "admin:${GRAFANA_PW}" -G \
      "${GRAFANA_URL}/api/datasources/proxy/uid/tempo/api/search" \
      --data-urlencode 'q={ resource.service.name="sample-api" }' \
      --data-urlencode 'limit=5' 2>/dev/null)
    case "$resp" in
      *'"traceID"'*) break ;;
    esac
    sleep 5
  done
  assert_contains "Tempo returns a sample-api trace" '"traceID"' "${resp:-}"
}

verify_step3() {
  echo "Step 3 - Loki logs pipeline + trace correlation:"

  local appstate
  appstate=$($KUBECTL -n argocd get application loki \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "loki Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # Loki runs as a StatefulSet. Its readinessProbe hits /ready on 3100, so a
  # ready replica already proves /ready responds.
  local ready
  ready=$($KUBECTL -n observability get statefulset loki \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  assert_ge "loki StatefulSet ready (readinessProbe hits /ready)" 1 "$ready"

  # The datasource sidecar loaded the Loki datasource into Grafana.
  local ds
  ds=$(curl -s -u "admin:${GRAFANA_PW}" "${GRAFANA_URL}/api/datasources" 2>/dev/null)
  assert_contains "Grafana has a Loki datasource" '"type":"loki"' "$ds"

  # The logs-to-trace derived field must keep its url template. If the '$' is
  # not escaped as '$$' in the datasource YAML, Grafana's provisioning reads
  # ${__value.raw} as an env var and blanks it, so "View trace" sends an empty
  # trace id. Assert the loaded url still carries the template.
  local lds
  lds=$(curl -s -u "admin:${GRAFANA_PW}" "${GRAFANA_URL}/api/datasources/uid/loki" 2>/dev/null)
  assert_contains "Loki trace_id derived field url is set (\$ escaped)" '__value.raw' "$lds"

  # Drive traffic so the app emits a log line carrying its trace_id.
  if $KUBECTL -n demo run log-gen --rm -i --restart=Never \
    --image=curlimages/curl:latest --command -- \
    sh -c 'for i in 1 2 3 4 5; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done' \
    >/dev/null 2>&1; then
    pass "drove traffic to sample-api /rolldice"
  else
    fail "drove traffic to sample-api /rolldice"
  fi

  # Query Loki through the Grafana proxy for a sample-api log line that carries
  # a trace_id (kept as structured metadata). The `| trace_id != ""` filter is
  # the whole point: it proves the log-to-trace pivot has something to key on.
  # Retry, since ingestion is async.
  local start end resp=""
  end=$(( $(date +%s) * 1000000000 ))
  start=$(( ($(date +%s) - 3600) * 1000000000 ))
  for attempt in 1 2 3 4 5 6; do
    resp=$(curl -s -u "admin:${GRAFANA_PW}" -G \
      "${GRAFANA_URL}/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
      --data-urlencode 'query={service_name="sample-api"} | trace_id != ""' \
      --data-urlencode "start=${start}" --data-urlencode "end=${end}" \
      --data-urlencode 'limit=5' 2>/dev/null)
    case "$resp" in
      *'rolled a'*) break ;;
    esac
    sleep 5
  done
  assert_contains "Loki has a sample-api log line with a trace_id" 'rolled a' "${resp:-}"
}

verify_step4a() {
  echo "Step 4a - Mimir backend + Grafana datasource:"

  local appstate
  appstate=$($KUBECTL -n argocd get application mimir \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "mimir Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # Mimir runs as microservices (ingest-storage), not one binary. The ingester
  # is the write-path core: a ready ingester proves the OTLP write path can land
  # samples. It is a StatefulSet, so readyReplicas is the check.
  local ready
  ready=$($KUBECTL -n observability get statefulset mimir-ingester \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  assert_ge "mimir-ingester StatefulSet ready" 1 "$ready"

  # The datasource sidecar loaded the Mimir datasource. It speaks the Prometheus
  # query API, so the type is prometheus (there is no mimir datasource type).
  local ds
  ds=$(curl -s -u "admin:${GRAFANA_PW}" "${GRAFANA_URL}/api/datasources" 2>/dev/null)
  assert_contains "Grafana has a Mimir (prometheus) datasource" '"type":"prometheus"' "$ds"
}

verify_step4b() {
  echo "Step 4b - a span metric and the app counter queryable in Mimir:"

  # Drive traffic so the app emits spans (-> span metrics) and increments its
  # dice.rolls counter (-> direct metric). Short-lived in-cluster curl pod, same
  # idiom as step2e/step3.
  if $KUBECTL -n demo run metric-gen --rm -i --restart=Never \
    --image=curlimages/curl:latest --command -- \
    sh -c 'for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done' \
    >/dev/null 2>&1; then
    pass "drove traffic to sample-api /rolldice"
  else
    fail "drove traffic to sample-api /rolldice"
  fi

  # Query Mimir through the Grafana datasource proxy. The Mimir datasource URL
  # already ends in /prometheus, so the proxy path appends /api/v1/query to it.
  # Two metrics prove the two paths (see docs/adr/014, docs/adr/015):
  #   - traces_span_metrics_calls_total : RED metric the span_metrics connector
  #     derives from traces (no app change). The _total suffix needs Mimir's
  #     otel_metric_suffixes_enabled, which values.yaml sets.
  #   - dice_rolls_total : the app's own SDK counter, the direct path.
  # Both are pushed then ingested asynchronously (SDK exports ~60s, span metrics
  # flush on their own interval), so retry generously.
  local span_resp="" dice_resp=""
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ -z "$span_resp" ] || [ "$span_resp" = "empty" ]; then
      span_resp=$(curl -s -u "admin:${GRAFANA_PW}" -G \
        "${GRAFANA_URL}/api/datasources/proxy/uid/mimir/api/v1/query" \
        --data-urlencode 'query=traces_span_metrics_calls_total{service_name="sample-api"}' 2>/dev/null)
    fi
    if [ -z "$dice_resp" ] || [ "$dice_resp" = "empty" ]; then
      dice_resp=$(curl -s -u "admin:${GRAFANA_PW}" -G \
        "${GRAFANA_URL}/api/datasources/proxy/uid/mimir/api/v1/query" \
        --data-urlencode 'query=dice_rolls_total' 2>/dev/null)
    fi
    # A non-empty Prometheus vector has a "metric" object in its result array.
    case "$span_resp" in *'"metric"'*) : ;; *) span_resp="empty" ;; esac
    case "$dice_resp" in *'"metric"'*) : ;; *) dice_resp="empty" ;; esac
    [ "$span_resp" != "empty" ] && [ "$dice_resp" != "empty" ] && break
    sleep 5
  done
  assert_contains "Mimir returns a sample-api span metric (traces_span_metrics_calls_total)" \
    '"metric"' "$span_resp"
  assert_contains "Mimir returns the app counter (dice_rolls_total)" \
    '"metric"' "$dice_resp"
}

verify_injection() {
  echo "Injection - the webhook injects the auto-instrumentation init-container:"

  # Server-side dry-run a pod with the inject annotation, in demo (which holds
  # the `python` Instrumentation CR from Step 2d). The mutating webhook runs on a
  # server dry-run but nothing is persisted.
  #
  # This is the check verify_step2d cannot do. Step 2d inspects a long-lived pod
  # that was injected once; it stays green even if the webhook later breaks. Here
  # we exercise the webhook on a fresh pod. If the webhook cert has drifted,
  # mpod.kb.io (failurePolicy=Ignore) lets the pod through with no init-container,
  # so the result is empty rather than an error. That empty result is the failure.
  local initc
  initc=$($KUBECTL -n demo run inject-probe --dry-run=server \
    -o jsonpath='{.spec.initContainers[*].name}' \
    --image=sample-api:0.1.0 --restart=Never --override-type=merge \
    --overrides='{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-python":"python"}}}' 2>/dev/null)
  assert_contains "webhook injects auto-instrumentation on a fresh pod" \
    "opentelemetry-auto-instrumentation" "$initc"
}

verify_step5a() {
  echo "Step 5a - the Mimir ruler and Alertmanager are up:"

  local appstate
  appstate=$($KUBECTL -n argocd get application mimir \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "mimir Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # The ruler is a Deployment in mimir-distributed; only the alertmanager is a
  # StatefulSet (it has a PVC).
  local ruler_ready am_ready
  ruler_ready=$($KUBECTL -n observability get deployment mimir-ruler \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  assert_ge "mimir-ruler Deployment ready" 1 "$ruler_ready"
  am_ready=$($KUBECTL -n observability get statefulset mimir-alertmanager \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  assert_ge "mimir-alertmanager StatefulSet ready" 1 "$am_ready"

  # The ruler read API through the gateway (via the Grafana proxy). An empty rule
  # set is fine here; Step 5b loads the rules. This just proves the ruler answers.
  local rules_resp
  rules_resp=$(curl -s -u "admin:${GRAFANA_PW}" \
    "${GRAFANA_URL}/api/datasources/proxy/uid/mimir/api/v1/rules" 2>/dev/null)
  assert_contains "Mimir ruler API reachable" '"status":"success"' "$rules_resp"
}

verify_step5b() {
  echo "Step 5b - the RED rules load and the ruler evaluates them:"

  local appstate
  appstate=$($KUBECTL -n argocd get application mimir-rules \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "mimir-rules Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # The ruler lists our rule group and one of the alerts.
  local rules_resp
  rules_resp=$(curl -s -u "admin:${GRAFANA_PW}" \
    "${GRAFANA_URL}/api/datasources/proxy/uid/mimir/api/v1/rules" 2>/dev/null)
  assert_contains "ruler has the app_red_alerts group" '"name":"app_red_alerts"' "$rules_resp"
  assert_contains "ruler has the AppHighErrorRatio alert" '"name":"AppHighErrorRatio"' "$rules_resp"

  # Drive traffic so the app emits spans (-> span metrics the rules read), then
  # read back a recording-rule series. Its presence proves the ruler evaluates.
  if $KUBECTL -n demo run metric-gen --rm -i --restart=Never \
    --image=curlimages/curl:latest --command -- \
    sh -c 'for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null http://sample-api.demo.svc.cluster.local/rolldice; sleep 1; done' \
    >/dev/null 2>&1; then
    pass "drove traffic to sample-api /rolldice"
  else
    fail "drove traffic to sample-api /rolldice"
  fi

  # The ruler evaluates on an interval, and the span metric has to reach Mimir
  # first (the SDK/connector export on ~60s), then rate[5m] needs a couple of
  # samples, so retry generously. No job filter: Mimir sets job to
  # "<namespace>/<service.name>" (demo/sample-api), and this is the only job that
  # produces span metrics, so the bare recording series is enough proof.
  local rec_resp="empty"
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    rec_resp=$(curl -s -u "admin:${GRAFANA_PW}" -G \
      "${GRAFANA_URL}/api/datasources/proxy/uid/mimir/api/v1/query" \
      --data-urlencode 'query=job:span_requests:rate5m' 2>/dev/null)
    case "$rec_resp" in *'"metric"'*) break ;; *) rec_resp="empty" ;; esac
    sleep 5
  done
  assert_contains "ruler wrote the recording rule series (job:span_requests:rate5m)" \
    '"metric"' "$rec_resp"
}

verify_step5c() {
  echo "Step 5c - the webhook sink is up and the alert path is reachable:"

  local appstate avail
  appstate=$($KUBECTL -n argocd get application alert-sink \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "alert-sink Application Synced/Healthy" "Synced/Healthy" "$appstate"
  avail=$($KUBECTL -n observability get deployment alert-sink \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  assert_ge "alert-sink Deployment available" 1 "$avail"

  local am_ready alerts_resp
  am_ready=$($KUBECTL -n observability get statefulset mimir-alertmanager \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  assert_ge "mimir-alertmanager StatefulSet ready" 1 "$am_ready"
  # The ruler alerts API answers (the ruler -> Alertmanager path is wired). A real
  # alert takes 5m of sustained errors to fire, so that is a manual check, not here.
  alerts_resp=$(curl -s -u "admin:${GRAFANA_PW}" \
    "${GRAFANA_URL}/api/datasources/proxy/uid/mimir/api/v1/alerts" 2>/dev/null)
  assert_contains "ruler alerts API reachable" '"status":"success"' "$alerts_resp"
}

verify_step5d() {
  echo "Step 5d - the RED dashboard loaded into Grafana:"

  local appstate
  appstate=$($KUBECTL -n argocd get application grafana-dashboards \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "grafana-dashboards Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # The sidecar imports the dashboard asynchronously, so retry until it appears.
  local dash_resp="empty"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    dash_resp=$(curl -s -u "admin:${GRAFANA_PW}" \
      "${GRAFANA_URL}/api/dashboards/uid/app-red" 2>/dev/null)
    case "$dash_resp" in *'"uid":"app-red"'*) break ;; *) dash_resp="empty" ;; esac
    sleep 5
  done
  assert_contains "RED dashboard imported (uid app-red)" '"uid":"app-red"' "$dash_resp"
}

verify_step6a() {
  echo "Step 6a - platform self-health (k8s_cluster metrics + alerts + dashboard):"

  # The collector now carries the k8s_cluster receiver + its ClusterRole. Argo
  # syncs it on the existing collector Application (no new Application).
  local appstate
  appstate=$($KUBECTL -n argocd get application collector \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
  assert_eq "collector Application Synced/Healthy" "Synced/Healthy" "$appstate"

  # The ClusterRole + binding exist and target the collector's ServiceAccount, so
  # the receiver can actually list/watch the API server.
  local crb_sa
  crb_sa=$($KUBECTL get clusterrolebinding otel-collector \
    -o jsonpath='{.subjects[0].name}' 2>/dev/null)
  assert_eq "collector ClusterRoleBinding targets its ServiceAccount" "otel-collector" "$crb_sa"

  # k8s_cluster metrics reached Mimir AND carry promoted workload identity. The
  # collector watches the API server continuously, so this needs no traffic, but
  # the OTLP export + ingest is async, so retry. Asserting the k8s_deployment_name
  # label is present proves promote_otel_resource_attributes worked (without it the
  # series collapses to a single unlabeled one). See docs/adr/018.
  local wl_resp="empty"
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    wl_resp=$(curl -s -u "admin:${GRAFANA_PW}" -G \
      "${GRAFANA_URL}/api/datasources/proxy/uid/mimir/api/v1/query" \
      --data-urlencode 'query=k8s_deployment_available{k8s_namespace_name="observability"}' 2>/dev/null)
    case "$wl_resp" in *'"k8s_deployment_name"'*) break ;; *) wl_resp="empty" ;; esac
    sleep 5
  done
  assert_contains "Mimir returns k8s_deployment_available for observability" '"metric"' "$wl_resp"
  assert_contains "the series carries the promoted k8s_deployment_name label" \
    '"k8s_deployment_name"' "$wl_resp"

  # The ruler loaded the platform-health group alongside the RED rules.
  local rules_resp
  rules_resp=$(curl -s -u "admin:${GRAFANA_PW}" \
    "${GRAFANA_URL}/api/datasources/proxy/uid/mimir/api/v1/rules" 2>/dev/null)
  assert_contains "ruler has the platform_health_alerts group" \
    '"name":"platform_health_alerts"' "$rules_resp"
  assert_contains "ruler has the PlatformDeploymentUnavailable alert" \
    '"name":"PlatformDeploymentUnavailable"' "$rules_resp"

  # The platform-health dashboard imported into Grafana.
  local dash_resp="empty"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    dash_resp=$(curl -s -u "admin:${GRAFANA_PW}" \
      "${GRAFANA_URL}/api/dashboards/uid/platform-health" 2>/dev/null)
    case "$dash_resp" in *'"uid":"platform-health"'*) break ;; *) dash_resp="empty" ;; esac
    sleep 5
  done
  assert_contains "platform-health dashboard imported (uid platform-health)" \
    '"uid":"platform-health"' "$dash_resp"
}

case "${1:-all}" in
  step0)  verify_step0 ;;
  step1)  verify_step1 ;;
  step2a) verify_step2a ;;
  step2b) verify_step2b ;;
  step2c) verify_step2c ;;
  step2d) verify_step2d ;;
  step2e) verify_step2e ;;
  step3)  verify_step3 ;;
  step4a) verify_step4a ;;
  step4b) verify_step4b ;;
  step5a) verify_step5a ;;
  step5b) verify_step5b ;;
  step5c) verify_step5c ;;
  step5d) verify_step5d ;;
  step6a) verify_step6a ;;
  injection) verify_injection ;;
  all)    verify_step0; echo; verify_step1; echo; verify_step2a; echo; verify_step2b; echo; \
          verify_step2c; echo; verify_step2d; echo; verify_step2e; echo; verify_step3; echo; \
          verify_step4a; echo; verify_step4b; echo; \
          verify_step5a; echo; verify_step5b; echo; verify_step5c; echo; verify_step5d; echo; \
          verify_step6a; echo; \
          verify_injection ;;
  *) echo "usage: $0 [step0|step1|step2a|step2b|step2c|step2d|step2e|step3|step4a|step4b|step5a|step5b|step5c|step5d|step6a|injection|all]" >&2; exit 2 ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK: all checks passed."
  exit 0
else
  echo "FAILED: ${FAILED} check(s) failed."
  exit 1
fi
