"""A tiny FastAPI service for the otel-platform-lab end-to-end checks.

Tracing and logging carry no OpenTelemetry code. The OTel Operator injects the
Python SDK at pod creation (zero-code auto-instrumentation), so every request
to a route below turns into a trace, and the log line in /rolldice becomes an
OTLP log record. Both go through the Collector (traces to Tempo, logs to Loki).

Metrics are the one exception (Step 4). The auto-instrumentation already exports
HTTP server metrics for free, but the counter below is declared by hand to show
an application-owned metric travelling the same path to Mimir.
"""
import logging
import random

from fastapi import FastAPI, HTTPException, Query
from opentelemetry import metrics

# Show INFO on stdout for local dev. In the cluster the operator also adds a
# handler that exports records as OTLP.
logging.basicConfig(level=logging.INFO)

# Set the level on our own logger explicitly. When the operator has already
# attached its OTLP handler to the root logger, basicConfig does not lower the
# root level, so without this an INFO record would be dropped before export.
logger = logging.getLogger("sample_api")
logger.setLevel(logging.INFO)

app = FastAPI(title="sample-api")

# Asking for the meter at import time is safe: until the injected SDK installs a
# real MeterProvider, the API hands back a proxy that forwards once it exists.
meter = metrics.get_meter("sample_api")

# The rolled value is deliberately NOT a label here. A metric stays aggregate;
# the per-request detail lives in the trace and the log line, which are already
# keyed to the same request. See docs/signal-strategy.md.
dice_rolls = meter.create_counter(
    "dice.rolls",
    unit="1",
    description="Total number of dice rolls served.",
)


@app.get("/healthz")
def healthz():
    """Readiness probe target. Not the interesting path for traces."""
    return {"status": "ok"}


@app.get("/rolldice")
def rolldice():
    """The traffic endpoint. One server span, a log line carrying its trace_id,
    and a counter increment. One request, all three signals."""
    result = random.randint(1, 6)
    dice_rolls.add(1)
    logger.info("rolled a %s", result)
    return {"roll": result}


@app.get("/flaky")
def flaky(rate: float = Query(0.2, ge=0.0, le=1.0)):
    """Fails with probability `rate` (a 500), else returns 200. Used to drive the
    RED error-ratio alert (Step 5). A 5xx makes the auto-instrumented server span
    status ERROR, so the request counts in
    traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"}, which pushes
    job:span_request_error_ratio:rate5m and, above 5% for 5m, fires
    AppHighErrorRatio. Default rate 0.2 is well over the 5% threshold."""
    if random.random() < rate:
        logger.warning("flaky failure (rate=%s)", rate)
        raise HTTPException(status_code=500, detail="flaky failure")
    return {"status": "ok"}
