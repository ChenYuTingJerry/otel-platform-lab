# Signal routing strategy

Status: Stub. Filled in during Step 2.

This document will describe how the three signals split responsibility:

- Logs carry high-cardinality context. Structured, keyed by request id and
  trace id.
- Metrics stay aggregate. Low cardinality, cheap to store, cheap to query
  at scale.
- Traces cover latency and per-request performance. High cardinality lives
  here, sampled if needed.

Cross-signal navigation:
- trace_id in a log line jumps to the trace view in Grafana.
- Span metrics (derived from traces via the Collector) feed Mimir so we can
  chart RED metrics without app-side changes.

Content will land in Step 2 once the Collector is in place and we have real
signals to route.
