# ADR 002: OTel Collector is the only telemetry ingress

Status: Accepted
Date: 2026-07-05

## Context

Applications can send telemetry directly to each backend (Loki for logs,
Tempo for traces, Mimir for metrics) using OTLP or vendor-specific SDKs.
Alternatively they can send to an OpenTelemetry Collector which then routes
to the backends.

## Decision

Applications only ever send OTLP to the OTel Collector. The Collector is the
one place that knows about backend endpoints, retries, batching, sampling,
and enrichment.

## Consequences

- Backends can be swapped (Tempo to Jaeger, Mimir to Prometheus) without
  touching any app.
- Batching, retries, and sampling live in one place, not scattered across
  services in every language.
- Cross-cutting enrichment (adding cluster name, region, k8s attributes) is
  applied uniformly through processors.
- The Collector becomes a critical path component. A Collector outage stops
  telemetry ingress. We accept this risk in exchange for the routing and
  policy centralisation.
- Auto-instrumentation is done via the OpenTelemetry Operator (zero-code
  injection) rather than embedding SDKs manually. Apps get a
  sidecar/init-container that configures OTLP export to the Collector.
