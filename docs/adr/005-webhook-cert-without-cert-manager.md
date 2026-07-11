# ADR 005: Self-generate the OTel Operator webhook cert, not cert-manager

Status: Superseded by ADR-016
Date: 2026-07-06

> Superseded on 2026-07-11. `autoGenerateCert` regenerates a random cert on every
> Helm render, so under Argo the webhook `caBundle` and the serving cert drift
> apart and injection breaks silently. The premise below ("the chart regenerates
> it on a Helm change") does not hold under GitOps. See ADR-016 for the cert-manager
> replacement and the full diagnosis.

## Context

The OpenTelemetry Operator ships an admission webhook. It is the mutating
webhook that injects auto-instrumentation into annotated pods (Step 2d). The
webhook server needs a TLS cert, and the Kubernetes API server needs to trust
it through the webhook's `caBundle`. Something has to create that cert and keep
the `caBundle` in sync.

The operator Helm chart offers two ways to do this:

- **cert-manager**: a separate controller that issues and rotates the cert.
  This is the chart's production-oriented default. It means installing and
  running cert-manager in the cluster.
- **autoGenerateCert**: the chart self-signs a cert through a Helm hook and
  patches the webhook `caBundle` itself. No extra controller.

For this lab there is exactly one webhook and no other TLS need. We do not serve
TLS to users, and no other component wants issued certs yet.

## Decision

Use `autoGenerateCert` and keep `certManager.enabled: false`. Do not install
cert-manager just for this one webhook.

## Consequences

- One less controller to install, run, and reason about. cert-manager is a
  real dependency with its own CRDs and pods. It is not worth it for a single
  webhook.
- The self-signed cert is not rotated by a controller. The chart regenerates it
  on a Helm change instead. This is fine for a lab where the operator is not a
  long-lived production service.
- Revisit trigger: when we introduce cert-manager for a real reason (serving
  TLS on an ingress, or more webhooks that all want issued and rotated certs),
  fold this webhook into it so cert handling is uniform.
- The choice is a Helm values flip (`certManager` vs `autoGenerateCert`), so
  reversing it later is cheap. See `k8s/manifests/otel-operator/values.yaml`.
