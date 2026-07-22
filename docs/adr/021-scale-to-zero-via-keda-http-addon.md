# ADR 021: Safe scale-to-zero with the KEDA HTTP Add-on

Status: Accepted
Date: 2026-07-19

## Context

ADR 020 scaled sample-api on request rate with KEDA's core Prometheus scaler and
kept a floor of one replica. It wrote down why that scaler cannot go to zero: a
scaled-to-zero app produces no span metrics, so the trigger has nothing to read
and can never re-activate (chicken-and-egg), and requests during a cold start get
dropped because nothing in the request path holds them. ADR 020 named its own
revisit trigger: "Move to the KEDA HTTP Add-on when the lab needs real-time
scaling or safe scale-to-zero."

This step executes that trigger. The goal is a backend that truly rests at zero
off-peak and wakes on the first request without dropping it.

Three things had to be settled.

**What scales to zero.** Not sample-api. sample-api's RED alerts, its dashboard,
and the `AppNoRequests` alert all assume a service with baseline traffic sitting
at a floor of one. Forcing it to zero would make `AppNoRequests` fire whenever it
rested, and would replace the Step 7 scaler that is already verified. So Step 8
adds a **new backend, offpeak-api**, and leaves Step 7 untouched. offpeak-api
reuses the sample-api:0.1.0 image (same FastAPI service), so there is no new app
code, only a different scaling policy. The two patterns now sit side by side:
sample-api scales 1 -> N on a reactive metric (Step 7), offpeak-api scales 0 -> 1
on a request-path hold (Step 8). The contrast is the point.

**How the wake works.** The HTTP Add-on puts an interceptor proxy in the request
path. When offpeak-api is at zero, a request goes to the interceptor, which holds
it, tells KEDA to scale 0 -> 1 through its own external scaler, waits for the pod
to become Ready, and then forwards the held request. The wake is request-driven
and synchronous, so the first request is served, not dropped. This is the one
capability the Prometheus scaler structurally lacks, and it is worth the cost of a
proxy in the data path only when a service really needs to rest at zero.

**Whether the autoscaling layer is observed.** This was the reason ADR 020 gave
for *not* taking the Add-on. In chart `keda-add-ons-http` 0.15.0 the interceptor
Deployment sets no OTEL environment, and its request metrics
(`interceptor_request_count` and friends) come out of a Prometheus `/metrics`
endpoint only, which this all-OTLP-push lab has no way to scrape. That reading of
the chart still holds. But the interceptor binary does honour the standard
`OTEL_*` environment; the chart just does not wire it by default. So we inject it
through `interceptor.extraEnvs`, enabling the interceptor's native OTLP metric
export and pointing it at the Collector's OTLP HTTP receiver (4318, already open,
the same port the apps push to). The interceptor then pushes
`interceptor.request.count` / `.concurrency` / `.duration` into the Collector and
on to Mimir. The self-observability loop ADR 020 could not close is now closed,
and no scrape mechanism is added: the lab stays pure OTLP push.

The port matters: enabling `OTEL_EXPORTER_OTLP_METRICS_ENABLED` turns on the
interceptor's *HTTP* OTLP exporter (it POSTs to `<endpoint>/v1/metrics`), so the
endpoint must be the Collector's HTTP port 4318. Pointing it at the gRPC port
4317 fails at runtime with "malformed HTTP response" (the gRPC server replies in
HTTP/2 framing to an HTTP/1.x client) and no metric ever lands. This was found
during live verification, not from the chart.

## Decision

Add the KEDA HTTP Add-on and use it to scale a new backend, offpeak-api, to zero.
Keep sample-api on the Prometheus scaler.

- **HTTP Add-on** (`kedacore/keda-add-ons-http` 0.15.0) as its own Argo
  Application in namespace `keda`, sync-wave -1, so its `HTTPScaledObject` CRD
  exists before the offpeak app (wave 4) applies one. It registers as an external
  scaler with the KEDA core operator already running from Step 7.
- **Interceptor self-observation over OTLP.** `interceptor.extraEnvs` sets
  `OTEL_EXPORTER_OTLP_METRICS_ENABLED=true` and `OTEL_EXPORTER_OTLP_ENDPOINT` to
  the Collector's HTTP receiver (port 4318). The interceptor's request metrics
  reach Mimir the same way every other signal does.
- **offpeak-api** reuses the sample-api image, in namespace `demo`,
  auto-instrumented by the operator, with `OTEL_SERVICE_NAME=offpeak-api` so its
  telemetry is a distinct `service_name`. The Deployment sets no `replicas` (same
  field-ownership rule as ADR 020: policy in git, count at runtime).
- **An HTTPScaledObject ships with the offpeak app** (wave 4): `replicas.min: 0`,
  `max: 3`, `scaledownPeriod: 60`, a low request-rate target. It defines the host
  (`offpeak-api`) the interceptor routes on.
- **Interceptor replicas trimmed to one** for the single-node lab (chart default
  is three). Production keeps at least two: the interceptor is in the data path,
  so losing the only one drops all traffic to the scaled services.

## Consequences

- **The first service that truly rests at zero.** Off-peak, offpeak-api runs no
  pod at all. The wake from zero is seconds (pod schedule + SDK init + readiness),
  far faster than Step 7's 3-4 minute reactive lag, and, crucially, the waking
  request is held and served rather than dropped.
- **A proxy is now in the data path, on purpose.** Callers reach offpeak-api only
  through the interceptor proxy
  (`keda-add-ons-http-interceptor-proxy.keda.svc`, port 8080) with a matching
  `Host: offpeak-api` header. Hitting the Service directly bypasses the wake and
  fails while at zero. This is the cost ADR 020 flagged, accepted here because the
  service needs to rest at zero. In production the interceptor must be highly
  available; the lab runs one replica only to stay light.
- **The autoscaling layer is now observed.** The interceptor's RED metrics land
  in Mimir over OTLP, so the same platform that watches the apps now watches the
  thing that scales them. This redeems the reason ADR 020 rejected the Add-on; the
  difference is a two-line `extraEnvs` block, not a new scrape path.
- **Two autoscaling patterns coexist by design.** Prometheus scaler for a
  baseline-traffic service that bursts (sample-api), HTTP Add-on for a service
  that idles to zero (offpeak-api). The reusable lesson is when to pay for a
  request-path proxy and when a reactive metric is enough.
- **Relation to ADR 020.** This ADR does not supersede ADR 020; it extends it.
  ADR 020's decision for sample-api stands. Step 8 acts on ADR 020's stated
  revisit trigger for a different service.
- **Left for later.** Re-tuning `scaledownPeriod` and the request-rate target to
  a real off-peak traffic shape (the demo values thrash quickly on purpose), and
  an alert or dashboard panel on the interceptor metrics now that they are
  collected.
