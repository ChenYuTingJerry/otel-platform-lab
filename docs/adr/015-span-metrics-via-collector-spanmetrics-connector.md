# ADR 015: Span metrics come from the Collector connector, not Tempo

Status: Accepted
Date: 2026-07-11

## Context

Step 4 wants RED metrics (request Rate, Error rate, Duration) per service and
operation, without touching the app. These are derived from spans: count them,
count the errors, bucket the durations. Two components in this stack can do that
derivation:

1. **Tempo's metrics-generator.** Tempo can generate span metrics (and service
   graphs) from the traces it receives and remote-write them to a Prometheus
   store. The derivation happens in the trace backend.
2. **The Collector's `spanmetrics` connector.** A connector is an exporter on one
   pipeline and a receiver on another. `spanmetrics` sits as an exporter on the
   traces pipeline and a receiver on the metrics pipeline, so the same span
   stream feeds both Tempo (the trace itself) and, after aggregation, Mimir (the
   RED metrics). The derivation happens in the Collector.

The deciding factor is where derivation lives. ADR-002 makes the Collector the
one place that receives and processes telemetry, and the one thing that talks to
backends. Tempo's metrics-generator would put a second derivation-and-export path
inside a backend: Tempo would remote-write to Mimir directly, so a backend starts
producing and shipping a new signal on its own. That is a second producer outside
the Collector, and it would also mean Tempo speaks remote-write to Mimir while
everything else is OTLP (against ADR-014).

The `spanmetrics` connector keeps it all in the Collector. One span stream in,
two signals out through the pipelines we already run. Note the component id in the
`otel/opentelemetry-collector-k8s` distro is `span_metrics` (snake_case), not the
upstream `spanmetrics`.

## Decision

Derive span metrics with the Collector's `span_metrics` connector, wired as an
exporter on the traces pipeline and a receiver on the metrics pipeline. Do not
enable Tempo's metrics-generator.

Keep the dimensions low-cardinality on purpose. On top of the connector defaults
(`service.name`, `span.name`, `span.kind`, `status.code`), add only
`http.method`, `http.status_code`, and `http.route`. These are the **legacy**
HTTP semconv keys, which is what the injected Python auto-instrumentation actually
emits today (verified on a real span); the newer `http.request.method` /
`http.response.status_code` are not present, so naming those would produce empty
labels. `http.route` is the route template (`/rolldice`), not the raw path. Raw
paths and per-request ids stay out of metric labels; they belong in traces.

## Consequences

- **The Collector stays the single place that derives metrics.** No backend
  produces or ships a signal on its own, so ADR-002 holds, and everything to
  Mimir is OTLP (ADR-014).
- **No app change for RED metrics.** The same auto-instrumentation that produces
  traces produces these metrics for free; the app only adds its one direct
  counter (the other metrics path).
- **Cardinality is a deliberate choice, not a default.** Every added dimension
  and every histogram bucket multiplies series. We keep a short bucket list and
  low-cardinality dimensions; a raw-path or per-id dimension would blow the series
  count up and is refused on purpose.
- **Dimension keys are pinned to what the SDK emits.** If the auto-instrumentation
  moves to the new HTTP semconv, the `http.method` / `http.status_code` dimensions
  go empty and must be renamed to `http.request.method` /
  `http.response.status_code`. That is a known, documented follow-up, not a
  surprise.
- **Metric names.** With the connector namespace `traces.span.metrics`, the series
  arrive in Mimir as `traces_span_metrics_calls_total` and
  `traces_span_metrics_duration_milliseconds_*`.
- **Revisit trigger.** If we later want service graphs, or span metrics even when
  the Collector is bypassed, revisit Tempo's metrics-generator then, as a
  deliberate second path, and record why it is allowed to derive and export on its
  own.
