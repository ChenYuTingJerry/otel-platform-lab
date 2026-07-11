## otel-platform-lab Makefile
##
## Build model: one scaffold step (Step 0) plus four signal steps.
##   Step 0  scaffold  - k3d cluster + ArgoCD          (make step0)   [done]
##   Step 1  Grafana   - the UI                         (make step1)   [done]
##   Step 2  Tempo     - traces                    (make step2b, step2c)  [2b,2c done]
##   Step 3  Loki      - logs                            (make step3)   [done]
##   Step 4  Mimir     - metrics                    (make step4a, step4b)  [4a,4b done]
## Each step is verified end to end before the next. See docs/VERIFICATION.md.

CLUSTER      ?= otel-lab
ARGOCD_NS    ?= argocd
OBS_NS       ?= observability
DEMO_NS      ?= demo
ARGOCD_CHART ?= argo/argo-cd
IMAGE_NAME   ?= sample-api
IMAGE_TAG    ?= 0.1.0

.PHONY: help
help:
	@echo "Build steps:"
	@echo "  make step0             - Step 0 scaffold: k3d cluster + ArgoCD"
	@echo "  make step1             - Step 1: bootstrap Grafana via Argo"
	@echo "  make step2b            - Step 2b: Tempo backend + Grafana datasource"
	@echo "  make step2c            - Step 2c: OTel Collector (single ingress gateway)"
	@echo "  make step2d            - Step 2d: auto-instrumentation + sample app"
	@echo "  make step3             - Step 3: Loki logs backend (OTLP via the Collector)"
	@echo "  make step4a            - Step 4a: Mimir metrics backend + Grafana datasource"
	@echo "  make step4b            - Step 4b: Collector metrics pipeline + app counter"
	@echo "  make step5a            - Step 5a: enable the Mimir ruler + Alertmanager"
	@echo "  make step5b            - Step 5b: RED rules + load them into the ruler"
	@echo "  make step5c            - Step 5c: webhook sink for fired alerts"
	@echo "  make step5d            - Step 5d: dashboards sidecar + RED dashboard"
	@echo
	@echo "Tests (assert state, exit non-zero on failure):"
	@echo "  make verify            - run every implemented step's checks"
	@echo "  make verify-step0      - assert the scaffold state"
	@echo "  make verify-step1      - assert Grafana synced and reachable"
	@echo "  make verify-step2b     - assert Tempo synced + datasource present"
	@echo "  make verify-step2c     - assert Collector synced + OTLP ingress up"
	@echo "  make verify-step2d     - assert injection + sample app running"
	@echo "  make verify-step2e     - assert one trace queryable in Tempo"
	@echo "  make verify-step3      - assert Loki synced + a log line with trace_id"
	@echo "  make verify-step4a     - assert Mimir synced + datasource present"
	@echo "  make verify-step4b     - assert a span metric + the app counter in Mimir"
	@echo "  make verify-step5a     - assert the ruler + Alertmanager are up"
	@echo "  make verify-step5b     - assert the RED rules load and the ruler evaluates them"
	@echo "  make verify-step5c     - assert the webhook sink is up and the AM path is reachable"
	@echo "  make verify-step5d     - assert the RED dashboard loaded into Grafana"
	@echo "  make test-rules        - unit-test the RED rules with promtool (local, no cluster)"
	@echo "  make verify-injection  - assert the webhook injects into a fresh pod"
	@echo
	@echo "Underlying targets:"
	@echo "  make sample-image      - build the sample app image + import into k3d"
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

## Build the sample app image and import it into the k3d cluster. No registry:
## k3d loads the local image so the Deployment (imagePullPolicy IfNotPresent)
## can run it. Re-run after changing apps/sample-api.
.PHONY: sample-image
sample-image:
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) apps/sample-api
	k3d image import $(IMAGE_NAME):$(IMAGE_TAG) -c $(CLUSTER)

## Step 2d: auto-instrumentation + sample app. Builds and imports the image,
## then applies the root app (idempotent); Argo discovers the otel-injection
## and sample-app Applications and syncs them. Waits for the app to go Healthy.
## Assumes Step 2c is up.
.PHONY: step2d
step2d: sample-image bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the sample-app Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/sample-app >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the sample-app Application to become Healthy..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/sample-app --timeout=180s
	@echo
	@$(MAKE) status

## Step 3: Loki logs backend. Applies the root app (idempotent); Argo discovers
## the loki Application and syncs it (StatefulSet + datasource). Waits for it to
## go Healthy. Assumes Step 2 is up (the Collector now also exports logs to Loki,
## and the sample app emits them as OTLP).
.PHONY: step3
step3: bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the loki Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/loki >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the loki Application to become Healthy..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/loki --timeout=180s
	@echo
	@$(MAKE) status

## Step 4a: Mimir metrics backend + Grafana datasource. Applies the root app
## (idempotent); Argo discovers the mimir Application and syncs it. Mimir is the
## heaviest backend (~12 pods incl. Kafka + MinIO), so the wait timeout is longer
## than the other steps. Assumes Step 3 is up. sync-wave 1, a backend like Tempo
## and Loki, up before the Collector (wave 2).
.PHONY: step4a
step4a: bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the mimir Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/mimir >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the mimir Application to become Healthy (Mimir is ~12 pods)..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/mimir --timeout=600s
	@echo
	@$(MAKE) status

