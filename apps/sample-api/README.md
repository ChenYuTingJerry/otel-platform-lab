# sample-api

A tiny FastAPI service. It exists to prove one trace flows end to end through
the platform: app to Collector to Tempo, queryable in Grafana (Step 2d + 2e).

The service has no OpenTelemetry code. It opts in to zero-code
auto-instrumentation with a pod annotation
(`instrumentation.opentelemetry.io/inject-python`). At pod creation the OTel
Operator webhook injects an init-container that provides the Python SDK, sets
`PYTHONPATH` plus the `OTEL_*` environment, and points
`OTEL_EXPORTER_OTLP_ENDPOINT` at the Collector. The app never talks to a
backend directly (see `docs/adr/002`).

## Routes

- `GET /healthz` — readiness probe. Returns `{"status": "ok"}`.
- `GET /rolldice` — the traffic endpoint. Each call is one server span in Tempo.

The app is packaged with [uv](https://docs.astral.sh/uv/) and started with the
FastAPI CLI (`fastapi run`), which is FastAPI's officially recommended way to
serve an app. `fastapi run` is a thin wrapper over uvicorn.

## Layout

```
app/main.py         the FastAPI app
pyproject.toml      project + dependency (fastapi[standard]); no otel deps
uv.lock             locked dependency versions
Dockerfile          python:3.12-slim + uv, runs `fastapi run`
deploy/             its Kubernetes manifests (namespace demo)
```

## Local dev

```
uv sync             # create the venv from the lockfile
uv run fastapi dev app/main.py   # reload server on http://127.0.0.1:8000
```

## Build and run in the lab

No registry. The image is built and imported into the k3d cluster:

```
make sample-image   # docker build + k3d image import
make step2d         # Argo syncs the Instrumentation CR and this app
```

The Deployment uses `imagePullPolicy: IfNotPresent`, so it runs the imported
image. See `docs/VERIFICATION.md` for the per-step checks.
