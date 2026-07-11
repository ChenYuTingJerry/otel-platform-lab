# ADR 019: Optional node-local agent tier for early log filtering

Status: Accepted
Date: 2026-07-11

## Context

The platform runs a single gateway Collector: apps push OTLP straight to it, and
it is the only thing that talks to a backend (ADR 002 single ingress, ADR 009
gateway as a Deployment). This step demonstrates a common pattern for cutting log
noise: filter unwanted logs early, before they load the central gateway, so noise
does not eat gateway capacity or wash out important logs in short-retention
storage.

The goal splits into two questions: how to filter, and where.

**How.** The OTel Collector `filter` processor drops records by OTTL conditions
(severity, body content, attributes, resource, scope). This is far better than
the blunt "non-JSON, so drop it" rule, which uses format as a proxy for
importance and throws away useful logs (system components, panics, stack traces
that are not JSON). The guardrail here: filter by severity and content, and gate
every drop below WARN so errors are never swallowed.

**Where.** Filtering can run on the gateway (a `filter` processor there) or on a
node-local agent in front of the gateway. On the gateway, the gateway still has to
receive and parse every record to decide what to drop, so it only saves downstream
storage, not its own ingest load. On a node-local agent, the dropped volume never
crosses the network to the gateway and never costs gateway CPU. So a node-local
agent is the right place when the goal is to offload the gateway from noise.

A node-local agent means a second Collector as a DaemonSet (one pod per node). It
must NOT replace the gateway: the gateway keeps the cluster-singleton work
(`span_metrics` aggregation, the `k8s_cluster` watcher) and stays the single
egress. ADR 009 already documents this exact revisit path: "A DaemonSet agent tier
is added in front of the gateway, it does not replace it." This step realizes it.

Honest scope: at this lab's volume the gateway is never stressed, so this is a
**demonstration of the pattern**, not a capacity need.

## Decision

Add an opt-in node-local agent tier, off by default.

- **A second Collector release** (`otel-agent`), same `opentelemetry-collector`
  chart, `mode: daemonset`, its own Argo Application `collector-agent`. The
  gateway is unchanged.
- **The agent filters logs, nothing else.** Its pipeline is
  `otlp -> memory_limiter, filter, batch -> otlp` to the gateway. It has no
  `span_metrics`, no `k8s_cluster`, no cluster RBAC. Only the sample app's OTLP
  **logs** are routed to it (a per-signal `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` on
  the app Deployment); traces and metrics still go straight to the gateway.
- **The filter drops by several dimensions** to show the OTTL vocabulary: DEBUG/
  TRACE by severity, health/probe chatter by body match, and a commented
  by-source example. Every condition is gated below WARN, so errors always pass.
- **Opt-in.** The tier exists only while the `collector-agent` Application file is
  present and the app's log endpoint points at it. Remove either and the app
  falls back to the single-gateway topology (Topology A). This is Topology B.

Single-node simplification: apps reach the agent through a normal ClusterIP
Service (`otel-agent.observability`). On one k3d node there is nothing to pin, so a
Service is equivalent to node-local. On a real multi-node cluster you would pin
each app to its own node's agent instead (host IP plus a `hostPort` on the agent,
or the OTel Operator's node-local injection), so the drop happens on the same node
the app runs on. That node-pinning is deliberately not built here.

## Consequences

- The pattern is demonstrated end to end: a DEBUG line the app emits is dropped by
  the agent and never reaches Loki, while the INFO line passes. The gateway and
  the existing logs path are untouched.
- Stays within the platform thesis. The Collector is still the ingress (ADR 002),
  now in two tiers; logs are still OTLP, no node filelog agent (ADR 012), so the
  agent tails nothing, it only receives and filters OTLP.
- The gateway stays the single egress and keeps the cluster-singleton work
  (ADR 009). The agent is additive, in front, not a replacement.
- **Filtering power is identical on the agent and the gateway** (same OTTL). The
  agent's only advantage is location: dropped volume never reaches the gateway. So
  this is not "only a DaemonSet can filter"; it is "drop it on the node to offload
  the gateway".
- A per-signal logs endpoint on the app is the seam that splits logs from traces/
  metrics. It overrides the operator-injected general endpoint for logs only, and
  the operator sets no per-signal logs endpoint, so it survives injection.
- Cost of the tier: one more Collector to run and reason about, and an extra hop
  for logs (app to agent to gateway). Accepted because it is opt-in and the point
  is the demonstration.
- The single-node Service simplification is a real gap versus production: it does
  not prove node-pinned routing (invisible on one node). The multi-node pattern is
  recorded above so the gap is explicit.
