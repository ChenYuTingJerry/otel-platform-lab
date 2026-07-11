# ADR 014: Metrics reach Mimir as OTLP push, not Prometheus remote-write

Status: Accepted
Date: 2026-07-11

## Context

Step 4 sends metrics from the Collector to Mimir. Mimir's distributor accepts
writes two ways, and both are on by default:

1. **Prometheus remote-write** at `/api/v1/push`. The Collector would carry the
   `prometheusremotewrite` exporter, translate OTLP to the Prometheus wire format
   itself, and push that. This is the older, more common path in Prometheus-land.
2. **Native OTLP** at `/otlp/v1/metrics` (on since Mimir 2.12, no flag). The
   Collector keeps the data as OTLP end to end and Mimir does the translation on
   ingest.

Two things push toward OTLP here. First, the lab already sends traces and logs
as OTLP through the one Collector (ADR-002, ADR-012); metrics as OTLP keeps that
one story instead of adding a second wire format on the way out. Second, the
`otel/opentelemetry-collector-k8s` distro we run (ADR-009) ships `otlphttp` but
**not** `prometheusremotewrite`. Remote-write would force a contrib image just
for the export step. OTLP needs no image change.

There is one real cost to OTLP, and it is about labels. Under OTLP ingest, Mimir
does not turn resource attributes into metric labels by default. It maps only
`service.name` (plus `service.namespace`) to `job` and `service.instance.id` to
`instance`. Every other resource attribute lands in a companion `target_info`
series that you join against at query time. So `deployment.environment=lab`,
which the Collector's `resource` processor stamps on every signal, would not be a
real label on the metrics the way it already is on traces and logs.

## Decision

The Collector pushes **OTLP** to `mimir-gateway` at `/otlp/v1/metrics` (the
`otlp_http/mimir` exporter, base URL `.../otlp`, the exporter appends
`/v1/metrics`). No `prometheusremotewrite`, no contrib image.

To keep the cross-signal `deployment.environment=lab` label consistent with
traces and logs, promote that one attribute to a real label with Mimir's
`limits.promote_otel_resource_attributes: "deployment.environment"` (set in
`k8s/manifests/mimir/values.yaml`). This takes a comma-separated string, not a
YAML list.

## Consequences

- **No image change.** The k8s distro already carries `otlphttp`. Remote-write
  would have needed contrib, for no gain here.
- **One protocol out of the Collector.** Metrics leave as OTLP, the same as
  traces and logs, so the "everything is OTLP through one Collector" story holds
  for all three signals.
- **`job` and `instance` come for free.** The default `service.name` and
  `service.instance.id` mapping is enough to tell series apart per service and
  per pod, which is all the lab queries need.
- **Prometheus-style suffixes are turned on.** OTLP translation adds the
  `_total` counter suffix and the unit only when
  `limits.otel_metric_suffixes_enabled` is set, which is off in Mimir by default.
  We turn it on, so the counters arrive as `dice_rolls_total` and
  `traces_span_metrics_calls_total` and the histogram as
  `traces_span_metrics_duration_milliseconds_*`, matching the OpenMetrics
  convention and Grafana's shipped RED dashboards. Left off, the same series land
  without the suffixes (`dice_rolls`, `traces_span_metrics_calls`), which reads
  as non-idiomatic to any Prometheus user.
- **Resource attributes need promotion to become labels.** We promote
  `deployment.environment`. The alternative, left on the table, is to not promote
  and join `target_info` at query time
  (`... * on (job, instance) group_left(deployment_environment) target_info`).
  The join keeps Mimir on defaults but makes every query longer and is easy to
  forget, so we promote instead.
- **`promote_otel_resource_attributes` is still experimental.** If it misbehaves
  on a chart bump, dropping the promotion falls back to the `target_info` join,
  which is documented above. Low risk: it is one line and one attribute.
- **Revisit trigger.** If a future need is genuinely Prometheus-remote-write
  shaped (for example scraping existing Prometheus exporters), add that path then
  with a contrib image, as a deliberate second exporter, and record why.
