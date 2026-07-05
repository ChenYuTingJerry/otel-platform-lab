# ADR 003: ArgoCD manages every workload from day one

Status: Accepted
Date: 2026-07-05

## Context

The lab is built in 4 steps: Grafana, then Tempo, then Loki, then Mimir. We
had to decide when to introduce ArgoCD.

Option A: Helm CLI for early steps, migrate to Argo at the end.
Option B: Argo installed on day one, every workload (starting with Grafana)
managed through Argo Application CRs.

Option A means one migration later. Option B means Step 1's scope grows from
"Grafana up" to "Argo up plus Grafana synced through Argo".

## Decision

Option B. Argo from day one.

## Consequences

- Step 1 takes longer. There is more to install and to verify (Argo pods
  Ready, Application Synced, Application Healthy, then the Grafana UI).
- No migration later. The bootstrap flow that gets Grafana up is the same
  flow that will get Tempo, Loki, Mimir, the OTel Collector, and the
  Operator up in later steps.
- Every workload lives in Git as an Argo Application CR plus a Helm values
  file. Diff and rollback are done through Argo.
- The one thing Argo cannot manage is Argo itself. That install stays as a
  `helm install` step in the Makefile (`make argocd`).
- Debugging surface is wider. A Grafana problem might live in the chart, in
  the Helm values, in the Argo Application CR, or in Argo's own sync engine.
  We accept this in exchange for the day-one GitOps flow.
