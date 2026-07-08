"""A tiny FastAPI service for the otel-platform-lab end-to-end trace check.

It carries no OpenTelemetry code on purpose. The OTel Operator injects the
Python SDK at pod creation (zero-code auto-instrumentation), so every request
to a route below turns into a trace that the Collector forwards to Tempo.
"""
import random

from fastapi import FastAPI

app = FastAPI(title="sample-api")


@app.get("/healthz")
def healthz():
    """Readiness probe target. Not the interesting path for traces."""
    return {"status": "ok"}


@app.get("/rolldice")
def rolldice():
    """The traffic endpoint. Each call is one server span in Tempo."""
    return {"roll": random.randint(1, 6)}
