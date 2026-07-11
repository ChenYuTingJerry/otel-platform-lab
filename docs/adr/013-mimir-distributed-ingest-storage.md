# ADR 013: Mimir runs as mimir-distributed in the ingest-storage architecture

Status: Accepted
Date: 2026-07-10

## Context

Step 4 adds Mimir as the metrics backend. Mimir is a horizontally scalable,
multi-service store for Prometheus-style metrics (it grew out of Cortex). Its
durable data always lives in **object storage** (S3 in production, the bundled
MinIO in this lab). Around that object store, Mimir runs a set of microservices.

### Chart and repo

Unlike Loki (ADR-011) and Tempo (ADR-008), there is no `mimir` chart on the
`grafana-community` repo. The only maintained chart is `mimir-distributed` on
the `grafana` repo. So Mimir cannot follow the community-repo pattern; it comes
from `grafana`, pinned to chart `6.1.0` (Mimir app `3.1.2`).

### Two architectures

Mimir can run in two shapes. The chart default changed between them at chart
6.0.0, so the shape is a real choice, not a given.

**Classic (push) architecture.** The distributor sends each sample straight to
ingesters over gRPC. Ingesters hold recent data in memory plus a write-ahead log
on disk, and flush blocks to the object store on a schedule. Durability on the
write path comes from replicating each sample across ingesters (replication
factor 3 by default). The read path queries ingesters for recent data and
store-gateways for older blocks.

```
Classic (push):

  Collector --OTLP--> distributor --gRPC(RF=3)--> ingester ---flush---> MinIO
                                                  ingester                 ^
                                                  ingester                 |
                                                                           |
  query-frontend -> query-scheduler -> querier --recent--> ingester        |
                                               --old------> store-gateway --+
  compactor: compacts and dedups blocks in MinIO
```

**Ingest-storage (Kafka) architecture.** The chart default since 6.0.0, and
Grafana's stated production direction. A Kafka broker sits between the
distributor and the ingesters. The distributor writes records to Kafka;
ingesters consume from Kafka, build blocks, and flush to the object store. Write
durability comes from Kafka, not from ingester replication, so the ingester's
own gRPC push method is turned off (`push_grpc_method_enabled: false`). The read
path is unchanged.

```
Ingest-storage (Kafka):

  Collector --OTLP--> distributor --write--> Kafka --consume--> ingester --> MinIO
                                             (durable write     (no gRPC push;         ^
                                              buffer)            reads from Kafka)     |
                                                                                       |
  query-frontend -> query-scheduler -> querier --recent--> ingester                    |
                                               --old------> store-gateway --------------+
  compactor: compacts and dedups blocks in MinIO
```

The key point for us: **the ingestion API is the same in both.** The distributor
exposes the OTLP endpoint (`/otlp/v1/metrics`) and Prometheus remote-write
(`/api/v1/push`) either way. Kafka sits behind the distributor, so whether it is
there or not changes nothing on the Collector side or in the lab's "everything is
OTLP" story. It only changes the internal write path and the pod count.

## Decision

Run Mimir as the `mimir-distributed` chart `6.1.0` from the `grafana` repo, in
the **ingest-storage (Kafka) architecture** (the chart default), with the
bundled MinIO as the object store. Trim it to a single-node dev footprint:
single replicas, zone-aware replication off, caches off, ruler and alertmanager
off, one Kafka broker in demo mode.

Do not force the classic architecture. Going classic means overriding the
chart's config to disable ingest storage, re-enable the ingester push method,
and disable Kafka. That is three overrides fighting the chart default, more
surface to break on each chart bump, for the sake of dropping one Kafka pod.

Do not use the monolithic single-binary Mimir here either (see the revisit
trigger below).

### Why ingest-storage, given the weight

- It is the chart's happy path. We deploy what the chart ships, with no config
  overrides on the architecture.
- It is the current production architecture. A lab that mirrors real platforms
  is more useful running the shape teams are moving to than the frozen one.
- The extra weight buys architectural realism at zero cost to the rest of the
  lab, because the OTLP ingestion path is identical either way. The only price
  is local resource use on k3d.

## Consequences

- **Heaviest backend in the lab.** A trimmed install still brings up about 12
  pods: distributor, ingester, querier, query-frontend, query-scheduler,
  store-gateway, compactor, `mimir-gateway`, overrides-exporter, rollout-operator,
  one Kafka broker, and MinIO. Tempo and Loki are single pods. This is a dev
  footprint on k3d, not a production sizing.
- **Kafka is a write-path buffer inside Mimir.** It buffers the distributor to
  ingester hop. Do not confuse it with collection-side buffering (an agent or
  sidecar collector near the app, discussed in ADR-009). They sit at different
  layers and neither replaces the other.
- **Repo deviation from ADR-008/011.** Mimir comes from `grafana`, not
  `grafana-community`, because the community repo does not carry it. Pinned to
  6.1.0 so nothing moves under us.
- **MinIO is bundled as the object store.** Filesystem storage is not an option
  in distributed mode because the components do not share a disk. Single-binary
  Mimir could use a filesystem, but we did not take that shape.
- **Two things are named "gateway".** The OTel Collector runs in gateway
  topology (ADR-009): one central collector for all apps. Mimir ships its own
  `mimir-gateway`, an nginx in front of its microservices that gives one URL for
  push and query. They are different layers. The Collector's metrics exporter
  targets `mimir-gateway` at `/otlp/v1/metrics`; Grafana queries `mimir-gateway`
  at `/prometheus`.
- **Revisit trigger.** If the k3d footprint becomes a problem on a laptop, the
  fallback is monolithic single-binary Mimir (`-target=all`, filesystem storage,
  no Kafka, no MinIO, one pod). We did not take it now because it hides the
  microservice topology this lab is meant to show.
