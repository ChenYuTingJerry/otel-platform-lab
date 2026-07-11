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

## Metrics (Step 4, done)

Metrics land in Mimir through two paths, both via the Collector. Metrics stay
aggregate and low-cardinality; the per-request detail belongs in traces and
logs, not in metric labels.

How Mimir plugs into the rest of the lab:

```
  demo ns
  ┌─────────────────────────┐
  │ sample-api              │
  │  app + injected OTel SDK │  OTLP: traces + logs + metrics
  └────────────┬────────────┘
               │
  observability ns
               v
  ┌────────────────────────────────────┐
  │ OTel Collector (single ingress)     │
  │                                      │
  │  traces  ──────────────────────────┼──> Tempo
  │     └── spanmetrics connector ──┐   │
  │  logs    ───────────────────────┼──┼──> Loki
  │  metrics <──────────────────────┘   │
  │   (otlp from the app + spanmetrics) ┼──> Mimir  (OTLP /otlp/v1/metrics)
  └────────────────────────────────────┘         │
                                                  v
        ┌──────────────────── mimir-gateway ─────────────────────┐
        │  distributor -> Kafka -> ingester -> MinIO (blocks)     │
        │  querier / store-gateway / compactor                    │
        └─────────────────────────────────────────────────────────┘
                            ^
   Grafana ──── query /prometheus (Mimir datasource) ──┘
```

The Mimir internals (distributor, Kafka, ingester, object store, query path) and
why it runs in the ingest-storage architecture are in ADR-013. Note the two
"gateway" layers: the Collector is a gateway-topology collector (ADR-009), and
`mimir-gateway` is Mimir's own nginx front door. They are different things.

### Path 1: span metrics (no app change)

The Collector's `spanmetrics` connector reads the trace pipeline and emits RED
metrics (request rate, error rate, duration) per service and operation. It is an
exporter on the traces pipeline and a receiver on the metrics pipeline, so one
span stream feeds both Tempo (the trace) and Mimir (the aggregate). No app-side
change: the same auto-instrumentation that produces traces produces these
metrics for free. Dimensions stay low-cardinality on purpose (method, status
code, route template), never raw paths or per-request ids.

### Path 2: direct metrics (from the app SDK)

The injected SDK also exports the app's own metrics as OTLP: the
auto-instrumentation HTTP server metrics, plus one explicit custom metric the app
declares (a `dice.rolls` counter). This is why `OTEL_METRICS_EXPORTER` went back
to `otlp` in Step 4, after being `none` in Step 3 to stop 404s before a metrics
pipeline existed. It is a small, deliberate break from the app's "zero OTel code"
rule, kept low-cardinality (a bounded label at most).

### Ingestion and cardinality

Both paths leave the Collector as OTLP and hit `mimir-gateway` at
`/otlp/v1/metrics`, the same OTLP story the logs path uses for Loki. The
Collector's `resource` processor stamps `deployment.environment=lab` on metrics
too, so all three signals carry it.

One Mimir detail to know: under OTLP, resource attributes are not turned into
metric labels by default. Only `service.name` (-> `job`) and `service.instance.id`
(-> `instance`) are mapped; everything else lands in a `target_info` series that
you join against. To make `deployment.environment` a real label like it is on
traces and logs, we promote it with Mimir's `promote_otel_resource_attributes`.
The alternative, a `target_info` join, is left as a note in ADR-014.
