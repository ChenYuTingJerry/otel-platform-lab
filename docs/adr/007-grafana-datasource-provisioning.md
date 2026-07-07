# ADR 007: Each backend ships its own Grafana datasource via the sidecar

Status: Accepted
Date: 2026-07-06

## Context

Grafana needs a datasource per backend to query it: Tempo for traces (Step 2b),
Loki for logs (Step 3), Mimir for metrics (Step 4). A datasource in Grafana is
just a small piece of config (name, type, URL). The question is where that
config lives and how it reaches Grafana.

Grafana provisions datasources from YAML files in
`/etc/grafana/provisioning/datasources/`. There are two common ways to get a
file into that directory with the Grafana Helm chart:

- **Inline in Grafana's values.** The chart has a `datasources:` block. You list
  every datasource there; the chart renders one provisioning ConfigMap. All
  datasource config sits in one place, inside Grafana's own values file.
- **Datasource sidecar.** The chart can run a sidecar container (`k8s-sidecar`,
  a plain container, not a CRD). It watches the cluster for ConfigMaps labelled
  `grafana_datasource` and writes their contents into the provisioning
  directory at runtime. Each datasource is a separate labelled ConfigMap that
  can live anywhere, shipped by whoever owns that backend.

We build the stack as an Argo app-of-apps, one Application per backend, each
step meant to be self-contained. That shape is the deciding factor here, not the
size of the config.

## Decision

Use the **datasource sidecar**. Enable `sidecar.datasources` in Grafana's
values once. Each backend then ships its own datasource as a labelled ConfigMap
next to the backend:

- Tempo's Application carries `tempo-grafana-datasource` (this step).
- Loki (Step 3) and Mimir (Step 4) will each add their own the same way.

Grafana's values do not list any datasource. Grafana does not know which
backends exist.

## Consequences

- Adding or removing a backend touches only that backend's files. Deleting the
  Tempo Application takes its datasource with it (the sidecar drops the file
  when the ConfigMap goes away). With the inline approach, every new backend
  would mean editing Grafana's values, so all three steps would keep coming
  back to one shared file.
- This matches the app-of-apps model: each Application is a complete unit,
  backend plus its Grafana wiring. It is also the pattern `kube-prometheus-stack`
  uses for both datasources and dashboards, so it is well-worn.
- The cost is a sidecar container in the Grafana pod that watches the
  Kubernetes API, plus one small ConfigMap per backend. For a lab this is
  cheap.
- One failure mode to know when debugging: if a datasource does not show up in
  Grafana, check the label on the ConfigMap (`grafana_datasource: "1"`) and the
  sidecar's search namespace before suspecting the datasource config itself.
  The inline approach has no such moving part, but we accept this trade for the
  decoupling.
- The sidecar loads datasources at runtime, so they can appear a few seconds
  after the ConfigMap does. Verification waits for the Tempo datasource through
  the Grafana API rather than assuming it is there the instant the pod is up.
