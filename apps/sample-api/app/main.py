"""A tiny FastAPI service for the otel-platform-lab end-to-end checks.

It carries no OpenTelemetry code on purpose. The OTel Operator injects the
Python SDK at pod creation (zero-code auto-instrumentation), so every request
to a route below turns into a trace, and the log line in /rolldice becomes an
OTLP log record. Both go through the Collector (traces to Tempo, logs to Loki).
"""
import logging
import random

from fastapi import FastAPI

# Show INFO on stdout for local dev. In the cluster the operator also adds a
# handler that exports records as OTLP.
logging.basicConfig(level=logging.INFO)

# Set the level on our own logger explicitly. When the operator has already
# attached its OTLP handler to the root logger, basicConfig does not lower the
# root level, so without this an INFO record would be dropped before export.
logger = logging.getLogger("sample_api")
logger.setLevel(logging.INFO)

app = FastAPI(title="sample-api")


@app.get("/healthz")
def healthz():
    """Readiness probe target. Not the interesting path for traces."""
    return {"status": "ok"}


@app.get("/rolldice")
def rolldice():
    """The traffic endpoint. One server span, plus a log line carrying its
    trace_id, so the log-to-trace pivot has something to jump on."""
    result = random.randint(1, 6)
    logger.info("rolled a %s", result)
    return {"roll": result}
