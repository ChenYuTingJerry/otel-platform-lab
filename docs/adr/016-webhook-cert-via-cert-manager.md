# ADR 016: Issue the OTel Operator webhook cert with cert-manager

Status: Accepted
Date: 2026-07-11

Supersedes: ADR-005

## Context

The OTel Operator ships an admission webhook that injects auto-instrumentation
into annotated pods (Step 2d). For the Kubernetes API server to call it over
TLS, one invariant must always hold:

> the webhook's `caBundle` must be the CA that signed the operator's serving cert.

ADR-005 chose the operator chart's `autoGenerateCert`: the chart self-signs a
cert through a Helm hook and patches the webhook `caBundle` itself. Its stated
assumption was that "the chart regenerates the cert only on a deliberate Helm
change". Under Argo (ADR-003) that assumption is false, and the invariant broke.

What actually happened, observed on the running cluster:

- The webhook `caBundle` and the operator's serving-cert Secret no longer
  matched. `openssl verify` of the serving cert against the caBundle failed with
  `unable to get local issuer certificate`.
- The operator logged `http: TLS handshake error ... remote error: tls: bad
  certificate` on every webhook call from the API server.
- A pod created with the inject annotation got no init-container. Injection was
  dead.

Why it drifts: `autoGenerateCert` generates a fresh random CA and cert **at
Helm render time**. Rendering the operator chart twice with identical values
produces two different `caBundle` values. Argo renders on every refresh and
re-applies on drift (selfHeal), so the Secret and the webhook `caBundle` end up
coming from different renders. `autoGenerateCert.recreate: false` does not help:
it still renders a random `caBundle`, and under `helm template` (which is what
Argo runs) it emits no Secret at all, because it relies on a cluster `lookup`
that returns nothing at render time.

Why it was invisible: the pod-mutating webhook `mpod.kb.io` has
`failurePolicy: Ignore`. When the API server cannot verify the webhook, pod
creation still succeeds, just without injection. So every app pod that restarts
silently loses all three signals, while Argo reports every Application
Synced/Healthy. The regression surfaced only because creating an
`Instrumentation` CR hits a second webhook, `minstrumentation.kb.io`, which is
`failurePolicy: Fail` and returned the TLS error out loud.

"Self-signed versus issued" is not the distinction that matters here. The
operator chart's cert-manager mode also issues a self-signed cert. The real
distinction is **snapshot versus continuous reconciliation** of the invariant
above.

## Decision

Issue the webhook serving cert with **cert-manager**, and keep the webhook
`caBundle` in sync with cert-manager's CA injector.

- Add cert-manager as an Argo Application (`jetstack/cert-manager` v1.21.0),
  sync-wave -2, so it is up before the operator (wave 0).
- Flip the operator values to `admissionWebhooks.certManager.enabled: true` and
  `autoGenerateCert.enabled: false`. The chart then renders a self-signed
  `Issuer`, a `Certificate` for the serving cert, and a webhook that carries a
  `cert-manager.io/inject-ca-from` annotation with **no `caBundle` baked in**.

This makes both halves of the invariant reconciled, not snapshotted:

- cert-manager issues the serving cert into the Secret and rotates it before
  expiry.
- The CA injector writes the matching `caBundle` onto the webhook from that same
  Secret, and rewrites it whenever the cert rotates.

Two alternatives were rejected as workarounds, because both leave the invariant
unmaintained:

- **A static self-signed cert committed to git** (the chart's third mode). It
  stops the drift, but freezes it. The same silent failure returns at cert
  expiry (one year), and the private key lives in git.
- **Argo `ignoreDifferences` on the caBundle and Secret.** This only hides the
  random values from Argo. Argo can then no longer manage or repair the webhook
  at all.

## Consequences

- Injection is fixed at the root. The `caBundle` and serving cert are now the
  same reconciled pair, and rotation keeps them together. Verified in-cluster:
  cert-manager's CA injector filled a probe webhook's `caBundle` to exactly
  match the issued cert (identical SHA256).
- Cost: one more controller. cert-manager runs three Deployments (controller,
  webhook, cainjector) plus its CRDs. ADR-005 declined this for "one webhook,
  not worth a controller". That reasoning was sound; its premise (autoGenerate
  is stable under our tooling) was not.
- Ordering. The operator's `Certificate`/`Issuer` are cert-manager CRDs, and the
  operator Deployment mounts the issued Secret. So cert-manager must be up first.
  cert-manager is sync-wave -2; the operator sync retries until cert-manager is
  Healthy, so a first apply shows brief churn before it converges. This is the
  same kind of cross-Application CRD-before-CR dependency the lab already lives
  with elsewhere.
- CRDs are installed by the cert-manager chart (`crds.enabled: true`) with the
  chart default `crds.keep: true`, so an Argo prune does not delete the CRDs and
  take every Certificate with them.
- The lab now has cert-manager available for any later TLS need (ingress, more
  webhooks), which was ADR-005's revisit trigger.
- New guard: `scripts/verify.sh` now creates a pod with the inject annotation
  via server-side dry-run and asserts the init-container comes back. This
  exercises the webhook on a fresh pod, which is what regressed here.
  `verify-step2d` could not catch it, because it inspects a long-lived pod that
  was injected before the drift.
