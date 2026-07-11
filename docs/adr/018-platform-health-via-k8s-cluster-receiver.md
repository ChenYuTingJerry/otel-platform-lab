# ADR 018: Platform self-health via the k8s_cluster receiver

Status: Accepted
Date: 2026-07-11

## Context

Step 5 gave the sample app RED alerting. Nothing watches the platform's own
services. If the Collector, Mimir, Loki, Tempo, or Grafana goes down, no alert
fires, and worse, a dead Collector silently stops all telemetry so the app
alerts stop working too. Step 6 closes that gap. The goal, in the user's words:
"be able to see when any important service has a problem, and get notified."

"Any important service has a problem" splits in two:

- **The service is down or crash-looping** (Deployment not available, pod
  CrashLoopBackOff, OOMKilled). One uniform signal covers every service at once,
  and it does not need each service to expose good internal metrics.
- **The service is alive but broken** (Collector running yet dropping data).
  Needs each service's own internal metrics.

The first kind has the highest coverage for the least work, so Step 6a targets
it: watch workload health for every important service and alert on it.

The lab had no metrics-collection mechanism for infrastructure at all. The
Collector's `prometheus` receiver is nulled on purpose (ADR 002, OTLP-only), and
there is no kube-state-metrics, no node-exporter, no Prometheus Operator. So the
question was how to get workload state into Mimir.

The obvious answer (install kube-state-metrics and scrape it) pulls in a
Prometheus scrape path, which fights ADR 002's "apps only send OTLP, the
Collector is the only backend client" model and the migration argument behind it
(swap the backend by changing one exporter). But there is an OTLP-native option.

The `otel/opentelemetry-collector-k8s` distro already in use ships the
`k8s_cluster` receiver. It watches the Kubernetes API server and emits workload
state as OTLP metrics (`k8s.deployment.available`/`desired`,
`k8s.statefulset.ready_pods`/`desired_pods`, `k8s.container.restarts`,
`k8s.pod.phase`, and more). It is a single cluster-wide receiver, not node-local,
so it fits the existing single gateway Deployment (ADR 009) and needs no
DaemonSet. It replaces kube-state-metrics for our needs without a scrape path.

Node-local data (host CPU/mem/disk, per-pod cAdvisor stats) is different: the
matching receivers (`host_metrics`, `kubelet_stats`) must run on every node, so
they need a DaemonSet agent tier. That is ADR 009's revisit trigger and a bigger
change, so it is out of scope here.

ArgoCD's own app-health metrics (`argocd_app_health_status`, Synced/OutOfSync)
are Prometheus-only; ArgoCD has no OTLP metrics exporter. Alerting on GitOps
drift therefore needs the `prometheus` receiver as an ingest adapter, which is a
separate decision. `k8s_cluster` already sees ArgoCD's Deployments at the
workload level, so "argocd is down" is covered here; only "argocd says an app
drifted" is deferred.

## Decision

Add the `k8s_cluster` receiver to the existing gateway Collector Deployment and
feed it into the metrics pipeline that already exports to Mimir. Grant the
Collector's ServiceAccount a read-only ClusterRole (list/watch workloads, nodes,
namespaces, quotas, HPAs) through the chart's `clusterRole` values.

Promote the workload-identity resource attributes in Mimir so the metrics carry
usable labels: extend `promote_otel_resource_attributes` with `k8s.namespace.name`,
`k8s.deployment.name`, `k8s.statefulset.name`, `k8s.pod.name`, `k8s.container.name`.
Under OTLP, Mimir keeps resource attributes out of labels and pushes them into
`target_info` unless promoted. A smoke test proved that without promotion every
`k8s_deployment_available` series collapses to one unlabeled series, so the
alerts could not tell which workload is down.

Alert on workload health with the same as-code path as Step 5 (rules ConfigMap
loaded into the Mimir ruler by the PostSync `mimirtool` Job, routed by the
bundled Alertmanager to the alert-sink webhook):

- `PlatformDeploymentUnavailable`: a Deployment has fewer available replicas than
  desired for 5m.
- `PlatformStatefulSetUnavailable`: a StatefulSet has fewer ready pods than
  desired for 5m.
- `PlatformContainerRestarting`: a container restarted more than twice in 15m.

Scope the alerts (and the dashboard) to the namespaces that hold services we care
about: `observability`, `demo`, `argocd`. This keeps `kube-system` churn
(coredns, local-path-provisioner) out of the alerts.

Defer to later phases: node-local metrics via a DaemonSet agent
(`host_metrics`/`kubelet_stats`), and ArgoCD GitOps-drift alerting via the
`prometheus` receiver.

## Consequences

- Platform workload health is observable and alertable end to end, reusing the
  Step 5 alerting path. "Any important service down or crash-looping" now
  notifies, which is the Step 6 goal.
- Stays OTLP-native and consistent with ADR 002. No scrape path, no
  kube-state-metrics, no node-exporter. The Collector is still the only backend
  client, so the backend-swap migration argument holds.
- The gateway stays a single Deployment (ADR 009). `k8s_cluster` is cluster-wide,
  so no DaemonSet is introduced. A single replica needs no leader election.
- The Collector now needs cluster-wide read RBAC. This is a real privilege
  increase over the previous OTLP-only gateway, but read-only (list/watch, no
  writes), and it is the same access kube-state-metrics would have required.
- Promoting five more resource attributes adds labels to any metric that carries
  them. No cardinality cost on the app metrics: they already carry a per-pod
  `instance` label, so `k8s_pod_name` is functionally redundant, not a multiplier.
- `promote_otel_resource_attributes` is still experimental in Mimir. Same caveat
  as ADR 014; accepted at lab scale.
- Two open follow-ups are named and scoped, not silently dropped: node-local
  resource metrics (needs the DaemonSet agent tier, ADR 009 revisit) and ArgoCD
  drift alerting (needs the `prometheus` receiver, revisit against ADR 002).

## Known limitation: these alerts share fate with the platform

The platform-health alerts run inside the platform. The rules live in the Mimir
ruler and depend on the Collector and Mimir being up. So they catch a single
service failing, but they cannot catch the platform failing as a whole: if the
Collector or Mimir dies, the alerts die with it, and silence looks like health.
This is the "who watches the watchers" problem.

The standard solutions are recorded here as known options, not as work to do:

- **Dead-man's switch (watchdog).** Emit one always-firing alert that flows the
  full pipeline to an *external* receiver (Dead Man's Snitch, healthchecks.io, a
  PagerDuty heartbeat). That receiver alerts when the heartbeat stops, so absence
  of signal is the signal. Needs the Collector's own `otelcol_*` self-telemetry
  wired in (today it sits on a `:8888` pull reader that no Service exposes).
- **Independent second monitor.** A small, separate monitoring instance that
  watches the primary one, living outside this cluster so it does not share fate.

Both only work if the watcher is independent of the watched. On a single-node
k3d cluster there is no independent place inside it, so any real value requires an
external endpoint. That external dependency is out of scope for this lab, so we
decided **not** to build a dead-man's switch here. It is documented so the gap is
explicit and the approach is on record if the lab ever grows a second failure
domain.
