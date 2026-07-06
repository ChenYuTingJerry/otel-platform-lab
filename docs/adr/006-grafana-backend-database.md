# ADR 006: Grafana uses SQLite in the lab, PostgreSQL when it needs HA

Status: Accepted
Date: 2026-07-06

## Context

Grafana keeps its own state in a relational database: dashboards, users, orgs,
API keys, datasource configs, alert rules, and annotations. This is not the
telemetry data (that lives in Tempo, Loki, and Mimir). It is Grafana's own
configuration and runtime state.

When we verified Step 1, we checked what Grafana runs on. It is the default
**SQLite**, and our values set `persistence.enabled: false`, so the `grafana.db`
file sits on the pod's ephemeral storage. A pod restart wipes it. That is fine
here because dashboards and datasources are meant to be provisioned
declaratively through Argo, not created by hand in the UI.

That raised two questions:

- Should we stay on SQLite, or move to an external database?
- If we move, MySQL or PostgreSQL? Grafana officially supports both.

The key fact for the first question: SQLite is a single file. It cannot be
shared safely across multiple Grafana replicas. So the trigger for an external
database is running Grafana in HA (more than one replica), not database size.

For the second question, Grafana's load on the database is tiny and simple. It
does not use advanced features of either engine. So the choice is driven more
by operational fit than by Grafana's needs.

## Decision

- The lab keeps Grafana on **default SQLite, non-persistent**. One replica,
  state provisioned as code, nothing precious in the database.
- Move to an **external database only when we need multiple replicas (HA)**.
- When that time comes, prefer **PostgreSQL** over MySQL, unless the platform
  already has a MySQL standard. Do not introduce a new engine just for Grafana.

## Consequences

- No persistence today. UI-created state (dashboards, users, annotations) is
  lost on pod restart. We accept this because state is declared in Git and
  re-synced by Argo. Anything worth keeping is provisioned, not hand-made.
- The move to an external database is triggered by HA, not by growth. A single
  replica on SQLite is the correct shape until we run more than one.
- PostgreSQL is preferred for two reasons. Grafana has fewer engine-specific
  footguns on Postgres. MySQL needs `utf8mb4` charset and collation care, and
  some Grafana migrations have hit MySQL row-size and index-length limits.
  Postgres also has stronger momentum in the Kubernetes world (CloudNativePG
  and similar operators).
- The org standard wins over this preference. If the platform already runs
  MySQL well, use MySQL. The cost of a new database engine is not worth it for
  a workload this small.
- Switching later is low-risk and deferrable. In our declarative setup there is
  nothing to migrate: point Grafana at the external database and re-provision.
  There is no clean cross-engine data migration, so any future UI-created state
  would be moved by re-provisioning (dashboards as JSON), not by copying the
  database file.
