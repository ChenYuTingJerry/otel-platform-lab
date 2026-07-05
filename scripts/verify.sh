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

  local ds
  ds=$(curl -s -u "admin:${GRAFANA_PW}" "${GRAFANA_URL}/api/datasources" 2>/dev/null)
  assert_eq "Grafana has zero datasources (empty until Step 2+)" "[]" "$ds"
}

case "${1:-all}" in
  step0) verify_step0 ;;
  step1) verify_step1 ;;
  all)   verify_step0; echo; verify_step1 ;;
  *) echo "usage: $0 [step0|step1|all]" >&2; exit 2 ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK: all checks passed."
  exit 0
else
  echo "FAILED: ${FAILED} check(s) failed."
  exit 1
fi
