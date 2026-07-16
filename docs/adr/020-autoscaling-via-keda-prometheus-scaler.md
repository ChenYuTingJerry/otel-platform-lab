# ADR 020: Autoscale the app with KEDA's Prometheus scaler

Status: Accepted
Date: 2026-07-15

## Context

Every signal pipeline is built (traces, logs, metrics, alerting, platform
health), but nothing acts on those signals yet. This step adds the first action:
scale the sample app on how much traffic it gets. In the platform-boundary frame
(docs/scenarios.md §9) autoscaling is a BOUNDARY case. It does not produce, move,
or store telemetry; it consumes telemetry to act. So the question is not "should
the platform observe scaling", it is "how does a consumer read the signal the
platform already produces, and who then owns the replica count".

Three sub-questions had to be settled.

**What to scale, and on what signal.** We scale sample-api on request rate, not
the Collector on ingest volume. Scaling the Collector would drag in tail sampling
and a two-tier collector topology (spans of one trace must reach the same
instance), which is a much larger piece of work. Out of scope here. The signal is
the span-metrics request rate that Step 4 already produces and Step 5 already
alerts on. We scale on LOAD, never on error ratio: errors from a bug are not
fixed by adding replicas (error -> alert and fix, load -> scale). KEDA and
Alertmanager are parallel consumers of the same metric; there is no alert -> KEDA
wire, and we do not want one.

**Which scaler.** KEDA is the autoscaler either way (it reads an external metric
and drives a standard HPA). The real fork was the KEDA core Prometheus scaler
versus the KEDA HTTP Add-on. We first leaned to the HTTP Add-on for one reason:
its interceptor and scaler were said to export their own OTLP telemetry into the
Collector, so the autoscaling layer would itself be observed. Checking the actual
chart (keda-add-ons-http 0.15.0) killed that reason. The interceptor deployment
template sets no OTEL environment at all; its request metrics
(`interceptor_request_*`) come out of a Prometheus `/metrics` endpoint only. The
lab has no scrape mechanism, so those metrics could not be collected here. Only
the scaler can push OTLP, and only its scaling-decision metrics, not the request
RED. The observability loop does not exist in this version, so the reason to pay
for the HTTP Add-on was gone.

**Who owns the replica count.** The Deployment used to pin `replicas: 1` in git,
and Argo runs with `selfHeal: true`. An autoscaler and Argo would then fight over
`/spec/replicas`: the autoscaler raises it, Argo resets it on the next sync. This
is not a KEDA quirk; a plain HPA hits it too. A mutable field can have only one
owner.

## Decision

Add KEDA (core chart) and scale sample-api with a Prometheus scaler that reads
Mimir. No HTTP Add-on.

- **KEDA core** (`kedacore/keda` 2.20.1) as its own Argo Application in namespace
  `keda`, sync-wave -1 so its CRDs (`ScaledObject`, ...) exist before the sample
  app applies one. It runs three pods (operator, metrics apiserver, admission
  webhooks) and creates a standard HPA under the hood.
- **A ScaledObject ships with the sample app** (wave 4). One `prometheus`
  trigger, `serverAddress` the Mimir query front-end
  (`http://mimir-gateway.observability.svc.cluster.local/prometheus`, anonymous,
  no tenant header, the same door the Grafana datasource uses), query
  `sum(rate(traces_span_metrics_calls_total{service_name="sample-api"}[5m]))`.
  The window is 5m because the span metric lands in Mimir only about every 2
  minutes (the connector flush cadence), so a shorter window has too few samples
  to compute a rate. This was found live: under load, `rate[1m]` and `rate[2m]`
  returned empty, `rate[3m]` and up worked. 5m matches the Step 5 recording rule,
  which is coarse for the same reason. The match is on `service_name`, not `job`,
  because Mimir sets `job="demo/sample-api"`.
- **Floor of 1, ceiling of 5, no scale-to-zero.** `minReplicaCount: 1`. Target
  ~5 calls/s per replica (`threshold: "5"`), so desired = ceil(rate / 5).
- **The Deployment no longer sets `replicas`.** With the field absent from git,
  Argo has nothing to diff on `/spec/replicas`, so `selfHeal` does not fight the
  HPA. Argo owns the scaling *policy* (the ScaledObject, in git); the HPA owns
  the scaling *action* (the replica count, at runtime). This split is the point.

## Consequences

- The first consumer of platform telemetry that acts on it is now in place, and
  the field-ownership split under GitOps is explicit: policy in git, count at
  runtime. This is the reusable lesson, bigger than "we installed KEDA".
- **The Prometheus scaler lags both ways.** The span metric lands in Mimir only
  ~every 2 min, and the rate() window is 5m. Scale-up trails a traffic rise by
  roughly 3 to 4 minutes (the window needs a couple of samples above the
  threshold). Scale-down is slower still: after traffic stops the rate stays high
  until the 5m window clears, so it takes ~5 minutes to fall below the threshold,
  then the HPA's 30s stabilization, before it returns to 1 (measured live on the
  Argo path). Fine for a floor-of-1 service that absorbs bursts; too slow to react
  to spiky, latency-critical traffic. The `verify_step7` check waits accordingly,
  which makes it the slowest step to verify.
- **No scale-to-zero, and not by accident.** A scaled-to-zero app produces no
  span metrics, so the trigger would have nothing to read and could never
  re-activate (a chicken-and-egg), and requests during a cold start would be
  dropped because nothing holds them. Safe scale-from-zero needs a signal source
  in the request path that can hold the request, which is exactly what the HTTP
  Add-on interceptor does and the Prometheus scaler cannot.
- **Revisit trigger.** Move to the KEDA HTTP Add-on when the lab needs real-time
  scaling or safe scale-to-zero. That brings its own costs: a proxy in the data
  path (all traffic must route through the interceptor, which must be HA), and,
  until the lab has a scrape mechanism, the interceptor's own request metrics
  stay uncollected (they are Prometheus-only in 0.15.0). Also re-tune the
  threshold and window once real traffic shapes are known, rather than the demo
  values here.
- **A note on an alert that looks related but is not.** `AppNoRequests` (Step 5,
  `absent(traces_span_metrics_calls_total{...})`) fires on "no traffic" whatever
  the pod count, because `absent()` keys on the series, not the pod. It is not a
  scale-to-zero conflict, and it already fires when an idle app sits at one
  replica. It is a property of that alert (it assumes a service with steady
  baseline traffic) and is left alone here.
- Cost of the choice: three more pods, and a scaling signal that trails reality
  by a minute or two. Accepted for a non-intrusive setup that reuses the existing
  span metrics and leaves the data path untouched.
