# Scenarios

The other docs in this repo are indexed the way the work happened. `README.md`
goes by build order (Step 0 to Step 6b). `docs/adr/` goes by decision number. Both
are useful when you are building.

Neither is useful when a problem shows up. A problem does not arrive as "Step 4b"
or "ADR-014". It arrives as *"our metrics bill tripled and nobody knows why"*, or
*"Argo says everything is green but we stopped getting traces"*. This document is
the third index: the same material, sorted by the shape of the problem.

Each scenario names a problem that keeps coming back in platform work, the real
options, what this lab picked, what that cost, and the detail that bit us. The
lab is only where the answer was built and checked. The reasoning is meant to
travel to other systems.

Nine scenarios:

1. [Every app knows every backend](#1-every-app-knows-every-backend)
2. [High-cardinality data lands in the wrong signal](#2-high-cardinality-data-lands-in-the-wrong-signal)
3. [You need RED metrics but you cannot change 40 apps](#3-you-need-red-metrics-but-you-cannot-change-40-apps)
4. [One protocol everywhere, and the labels you silently lose](#4-one-protocol-everywhere-and-the-labels-you-silently-lose)
5. [Alert rules you cannot test, that die with the dashboard](#5-alert-rules-you-cannot-test-that-die-with-the-dashboard)
6. [Nothing watches the monitoring system](#6-nothing-watches-the-monitoring-system)
7. [Reaching for a DaemonSet you do not need](#7-reaching-for-a-daemonset-you-do-not-need)
8. [Argo says Healthy and the system is broken](#8-argo-says-healthy-and-the-system-is-broken)
9. [Deciding what not to build](#9-deciding-what-not-to-build)

---

## 1. Every app knows every backend

**The problem.** You have N apps and M telemetry backends. Every app holds the
address of every backend it sends to. Swapping Jaeger for Tempo means a config
change and a redeploy in all N apps. Sampling policy, batching, and enrichment are
spread across N codebases, so there is no single place to change them and no way to
audit what is actually in force.

**Where it shows up.** Any platform with more than a couple of teams. It gets loud
during a vendor migration (moving off a SaaS, or between open source backends), and
during a cost push, when someone asks you to sample 90% of traces away and you find
there is no one place to do it.

**The options.**

- Apps talk to backends directly. Simplest to start, worst to change.
- A sidecar Collector per app. Isolated blast radius, scales to zero with the app,
  but you pay the memory cost once per pod and the policy still lives in N places
  unless you template it.
- A node-local agent (DaemonSet). One per node instead of one per pod.
- A central gateway Collector. One deployment, one place for policy.

**What this lab does.** The Collector is the only telemetry ingress, and it runs as
a central gateway Deployment ([ADR 002](adr/002-collector-as-single-ingress.md),
[ADR 009](adr/009-collector-topology-gateway-deployment.md),
`k8s/manifests/collector/values.yaml`). Applications only ever speak OTLP to the
Collector. They do not know that Tempo, Loki, or Mimir exist. The Collector is the
one component that knows about backends, retries, batching, and enrichment.

You can see the payoff in one line of config: the `resource` processor stamps
`deployment.environment=lab` onto every signal, in one place, and all three signals
correlate on it. Doing that per app would mean N changes.

**What it costs.** The Collector becomes a shared critical path. If it is down,
telemetry ingress stops, for everything, at once. This lab runs a single replica
and does not mitigate that. The honest position is that it is accepted at lab
scale, and written down as accepted rather than quietly ignored. In production the
answers are replicas behind a Service, a persistent queue on the exporter so a
backend outage does not become data loss, and enough headroom that a restart does
not drop a batch.

The gateway also adds one network hop, and it is the piece you now have to size,
monitor, and roll carefully.

**Takeaway.** Centralising the ingress buys backend portability and one place for
policy. It also buys a new single point of failure. Both are real, and you should
say both out loud. The mistake is not choosing the gateway. The mistake is choosing
it and then talking about it as if it were free.

---

## 2. High-cardinality data lands in the wrong signal

**The problem.** Someone adds `user_id` as a metric label. Or `trace_id` as a Loki
index label. The series count or the stream count explodes, queries slow to a
crawl, and the bill bends upward. Nobody notices at the moment of the commit,
because at low traffic it looks fine.

**Where it shows up.** Cost reviews. Incidents where the metrics backend falls over
under its own write load. Any conversation that starts "can we just add one more
label".

**The options.** The framing that fails is treating cardinality as a per-metric
accident to clean up later. The framing that works is deciding, up front, which
signal is *allowed* to be high-cardinality, and pushing the detail there.

**What this lab does.** An explicit split, written down in
[`signal-strategy.md`](signal-strategy.md):

- **Logs carry the high-cardinality context.** `trace_id`, `span_id`, code
  location, severity. But they ride as Loki **structured metadata**, not as index
  labels. They are queryable with a filter like `| trace_id != ""`, and they do not
  turn every request into its own Loki stream. Index labels stay low-cardinality on
  purpose: `service_name`, `deployment_environment`, and the Kubernetes identity
  labels.
- **Metrics stay aggregate.** Low cardinality, cheap to store, cheap to query.
- **Traces hold the per-request detail**, and are sampled if volume demands it.

The rule is enforced where it is easy to break. The `span_metrics` connector emits
RED metrics with dimensions limited to `http.method`, `http.status_code`, and
`http.route` (the route *template*, not the raw path). Raw paths and per-request
ids are refused. Even the histogram bucket list is kept short on purpose, because
the number of buckets is a cardinality knob too, and it is one people forget.

**What it costs.** You cannot slice a metric by user, or by raw URL. That question
now has to be answered from traces or logs, which is slower and a different query
language. That is a real ergonomic loss and users will ask for the label back.

**Takeaway.** Cardinality is a design decision you make per signal, not a default
you inherit from whatever the SDK emits. Decide which signal is allowed to be
expensive, put the detail there, and hold the line in the places that quietly leak:
metric labels, log index labels, and histogram buckets.

---

## 3. You need RED metrics but you cannot change 40 apps

**The problem.** You want request rate, error rate, and duration for every service.
You cannot realistically ask 40 teams to add instrumentation code, agree on metric
names, and ship it.

**Where it shows up.** Every "we need a service dashboard" and "we need SLOs"
project, in an org where the platform team cannot merge into product repos.

**The options.**

- **App-side SDK metrics.** Accurate, but needs code in every app, and the naming
  drifts across teams.
- **Derive in the backend.** Tempo has a metrics-generator that turns spans into
  RED metrics.
- **Derive in the Collector.** A connector reads the trace pipeline and writes to
  the metrics pipeline.

**What this lab does.** The `span_metrics` connector
([ADR 015](adr/015-span-metrics-via-collector-spanmetrics-connector.md)). It is
configured as an exporter on the traces pipeline and a receiver on the metrics
pipeline, so a single span stream feeds both Tempo (the trace itself) and Mimir
(the aggregate). The apps change nothing. The same auto-instrumentation that
already produces traces produces the RED metrics for free.

**Why not the Tempo generator.** It would put a second derivation-and-export path
inside a backend, and it would make Tempo speak Prometheus remote-write to Mimir.
That breaks the model in Scenario 1, where the Collector is the only component that
talks to backends. Keeping derivation in the Collector keeps one place that owns
policy, and keeps Tempo swappable.

**The gotcha.** The connector's extra dimensions had to use the **legacy** HTTP
semantic-convention keys (`http.method`, `http.status_code`, `http.route`), because
that is what the injected Python auto-instrumentation actually emits today. The
new-style keys (`http.request.method` and friends) would have produced labels that
are silently **empty**, not missing. You would get a dashboard full of series with
a blank method label and no error anywhere.

This was caught by reading a real span off the wire, not by trusting the
documentation.

**Takeaway.** Derive telemetry where the policy lives, which is the Collector, not
a backend. And before you build alerts on an attribute, confirm the attribute key
against a real payload. A wrong key does not fail loudly. It gives you an empty
string.

---

## 4. One protocol everywhere, and the labels you silently lose

**The problem.** Every backend has a preferred way in. Prometheus wants
remote-write. Loki has its own push API. Node logs want a filelog agent. Kubernetes
state wants kube-state-metrics plus a scrape. Do you teach your pipeline all four,
or normalise on one wire format?

**Where it shows up.** Whenever you add the second backend. Also whenever your
Collector image has to grow, because supporting one more protocol means switching
from the base distribution to a contrib build.

**What this lab does.** OTLP push, everywhere, out of one Collector:

- Logs go in as OTLP from the app SDK, not scraped off the node by a filelog
  DaemonSet ([ADR 012](adr/012-logs-via-otlp-not-node-filelog.md)).
- Metrics are pushed to Mimir as OTLP, not Prometheus remote-write
  ([ADR 014](adr/014-metrics-via-otlp-push-not-remote-write.md)).
- Kubernetes workload state comes from the `k8s_cluster` receiver, not
  kube-state-metrics plus a scrape path
  ([ADR 018](adr/018-platform-health-via-k8s-cluster-receiver.md)).

The payoff is more concrete than "consistency". The
`otel/opentelemetry-collector-k8s` distribution ships `otlphttp` but does **not**
ship `prometheusremotewrite`. Choosing remote-write would have forced a contrib
image, for one exporter. Staying on OTLP kept the base image.

**The gotcha, and this is the one worth knowing.** Under OTLP, **Mimir does not
turn resource attributes into metric labels.** Only two are mapped:
`service.name` becomes `job`, and `service.instance.id` becomes `instance`.
Everything else is pushed into a separate `target_info` series that you are
expected to join against.

So resource attributes have to be promoted explicitly, with Mimir's
`promote_otel_resource_attributes`. A smoke test showed exactly how bad the failure
is: without promoting the `k8s.*` attributes, **every `k8s_deployment_available`
series collapses into a single unlabeled series**. The metric still exists. The
alert still evaluates. It just cannot tell you *which* Deployment is down, because
the workload identity was never a label.

There is a second, smaller version of the same trap. Mimir needs
`otel_metric_suffixes_enabled` to add the `_total` suffix to counters. Without it,
a rule written as `rate(something_total[5m])` matches nothing at all, and a rule
that matches nothing looks exactly like a rule that is healthy and quiet.

Both settings are in `k8s/manifests/mimir/values.yaml`. Note that
`promote_otel_resource_attributes` takes a comma-separated string, not a YAML list.

**Takeaway.** Protocol translation is never lossless. When you normalise on one
wire format, go and find out what the receiving end drops on the floor, and prove
it with a query rather than assuming. The dangerous losses are the quiet ones: an
empty label, a collapsed series, a rule that silently matches nothing.

---

## 5. Alert rules you cannot test, that die with the dashboard

**The problem.** Alert rules authored in a UI are not reviewable, not testable, and
not portable. And if they are evaluated by the dashboard tool, then restarting the
dashboard tool stops your alerts from firing. A visualisation service being down
should not mean you stop getting paged.

**Where it shows up.** The first time an alert does not fire and nobody can explain
why, because there is no test and no diff to read.

**The options.** Grafana-managed alerting (rules stored and evaluated by Grafana),
or a ruler in the metrics backend itself (Prometheus-format rules, evaluated by
Mimir or Prometheus).

**What this lab does.** Rules live in git in Prometheus format, are unit-tested with
`promtool`, and are evaluated by the **Mimir ruler**. The bundled Alertmanager
routes fired alerts to a webhook sink
([ADR 017](adr/017-metrics-alerting-via-mimir-ruler.md),
`k8s/manifests/mimir/rules/`). Grafana-managed alerting is kept in reserve for
things the ruler cannot do, such as cross-signal rules or alerting on Tempo, which
has no ruler.

`make test-rules` runs `promtool test rules` inside a container, so nothing gets
installed on the host to run the tests.

**The seam worth knowing about.** The Mimir ruler stores its rules in **object
storage**, not in a mounted ConfigMap. So applying the ConfigMap with `kubectl
apply` does not load them. Something still has to push them in. Here that is an
Argo **PostSync hook Job** that runs `mimirtool rules load` (an upsert, so it is
idempotent), with an initContainer that waits for the ruler API to answer first.

This is worth naming because it is an honest edge of GitOps. Declarative apply gets
the ConfigMap into the cluster. It does not get the rules into the ruler. Knowing
where the declarative model stops, and putting a deliberate, idempotent hook there,
is better than pretending the gap is not there.

**The test detail worth copying.** The promtool test extracts the **same ConfigMap
data key that the ruler loads** and asserts against that. So the test exercises
exactly the artefact that ships. There is no second copy of the rules living in the
test fixtures, waiting to drift out of sync with the real ones.

**The gotcha.** Mimir sets the job label to `demo/sample-api`, namespace slash
service, because the app declares a `service.namespace`. Not `sample-api`. A
"no requests are arriving" alert written as `absent(...{job="sample-api"})` would
therefore have matched nothing and fired **forever**. It had to key on
`service_name` instead. An `absent()` rule with a typo in the selector does not
fail. It just alerts, permanently, and teaches everyone to ignore it.

**Takeaway.** Alerting is code. It gets review, tests, and a deploy path like
anything else. And the test has to run against the artefact that actually ships,
not a copy of it.

---

## 6. Nothing watches the monitoring system

**The problem.** If the Collector dies, telemetry stops flowing. So the app alerts
stop evaluating too. Nothing fires. And silence looks exactly like health.

**Where it shows up.** The worst kind of incident: the one where the dashboards were
green because they were dead.

**Frame the goal, not the tool.** "Any important service has a problem" splits into
two very different jobs:

- **The service is down or crash-looping.** One uniform signal covers every service
  at once, and it needs nothing from the services themselves.
- **The service is alive but broken.** The Collector is running but dropping data.
  This needs each service's own internal metrics, service by service.

The first has by far the highest coverage for the least work, so do it first. That
ordering is the actual decision. The receiver is just how you implement it.

**What this lab does.** The `k8s_cluster` receiver, added to the gateway Collector
that already exists ([ADR 018](adr/018-platform-health-via-k8s-cluster-receiver.md)).
It watches the Kubernetes API server and emits workload state
(`k8s.deployment.available` and `desired`, `k8s.statefulset.ready_pods` and
`desired_pods`, `k8s.container.restarts`) as OTLP metrics into the Mimir pipeline
that is already there. Three alerts come off it: Deployment unavailable, StatefulSet
unavailable, container restarting more than twice in 15 minutes.

No kube-state-metrics. No scrape path. No DaemonSet. The receiver is cluster-wide,
so it fits on the single gateway, and a single replica needs no leader election.

**What it costs.** The Collector now needs cluster-wide read RBAC (list and watch on
workloads, nodes, namespaces, quotas, HPAs). That is a real privilege increase over
a Collector that only received OTLP. It is read-only, with no write verbs, and it
is the same access kube-state-metrics would have needed anyway. But it is a change
worth stating rather than sliding past.

**The gap, stated out loud.** There is **no dead-man's switch**. These platform
alerts run inside the platform they watch. The rules live in the Mimir ruler and
depend on the Collector and Mimir being up. So they catch a single service failing.
They cannot catch the platform failing as a whole. If Mimir dies, the alerts die
with it.

This is the "who watches the watchers" problem, and the standard fix is known:
emit one alert that always fires, let it flow the whole pipeline out to a receiver
**outside** the failure domain (a heartbeat endpoint, a snitch service), and have
that receiver alert when the heartbeat stops. **Absence of signal becomes the
signal.**

It was not built here, because a single-node k3d cluster has no independent place to
put the receiver, and an external endpoint is out of scope for the lab. The gap is
documented rather than papered over, along with the approach that would close it.

**Takeaway.** A monitor that shares a failure domain with the thing it monitors
cannot report that domain failing. Any real answer needs a watcher outside the
domain, and the signal you alert on is silence. Naming the gap honestly is a better
answer than a dashboard that merely looks covered.

---

## 7. Reaching for a DaemonSet you do not need

**The problem.** People default to running the Collector as a DaemonSet because that
is what the diagrams show. Then they cannot say what it is buying them.

**Where it shows up.** Any Collector topology discussion. The wrong answer sounds
confident: "a DaemonSet, so it scales with the cluster."

**The reasoning that actually decides it.** On a single node, "a DaemonSet is
cheaper" is meaningless. A DaemonSet is about **function, not cost**. There are only
two real reasons to want one:

1. **The data is node-local.** Host CPU, memory and disk (`host_metrics`), per-pod
   cAdvisor stats (`kubelet_stats`), or logs read off node files. A central
   Deployment physically cannot collect these. This is the only *hard* reason.
2. **You want to drop volume before it crosses the network.**

And here is the sharp part of reason 2: **filtering power is identical on the agent
and on the gateway.** Same OTTL, same `filter` processor, same expressiveness. The
agent's only advantage is **location**. On the gateway you still have to receive and
parse every record before you can decide to throw it away. On the node, the dropped
volume never leaves the node at all.

That is a real advantage, but it is a narrow one, and it is worth being precise
about rather than hand-waving at "efficiency".

**What this lab does.** An opt-in DaemonSet agent, placed **in front of** the
gateway rather than replacing it, and on the logs path only
([ADR 019](adr/019-optional-agent-tier-for-node-local-log-filtering.md),
`k8s/manifests/collector-agent/values.yaml`). The app points only its logs endpoint
at the agent; traces and metrics still go straight to the gateway. The agent drops
DEBUG and health-probe noise and forwards the rest. Kept logs still converge on the
one gateway, so the single-egress model from Scenario 1 holds.

The gateway keeps every cluster-singleton job: `span_metrics`, `k8s_cluster`, and
the only connection to the backends. That is not an accident. Span-to-metric
aggregation and tail sampling need to see **all** spans in one place, and a per-node
agent by definition sees only its own node's spans.

The whole tier is off by default. Delete the Argo Application and the app's logs
endpoint, and it falls back to the single-gateway topology.

**The guardrail worth copying.** Every drop condition in the filter is gated below
WARN. So no matter how the noise rules grow, an ERROR can never be silently
swallowed by a log filter. A noise filter that can eat errors is a liability, not an
optimisation.

**Honest scope.** At lab volume the gateway is never stressed. This is a
demonstration of the pattern, not a capacity need, and the ADR says so. Overclaiming
it as a performance fix would be easy and wrong.

**Takeaway.** Pick a topology from the function you need, node-local data or dropping
volume before the wire, not from habit. And when you do add an agent tier, it goes
**in front of** the gateway. It does not replace it, because the gateway is where
the work that needs a global view has to live.

---

## 8. Argo says Healthy and the system is broken

The best failure in this repo, and the one that transfers furthest
([ADR 005](adr/005-webhook-cert-without-cert-manager.md), superseded by
[ADR 016](adr/016-webhook-cert-via-cert-manager.md)).

**The invariant.** An admission webhook's `caBundle` must be the CA that signed the
webhook's serving certificate. If they do not match, the API server cannot call the
webhook.

**What broke it.** The OpenTelemetry Operator chart offers `autoGenerateCert`, which
self-signs a cert and patches the `caBundle` itself. The original decision took it,
on the stated assumption that the chart only regenerates the cert on a deliberate
Helm change.

Under Argo that assumption is false. `autoGenerateCert` generates a fresh random CA
**at Helm render time**. Render the chart twice with identical values and you get two
different `caBundle` values. Argo renders on every refresh and re-applies on drift,
because `selfHeal` is on. So the Secret and the webhook's `caBundle` ended up coming
from two different renders.

The symptoms, once we went looking: `openssl verify` of the serving cert against the
`caBundle` failed with `unable to get local issuer certificate`, and the operator
logged `tls: bad certificate` on every webhook call from the API server.

**Why it was invisible.** The pod-mutating webhook is `failurePolicy: Ignore`. When
the API server cannot verify the webhook, pod creation **still succeeds**, just
without the injection. So every app pod that restarted came back with no
auto-instrumentation, and therefore silently lost **all three signals**, while Argo
reported every Application Synced and Healthy.

It only surfaced at all because a *second* webhook (`minstrumentation.kb.io`, which
validates the `Instrumentation` CR) is `failurePolicy: Fail`, so it refused loudly
and returned the TLS error. Without that accident, the failure had no voice.

**The fix, and the framing that generalises.** The distinction that matters is
**not** self-signed versus properly issued. The chart's cert-manager mode also issues
a self-signed certificate. The real distinction is **snapshot versus continuous
reconciliation**.

cert-manager issues the serving cert into the Secret and rotates it before expiry,
and its CA injector writes the matching `caBundle` onto the webhook from that same
Secret, rewriting it whenever the cert rotates. Both halves of the invariant become
reconciled, instead of frozen at whatever a render produced once.

Two workarounds were rejected, and the reason is the same for both: they leave the
invariant unmaintained.

- **Commit a static self-signed cert to git.** It stops the drift by freezing it.
  The same silent failure comes back at expiry, a year later, and the private key
  lives in git.
- **Tell Argo to `ignoreDifferences` on the caBundle and the Secret.** This only
  hides the random values from Argo. Argo can then no longer manage or repair the
  webhook at all.

**The testing lesson, which is half the value.** The existing verification step
looked at a long-lived pod that had been injected *before* the drift started. It
stayed green throughout. It could not have caught this.

The new guard creates a pod carrying the inject annotation via **server-side
dry-run**, and asserts the init-container comes back. That exercises the webhook on
a *fresh* pod, which is the path that actually regressed.

**Takeaway.** Three things, and they all travel:

- "Synced and Healthy" means the desired state was applied. It does not mean the
  system works. Do not let a GitOps dashboard stand in for a health check.
- Any invariant that spans two objects (a cert and its `caBundle`) needs something
  that reconciles the **relationship**, not each object on its own. A tool that
  reconciles both objects independently will happily keep them consistently wrong.
- A check that only inspects existing state will not catch a regression in the path
  that **creates** new state. Test the fresh path, not the already-good result.

---

## 9. Deciding what not to build

**The problem.** The hardest scoping question is not what to add. It is where the
platform stops. Without a rule, scope creeps by a series of individually reasonable
yeses.

**The working rule.** Judge a capability by its relationship to telemetry:

- **IN.** It produces, moves, stores, or shows telemetry. Collectors, backends,
  dashboards, alert rules. This is the platform.
- **BOUNDARY.** It **consumes** telemetry in order to act, or it pushes its own
  telemetry in over OTLP. Judge these case by case. An autoscaler that scales on a
  metric sits exactly here, and Step 7 pulls one across on purpose: KEDA reads the
  app's request rate from Mimir and scales it (ADR 020). Argo owns the scaling
  policy, the runtime owns the replica count.
- **OUT.** It does not touch your telemetry at all. Not your problem.

The Collector's ingest and egress edges are the boundary line. The boundary is not
a wall, it is a design lever: pulling something across it is a decision you make on
purpose, with a reason.

**The habit that makes the rule work.** Every ADR in this repo names a **revisit
trigger**: the condition under which the decision should be reopened. Grafana stays
on SQLite until we need HA. The gateway stays a Deployment until we need node-local
data. Helm stays Kustomize-free until a chart hardcodes a field with no escape
hatch.

A decision with a written revisit trigger is scoped to today's constraints without
becoming permanent by accident. It stops premature building at one end, and stale,
untouchable decisions at the other.

**What is deliberately not built here, and why.** Each one is on record, not quietly
missing:

- **A dead-man's switch.** Needs a receiver outside the failure domain. A single-node
  cluster has no such place. See Scenario 6.
- **Node-local host and cAdvisor metrics.** `host_metrics` and `kubelet_stats` need
  a DaemonSet agent tier on every node. That is ADR 009's revisit trigger, and a
  bigger change than it looks. See Scenario 7.
- **ArgoCD drift alerting.** ArgoCD's own app-health metrics are Prometheus-only, so
  alerting on "an app drifted" would need a `prometheus` receiver as an ingest
  adapter, which cuts against the OTLP-only model in Scenario 4. "ArgoCD is down" is
  already covered by `k8s_cluster` at the workload level. Only the drift part is
  deferred.

Autoscaling used to sit on this list. Step 7 pulled it across the boundary on
purpose (KEDA scales the app on its request rate, ADR 020), so it is now a built
BOUNDARY capability rather than a deferred one. Safe scale-to-zero was the next
deferred item under it, on ADR 020's revisit trigger. Step 8 built that too: the
KEDA HTTP Add-on rests a second backend at zero and wakes it on the first request
(ADR 021). Two autoscaling patterns now coexist on purpose, a reactive metric for
a service that bursts and a request-path hold for one that idles to zero. The one
worry ADR 020 had, that the Add-on's own metrics were Prometheus-only and the lab
has no scrape path, was avoided rather than accepted: the interceptor pushes its
metrics over OTLP through `extraEnvs`, so the scaling layer is observed without a
scrape mechanism.

**Takeaway.** A platform is defined as much by its refusals as by its features. An
undocumented gap is a blind spot. The same gap, written down with the condition that
would reverse it, is an asset: it shows you saw it, priced it, and decided.

---

## Where the detail lives

Every scenario above compresses an ADR or two. When the compressed version is not
enough:

- [`ARCHITECTURE.md`](ARCHITECTURE.md) for the runtime and GitOps diagrams, and a
  one-line summary of all 19 decisions.
- [`signal-strategy.md`](signal-strategy.md) for how logs, metrics, and traces
  divide the work.
- [`adr/`](adr/) for the full context, the alternatives that were rejected, and the
  revisit trigger of each decision.
- [`VERIFICATION.md`](VERIFICATION.md) for how each claim here was actually checked
  on a running cluster.
