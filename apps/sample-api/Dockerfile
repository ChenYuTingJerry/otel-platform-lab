# A plain FastAPI image, packaged with uv. The only OpenTelemetry package is
# opentelemetry-api, used for one custom metric (Step 4). No SDK, no exporter:
# the OTel Operator injects those at pod creation, so tracing and logging stay
# zero-code.
FROM python:3.12-slim

# uv, pinned. Copied from the official distroless image (astral's recommended
# way to get uv into a container).
COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /uvx /bin/

WORKDIR /app

# Install dependencies in their own layer, from the lockfile only. The bind
# mounts keep pyproject.toml/uv.lock out of the layer; the cache mount reuses
# downloads across builds. --no-install-project: we run from source, we do not
# package the app itself (so no build backend needed).
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev

COPY app/ ./app/

# Put the venv on PATH and run the app directly. We do NOT use `uv run` as the
# entrypoint: the OTel Operator's Python injection relies on PYTHONPATH +
# sitecustomize at interpreter startup, and running the plain venv binary keeps
# that environment intact.
ENV PATH="/app/.venv/bin:$PATH"

EXPOSE 8000

# fastapi run is FastAPI's officially recommended way to serve an app. It is a
# thin wrapper over uvicorn and defaults to host 0.0.0.0.
CMD ["fastapi", "run", "app/main.py", "--port", "8000"]
