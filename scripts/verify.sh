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

case "${1:-all}" in
  step0)  verify_step0 ;;
  step1)  verify_step1 ;;
  step2a) verify_step2a ;;
  step2b) verify_step2b ;;
  step2c) verify_step2c ;;
  step2d) verify_step2d ;;
  step2e) verify_step2e ;;
  all)    verify_step0; echo; verify_step1; echo; verify_step2a; echo; verify_step2b; echo; \
          verify_step2c; echo; verify_step2d; echo; verify_step2e ;;
  *) echo "usage: $0 [step0|step1|step2a|step2b|step2c|step2d|step2e|all]" >&2; exit 2 ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK: all checks passed."
  exit 0
else
  echo "FAILED: ${FAILED} check(s) failed."
  exit 1
fi
