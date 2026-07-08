## otel-platform-lab Makefile
##
## Build model: one scaffold step (Step 0) plus four signal steps.
##   Step 0  scaffold  - k3d cluster + ArgoCD          (make step0)   [done]
##   Step 1  Grafana   - the UI                         (make step1)   [done]
##   Step 2  Tempo     - traces                    (make step2b, step2c)  [2b,2c done]
##   Step 3  Loki      - logs                                          [todo]
##   Step 4  Mimir     - metrics                                       [todo]
## Each step is verified end to end before the next. See docs/VERIFICATION.md.

CLUSTER      ?= otel-lab
ARGOCD_NS    ?= argocd
OBS_NS       ?= observability
ARGOCD_CHART ?= argo/argo-cd

.PHONY: help
help:
	@echo "Build steps:"
	@echo "  make step0             - Step 0 scaffold: k3d cluster + ArgoCD"
	@echo "  make step1             - Step 1: bootstrap Grafana via Argo"
	@echo "  make step2b            - Step 2b: Tempo backend + Grafana datasource"
	@echo "  make step2c            - Step 2c: OTel Collector (single ingress gateway)"
	@echo "  (step3-4: Loki / Mimir, not implemented yet)"
	@echo
	@echo "Tests (assert state, exit non-zero on failure):"
	@echo "  make verify            - run every implemented step's checks"
	@echo "  make verify-step0      - assert the scaffold state"
	@echo "  make verify-step1      - assert Grafana synced and reachable"
	@echo "  make verify-step2b     - assert Tempo synced + datasource present"
	@echo "  make verify-step2c     - assert Collector synced + OTLP ingress up"
	@echo
	@echo "Underlying targets:"
	@echo "  make cluster           - create k3d cluster $(CLUSTER)"
	@echo "  make argocd            - helm install ArgoCD into ns $(ARGOCD_NS)"
	@echo "  make bootstrap         - apply the root Application (app-of-apps)"
	@echo "  make status            - show Argo Applications + pods"
	@echo "  make argo-password     - print initial Argo admin password"
	@echo "  make grafana-password  - print Grafana admin password"
	@echo "  make urls              - print Argo + Grafana local URLs"
	@echo "  make clean             - delete the k3d cluster"

.PHONY: cluster
cluster:
	@if k3d cluster list | grep -q "^$(CLUSTER) "; then \
	  echo "cluster $(CLUSTER) already exists, skipping"; \
	else \
	  k3d cluster create $(CLUSTER) \
	    --port "3000:30300@server:0" \
	    --port "8081:30080@server:0" \
	    --k3s-arg "--disable=traefik@server:0"; \
	fi
	kubectl config use-context k3d-$(CLUSTER)

.PHONY: argocd
argocd:
	helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
	helm repo update argo >/dev/null
	kubectl create namespace $(ARGOCD_NS) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install argocd $(ARGOCD_CHART) \
	  --namespace $(ARGOCD_NS) \
	  --values k8s/argocd/install/values.yaml \
	  --wait --timeout 10m
	@echo "waiting for argocd server..."
	kubectl -n $(ARGOCD_NS) rollout status deploy/argocd-server --timeout=5m

.PHONY: bootstrap
bootstrap:
	kubectl apply -f k8s/argocd/root-app.yaml
	@echo "root Application applied. Argo will pick up children under k8s/argocd/applications/"

.PHONY: status
status:
	@echo "== ArgoCD Applications =="
	@kubectl -n $(ARGOCD_NS) get applications || true
	@echo
	@echo "== Pods (all namespaces) =="
	@kubectl get pods -A

.PHONY: argo-password
argo-password:
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d && echo

.PHONY: grafana-password
grafana-password:
	@kubectl -n $(OBS_NS) get secret grafana \
	  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d && echo || \
	  echo "(Grafana secret not ready yet, check with: kubectl -n $(OBS_NS) get pods)"

.PHONY: urls
urls:
	@echo "Argo UI:    http://localhost:8081  (admin / \`make argo-password\`)"
	@echo "Grafana UI: http://localhost:3000  (admin / \`make grafana-password\`)"

## Step 0: scaffold. k3d cluster + ArgoCD. No workloads yet.
.PHONY: step0
step0: cluster argocd
	@echo
	@echo "Step 0 done: cluster + ArgoCD up."
	@echo "Argo UI: http://localhost:8081  (admin / \`make argo-password\`)"

## Step 1: bootstrap Grafana. Assumes Step 0 is up. Applies the root
## app-of-apps; Argo then syncs Grafana. Waits for it to go Healthy.
.PHONY: step1
step1: bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the grafana Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/grafana >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the grafana Application to become Healthy..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/grafana --timeout=180s
	@echo
	@$(MAKE) status
	@echo
	@$(MAKE) urls

## Step 2b: Tempo backend + Grafana datasource. Assumes Step 1 is up (root
## app-of-apps exists). Applies the root app (idempotent); Argo discovers the
## tempo Application and syncs it. Waits for it to go Healthy.
.PHONY: step2b
step2b: bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the tempo Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/tempo >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the tempo Application to become Healthy..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/tempo --timeout=180s
	@echo
	@$(MAKE) status

## Step 2c: OTel Collector, the single telemetry ingress (gateway). Assumes
## Step 2b is up. Applies the root app (idempotent); Argo discovers the
## collector Application and syncs it. Waits for it to go Healthy.
.PHONY: step2c
step2c: bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the collector Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/collector >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the collector Application to become Healthy..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/collector --timeout=180s
	@echo
	@$(MAKE) status

## Tests: assert the expected state of each step. Non-zero exit on failure.
.PHONY: verify verify-step0 verify-step1 verify-step2a verify-step2b verify-step2c
verify:
	@./scripts/verify.sh all
verify-step0:
	@./scripts/verify.sh step0
verify-step1:
	@./scripts/verify.sh step1
verify-step2a:
	@./scripts/verify.sh step2a
verify-step2b:
	@./scripts/verify.sh step2b
verify-step2c:
	@./scripts/verify.sh step2c

.PHONY: clean
clean:
	k3d cluster delete $(CLUSTER)
