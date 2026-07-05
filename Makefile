## otel-platform-lab Makefile
## Step 1 targets: create k3d cluster, install ArgoCD, bootstrap Grafana.

CLUSTER      ?= otel-lab
ARGOCD_NS    ?= argocd
OBS_NS       ?= observability
ARGOCD_CHART ?= argo/argo-cd

.PHONY: help
help:
	@echo "Step 1 targets:"
	@echo "  make step1             - cluster + argocd + bootstrap (one shot)"
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

.PHONY: step1
step1: cluster argocd bootstrap
	@echo
	@echo "Step 1 install steps done. Waiting a bit for Grafana to sync..."
	@sleep 15
	@$(MAKE) status
	@echo
	@$(MAKE) urls

.PHONY: clean
clean:
	k3d cluster delete $(CLUSTER)
