# ADR 001: Use the LGTM stack (Loki, Grafana, Tempo, Mimir)

Status: Accepted
Date: 2026-07-05

## Context

We need an observability backend for a Kubernetes-based lab that will later
grow into a real platform. The three signals we care about are logs, metrics,
and traces. Grafana Labs provides one component per signal, all sharing the
same query and dashboard layer.

Alternatives considered:
- Prometheus + Jaeger + Elasticsearch/Kibana. Mature but each piece has its
  own storage model, query language, and operational shape. Cross-signal work
  (like jumping from a metric to a related trace) is harder to wire.
- Vendor SaaS (Datadog, Honeycomb, New Relic). Fastest to reach value, but
  the goal of this lab is to learn the pieces, not to hand them off.

## Decision

Use LGTM: Loki for logs, Tempo for traces, Mimir for metrics, Grafana for
visualisation. All four are open source and use similar object storage
backends (S3-compatible), which keeps the ops story consistent.

## Consequences

- We only need to learn one dashboarding tool (Grafana).
- Cross-signal navigation (trace_id in a log line jumps to the trace view) is
  a first-class feature of the stack.
- Storage is object-storage-shaped from the start. For local lab we use
  in-cluster options or the components' built-in single-node modes.
- We take a dependency on the Grafana Labs ecosystem. This is acceptable for
  a learning lab and reflects a mainstream production choice.
