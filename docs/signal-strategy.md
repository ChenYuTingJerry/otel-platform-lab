# Signal routing strategy

How the three signals split responsibility, and how they connect.

- Logs carry high-cardinality context. Structured, keyed by request id and
  trace id.
- Metrics stay aggregate. Low cardinality, cheap to store, cheap to query
  at scale.
- Traces cover latency and per-request performance. High cardinality lives
  here, sampled if needed.

Cross-signal navigation:
- trace_id in a log line jumps to the trace view in Grafana.
- a trace span jumps to that request's logs.
- Span metrics (derived from traces via the Collector) feed Mimir so we can
  chart RED metrics without app-side changes.

## Logs (Step 3, done)

The app does not talk to Loki. It emits its logs as OTLP to the Collector, the
same path its traces take, and the Collector exports them to Loki. This keeps
the single-ingress model (ADR-002) and avoids a node-level log agent (ADR-012).
Because the OTel SDK is in the process, every log record is stamped with the
active `trace_id` and `span_id` for free.

Cardinality split in Loki, on purpose:
- Index labels stay low-cardinality: `service_name`, `deployment_environment`,
  and the k8s identity labels. These are cheap to select on.
- The high-cardinality context (`trace_id`, `span_id`, code location, severity)
  rides as structured metadata, not as index labels. It is queryable with a
  `| trace_id != ""` style filter, but it does not explode the number of
  streams.

This is what "logs carry high-cardinality context" means here: the detail lives
in the log, keyed to the exact request, without turning every request into its
own Loki stream.

Correlation is wired both ways in Grafana:
- Loki datasource `derivedFields`: a `trace_id` on a log line links to the Tempo
  datasource, so a log jumps to its trace.
- Tempo datasource `tracesToLogsV2`: a span links back to Loki, filtered by
  `service.name` and the span's `trace_id`, so a trace jumps to its logs.

## Metrics (Step 4, not built yet)

Metrics land in Mimir. Two paths are planned: span metrics derived from traces
by the Collector (RED metrics with no app-side change), and a direct metrics
path. Metrics stay aggregate and low-cardinality; the per-request detail belongs
in traces and logs, not in metric labels. This section fills in during Step 4.
