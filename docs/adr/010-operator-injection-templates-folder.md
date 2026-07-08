# ADR 010: Operator injection templates get their own folder

Status: Accepted
Date: 2026-07-08

## Context

The OTel Operator (Step 2a) installs two things: the CRDs (the types
`OpenTelemetryCollector` and `Instrumentation`) and a mutating webhook. It does
not create any instances. Checked against the chart: `helm template` of the
operator chart renders CRDs, a Deployment, webhooks, and RBAC, but zero
`Instrumentation` or sidecar `OpenTelemetryCollector` instances.

So the instances are ours to author. Two are coming:

- The `Instrumentation` CR (Step 2d). A hand-written CR that declares the
  language SDKs, the exporter endpoint (the collector Service), the sampler, and
  resource attributes. You write and commit it, annotate the app pods, and the
  webhook injects an init-container at pod creation.
- A sidecar-mode `OpenTelemetryCollector` CR (a possible future ADR 009 revisit,
  for local buffering near the app). Also hand-written, also injected by
  annotation.

These are a different kind of artifact from the deployed components (Grafana,
Tempo, the gateway Collector). A deployed component is a Helm chart that turns
into a running workload. An injection template is a CR that runs nothing on its
own; it sits and waits for a pod annotation to reference it, and the webhook
does the work. Injection templates are also namespace-scoped: they must live in
the namespace of the target app pods, which may not be `observability`.

The current layout (`k8s/argocd/applications/` for Argo Application CRs,
`k8s/manifests/<component>/` for what they deliver) is built around deployed
components. Mixing injection templates into that same shape blurs two different
kinds of thing.

## Decision

Keep operator injection templates in one dedicated folder, delivered by a single
Argo Application, separate from the deployed-component folders.

- Folder: `k8s/manifests/otel-injection/`. A neutral name, because it holds both
  `Instrumentation` CRs and any sidecar `OpenTelemetryCollector` CRs.
- One Argo Application `otel-injection`, a raw directory source with
  `recurse: true`, the same shape as the Tempo datasource source in
  `k8s/argocd/applications/tempo.yaml`. Adding a language or a sidecar flavor is
  a new file in the folder, not a new Application.
- `ServerSideApply=true`. These are operator CRs, so the defaulting webhook adds
  fields to them. SSA keeps Argo from fighting those fields. (The escape we used
  for the gateway, a Helm chart instead of a CR, is not available here: a
  sidecar has no chart, it is CR-only.)
- Namespace: the app namespace, not `observability`. Set on the CRs and the
  Application destination once the app namespace is fixed in Step 2d.
- sync-wave after the operator CRDs (wave 0).

## Consequences

- `k8s/argocd/applications/` stays for Argo Application CRs, and
  `k8s/manifests/<x>/` stays for what they deliver. Injection templates are
  grouped as their own category instead of being scattered among deployed
  components.
- The folder scales without churn: a new SDK language or a new sidecar variant
  is one file, and the single `otel-injection` Application picks it up.
- The convention is set now, but nothing is built yet. The folder and its
  Application are created in Step 2d, when the first `Instrumentation` CR lands.
  Step 2c is not affected.
- Injection templates carry the operator-CR drift concern (see ADR 009), handled
  the same way, with `ServerSideApply`.
- Revisit trigger: if injection templates ever need to live in several app
  namespaces at once, one Application may need to become one per namespace, or an
  ApplicationSet. Fold that in when a second app namespace appears.
