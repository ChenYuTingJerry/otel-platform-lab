# ADR 009: Collector runs as a central Deployment (gateway)

Status: Accepted
Date: 2026-07-08

## Context

ADR 002 fixes that the Collector is the single telemetry ingress. It does not
say *how* the Collector runs. There are three ways, each with a different
resource profile:

- **Sidecar**: a collector container injected into each app pod by the operator
  webhook. The app sends to localhost. Each sidecar handles only its own pod's
  telemetry, so it can be sized tiny, and its cost scales with the app, down to
  zero when the app scales to zero. There is no always-on central tier to size
  for peak and no idle capacity held for HA. This is where sidecar saves
  resources: the total cost tracks the workloads that are actually running. The
  price is many small collectors, each with a base footprint, so the overhead
  grows once the pod count is high.
- **Agent (DaemonSet)**: one collector per node. Apps send to the node-local
  collector. The count is bounded by nodes, not pods, and telemetry stays on the
  node. But every node runs one, including near-idle nodes.
- **Gateway (Deployment)**: one central collector (or a few replicas) behind a
  Service. All apps send there. The footprint is fixed and predictable in one
  place, but you size it for the aggregate peak and may hold idle or HA capacity.

Two ways to deploy a gateway: the `opentelemetry-collector` Helm chart, or an
`OpenTelemetryCollector` CR managed by the operator.

## Decision

Run the Collector as a central **Deployment (gateway)**, deployed with the
`opentelemetry-collector` Helm chart.

At lab scale (5 to 6 services, about 10 pods) one gateway sized at ~256Mi costs
less in total than about 10 sidecars, each with its own base footprint, and it
is simpler to reason about (one place to size). Sidecar's resource advantage
(cost tracks the workloads, scales to zero, no idle central tier) only wins at a
different shape: few, large, bursty, or intermittent workloads where a central
gateway would sit over-provisioned. That is not our case now.

Use the Helm chart, not the `OpenTelemetryCollector` CR. For a gateway the CR
adds no capability over the chart. Its one unique feature, sidecar injection, is
not a gateway concern. The CR would only add an extra operator and Argo layer.

## Consequences

- Simple and cheap at the current scale. One collector to size, one place to set
  resource limits.
- No per-node waste (DaemonSet) and no per-pod multiplication (sidecar).
- The backend faces only a few controlled clients (the gateway replicas).
  Batching, rate control, and tail sampling happen once, centrally. Sidecars
  that export straight to the backend open one connection per pod and cannot do
  global or tail sampling. This is the backend-protection side of ADR 002's
  single-ingress rule.
- Trade-off: the gateway is a shared critical path, and it adds one network hop
  (app to central collector to backend) compared with a node-local agent.
  Accepted at lab scale; add replicas later if needed.
- The whole collector workload (Deployment, Service, ConfigMap) stays in the
  Helm release and is fully Argo-managed, with drift detection on all of it.
  With the CR the runtime is operator-owned derived state that Argo does not
  manage.
- The operator stays, but only for Step 2d auto-instrumentation. It does not
  manage the collector. Do not confuse the two operator CRs: the
  `OpenTelemetryCollector` CR (declined here) deploys a collector, while the
  `Instrumentation` CR (used in Step 2d) injects an init-container that installs
  a language SDK into an app and points it at the collector.
- No sidecar-collector layer is needed: an auto-instrumented app's SDK sends
  OTLP straight to the gateway Service, and the SDK already does its own
  batching and retry. The `OpenTelemetryCollector` CR earns its keep only when
  you need sidecar mode (per-pod local buffering, protocol translation, or
  offloading export from a thin SDK) or the operator target allocator for
  sharded Prometheus scraping. A trace gateway needs neither.
- Revisit trigger: at higher scale or throughput, add a DaemonSet agent tier
  (agent collects locally, forwards to the gateway) or scale the gateway with
  replicas. Use sidecars only if a service needs per-pod isolation.