## Step 4b: Collector metrics pipeline (span_metrics + direct passthrough) + the
## app's dice.rolls counter. Rebuilds and imports the image (the counter is new
## app code), then applies the root app (idempotent). Argo re-syncs the collector
## (now with a metrics pipeline) and sample-app (new image + OTEL_METRICS_EXPORTER
## flipped to otlp). Waits for the sample app to go Healthy. Assumes Step 4a is up.
.PHONY: step4b
step4b: sample-image bootstrap
	@echo
	@echo "Waiting for the sample-app Application to become Healthy..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/sample-app --timeout=180s
	@echo
	@$(MAKE) status

## Step 5a: enable the Mimir ruler + Alertmanager. Edits the mimir values only, so
## this rides the existing mimir Application: Argo re-syncs the Helm release and
## adds the ruler + alertmanager StatefulSets. Applies the root app (idempotent),
## waits for mimir to go Healthy again, then waits for the two new StatefulSets.
## Assumes Step 4 is up.
.PHONY: step5a
step5a: bootstrap
	@echo
	@echo "Waiting for Argo to sync the ruler + Alertmanager into the cluster..."
	@for i in $$(seq 1 60); do \
	  kubectl -n $(OBS_NS) get deploy/mimir-ruler >/dev/null 2>&1 && \
	  kubectl -n $(OBS_NS) get statefulset/mimir-alertmanager >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the ruler Deployment and Alertmanager StatefulSet to be ready..."
	@kubectl -n $(OBS_NS) rollout status deployment/mimir-ruler --timeout=300s
	@kubectl -n $(OBS_NS) rollout status statefulset/mimir-alertmanager --timeout=300s
	@echo
	@$(MAKE) status

## Step 5b: the RED rules + loading them into the ruler. Applies the root app
## (idempotent); Argo discovers the mimir-rules Application (a Kustomize dir) and
## syncs it: a ConfigMap of the rules plus a PostSync-hook Job that pushes them to
## the ruler with mimirtool. Waits for the Application to go Healthy. Assumes
## Step 5a is up. Run `make test-rules` first to unit-test the rules locally.
.PHONY: step5b
step5b: bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the mimir-rules Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/mimir-rules >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the mimir-rules Application to become Healthy..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/mimir-rules --timeout=300s
	@echo
	@$(MAKE) status

## Step 5c: the webhook sink for fired alerts. Applies the root app (idempotent);
## Argo discovers the alert-sink Application and syncs it (Deployment + Service).
## Waits for it to go Healthy. Assumes Step 5a is up (the Alertmanager routes here).
.PHONY: step5c
step5c: bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the alert-sink Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/alert-sink >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for the alert-sink Application to become Healthy..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/alert-sink --timeout=180s
	@echo
	@$(MAKE) status

## Step 5d: the dashboards sidecar + the RED dashboard. Edits grafana values to
## enable the dashboards sidecar (so Grafana re-syncs) and adds the
## grafana-dashboards Application (the dashboard ConfigMap). Applies the root app
## (idempotent); waits for both to go Healthy. Assumes Step 5b is up (the panels
## read the recording rules).
.PHONY: step5d
step5d: bootstrap
	@echo
	@echo "Waiting for the root app-of-apps to create the grafana-dashboards Application..."
	@for i in $$(seq 1 30); do \
	  kubectl -n $(ARGOCD_NS) get application/grafana-dashboards >/dev/null 2>&1 && break; \
	  sleep 5; \
	done
	@echo "Waiting for grafana to re-sync (dashboards sidecar) and the dashboards app..."
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/grafana --timeout=300s
	@kubectl -n $(ARGOCD_NS) wait --for=jsonpath='{.status.health.status}'=Healthy \
	  application/grafana-dashboards --timeout=180s
	@echo
	@$(MAKE) status

## Unit-test the RED rules with promtool, locally, no cluster needed. The rules
## live inline in configmap.yaml (the single source), so first extract that data
## key into a transient rendered file next to the tests (ruby ships with macOS),
## then run promtool in the prom/prometheus image (nothing to install on the host).
## Run this before `make step5b` to catch rule mistakes early.
RULES_DIR := k8s/manifests/mimir/rules
.PHONY: test-rules
test-rules:
	@ruby -ryaml -e 'print YAML.load_file("$(RULES_DIR)/configmap.yaml")["data"]["red-alerts.yaml"]' \
	  > $(RULES_DIR)/tests/red-alerts.rendered.yaml
	docker run --rm --entrypoint promtool \
	  -w /rules/tests \
	  -v $(PWD)/$(RULES_DIR):/rules \
	  prom/prometheus:v3.1.0 \
	  test rules /rules/tests/red-alerts_test.yaml; \
	  status=$$?; rm -f $(RULES_DIR)/tests/red-alerts.rendered.yaml; exit $$status

## Tests: assert the expected state of each step. Non-zero exit on failure.
.PHONY: verify verify-step0 verify-step1 verify-step2a verify-step2b verify-step2c verify-step2d verify-step2e verify-step3 verify-step4a verify-step4b verify-step5a verify-step5b verify-step5c verify-step5d verify-injection
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
verify-step2d:
	@./scripts/verify.sh step2d
verify-step2e:
	@./scripts/verify.sh step2e
verify-step3:
	@./scripts/verify.sh step3
verify-step4a:
	@./scripts/verify.sh step4a
verify-step4b:
	@./scripts/verify.sh step4b
verify-step5a:
	@./scripts/verify.sh step5a
verify-step5b:
	@./scripts/verify.sh step5b
verify-step5c:
	@./scripts/verify.sh step5c
verify-step5d:
	@./scripts/verify.sh step5d
verify-injection:
	@./scripts/verify.sh injection

.PHONY: clean
clean:
	k3d cluster delete $(CLUSTER)
