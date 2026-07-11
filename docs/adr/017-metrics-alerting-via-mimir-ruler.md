# ADR 017: Metrics alerting runs in the Mimir ruler, not Grafana-managed

Status: Accepted
Date: 2026-07-11

Verified live on k3d through Argo on 2026-07-11 (commits 34d45b8 + c027900):
the ruler evaluates the RED rules, and a forced error burst drove
AppHighErrorRatio from pending to firing and out through the Alertmanager to the
webhook sink, end to end.

## Decisions made

The forks chosen for this step, with what each turned down:

- **Metrics alerting runs in the Mimir ruler.** Turned down: Grafana-managed
  rules for metrics.
- **Rules are Prometheus format, in git, unit-tested with `promtool`.** This is a
  chosen property, not a side effect.
- **Notifications go to Mimir's bundled Alertmanager, then an in-cluster webhook
  sink.** Turned down: a state-only setup with no receiver, and routing to an
  external Slack or email channel.
- **Grafana-managed alerting is kept in reserve.** It is used only for a rule that
  must span signals, or alert on a datasource with no ruler (Tempo), decided case
  by case.
- **Dashboard scope for the same step: one app RED dashboard.** Platform
  self-health (Collector throughput and drops, backend ingest health) needs
  telemetry wiring that does not exist yet, so it is deferred to Step 6 with its
  own ADR. Dashboards are otherwise out of this ADR (they follow the ADR-007
  ConfigMap-as-code path). The scope is recorded here because it was decided
  together with the alerting path.

## Context

Step 5 adds alerting on top of the metrics we already store. The targets are the
RED metrics derived from spans (ADR-015) and a few platform self-health signals
(Collector throughput and drops, backend ingest health). This ADR decides one
thing: where the metric alert rules live and what evaluates them. Dashboards and
the notification path are separate concerns, noted at the end.

Grafana's "unified alerting" is a UI umbrella, not a single rule engine. Under it
sit two different kinds of rule:

1. **Grafana-managed rules.** Grafana evaluates them itself, in its own rule
   format. One rule can query several datasources at once (for example a Loki log
   condition joined with a Mimir metric). The rule state lives in Grafana's
   database, and evaluation is centralised in the Grafana process.
2. **Data source-managed rules.** These are plain Prometheus rules (recording and
   alerting) that live in and are evaluated by the Mimir ruler. Grafana can read
   and edit them through the ruler API, but the evaluation happens in the backend,
   next to the data.

The deciding factor is what we want out of *metrics* alerting. We want the rules
in standard Prometheus format so they are portable and can be unit-tested with
`promtool test rules`. We want them in git and reviewed like any other code. We
want evaluation to keep working when Grafana is down, because a dashboard tool
being restarted should not stop an alert from firing. All three point to the
Mimir ruler. It also fits the shape of the rest of the stack: metrics concerns
live in the metrics backend, the same way ADR-002 keeps ingest in the Collector.

Two facts about this cluster shape the mechanics:

- **Tenant is `anonymous`.** The Collector pushes to `mimir-gateway` with no
  `X-Scope-OrgID` header (see `k8s/manifests/collector/values.yaml`), and Step 4
  writes land fine, so Mimir runs no-auth and all series sit under the default
  tenant `anonymous`. Rules must load under that same tenant, or the ruler
  evaluates them against an empty store.
- **The ruler does not read rules from a mounted file.** Mimir keeps rules in
  object storage, per tenant, and loads them through the ruler API. So "mount a
  ConfigMap and it takes effect" (the pattern datasources and dashboards use, per
  ADR-007) does not apply here. Rules are pushed with `mimirtool rules load`.

Grafana-managed rules are still the right tool for things the Mimir ruler cannot
do: a single rule that spans metrics and logs, or alerting on a datasource with no
ruler (Tempo). This ADR does not remove that option; it keeps metrics alerting out
of it.

## Decision

Author metric alert rules and recording rules as Prometheus rule files in git,
under `k8s/manifests/mimir/rules/`. Evaluate them in the Mimir ruler for tenant
`anonymous`. Do not route metrics alerting through Grafana-managed rules.

- **Enable the ruler and Alertmanager** in the Mimir values (both are off today,
  `k8s/manifests/mimir/values.yaml:44`). The chart already ships both components.
- **Load rules through the ruler API, kept inside the GitOps flow.** Rules live in
  a ConfigMap generated from the git files. An Argo-managed Job runs `mimirtool
  rules load --id anonymous` against the ruler on each sync (a PostSync hook), so
  Argo still owns the desired state and the imperative push is wrapped, not
  hand-run. This is the one seam where declarative apply is not enough, because
  the ruler's state lives in object storage, not in a Kubernetes object.
- **Unit-test the rules.** `promtool test rules` runs the rule tests as a `make`
  target and, later, in CI. This is the payoff of choosing Prometheus format, so
  it is part of the decision, not a nice-to-have.
- **Notifications go to the bundled Alertmanager, then to an in-cluster webhook
  sink.** Mimir's own Alertmanager handles routing. Its receiver is a small
  in-cluster service that logs what it gets, so the full path (rule fires ->
  Alertmanager -> receiver) is visible end to end without any external
  credentials.

## Consequences

- **Rules are portable and testable.** They are standard Prometheus rules in git,
  unit-tested with `promtool`, and would move to any Prometheus-compatible backend
  unchanged.
- **Alerts survive Grafana restarts.** Evaluation runs in the ruler, so bringing
  Grafana down (or losing it, since it has no persistence) does not stop alerting.
- **More moving parts than Grafana-managed.** We turn on the ruler, Alertmanager,
  and a webhook sink, and we add a rule-sync Job. That is real extra surface for a
  lab, accepted on purpose because practising this path is the point.
- **A rule-loading seam in the GitOps model.** Argo brings up the ruler
  declaratively, but a Job pushes the rules imperatively through the API. The Job
  is Argo-managed and idempotent, so re-running it is safe, but it is not a plain
  `kubectl apply`. This is inherent to how the Mimir ruler stores rules, and it is
  documented rather than hidden.
- **Tenant coupling is now load-bearing.** Rules target `anonymous`. If
  multitenancy is ever turned on, the rule tenant and the Collector's
  `X-Scope-OrgID` must be set and kept in step, or the ruler reads an empty store.
- **Revisit trigger.** If we later need one rule that spans metrics and logs, or
  alerting on Tempo, use a Grafana-managed rule for that specific case, and record
  why it is allowed to sit outside the ruler.
