# ADR 012: App logs come in as OTLP, not scraped from node files

Status: Accepted
Date: 2026-07-08

## Context

Step 3 needs the sample app's logs in Loki. There are two common ways to get
container logs into a pipeline:

1. **Node-level file scraping.** Run a log agent as a DaemonSet (promtail, or a
   second Collector with the `filelog` receiver) on every node. It tails
   `/var/log/pods/*` and ships whatever any container writes to stdout. This is
   what most Loki tutorials show.
2. **App emits OTLP logs.** The app's own logging is exported as OTLP to the
   Collector, the same path its traces already take. With the OTel Operator's
   Python auto-instrumentation this is zero-code: set `OTEL_LOGS_EXPORTER=otlp`
   and `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` on the
   Instrumentation CR, and each `logging` record is exported and stamped with
   the active `trace_id`.

Option 1 fights two decisions already made here. ADR-002 says apps send only to
the Collector and the Collector is the single telemetry ingress; a node
DaemonSet is a second ingress that bypasses it. ADR-009 keeps the Collector as
one central gateway Deployment; file scraping needs a per-node agent, a
different topology. Option 1 also does not carry `trace_id` for free: correlating
a scraped log line to its trace means parsing it back out, and it only works if
the app writes the id into the line.

## Decision

The app emits logs as **OTLP to the Collector** (option 2). No node-level
filelog DaemonSet.

## Consequences

- The single-ingress model (ADR-002) and the single-gateway topology (ADR-009)
  both hold for logs, exactly as they do for traces.
- `trace_id` correlation is automatic: the SDK stamps each record, so the
  logs-to-trace and trace-to-logs pivots work without log parsing.
- The Collector's `resource` processor enriches logs too, so logs carry the same
  `deployment.environment=lab` as traces, from one place.
- The trade: we only capture logs that go through the app's `logging`. Arbitrary
  stdout from the app, or logs from third-party containers (sidecars, system
  pods), are not collected. For this lab, where the point is app-to-backend
  correlation, that is the right scope.
- Revisit trigger: if we later need cluster-wide log capture (system pods, any
  container's stdout), add a filelog collector then, as a deliberate second
  path, and document why it is allowed to bypass the gateway.
