"""
platform-status — lightweight platform observability service.

Exposes structured health, readiness, and environment metadata endpoints
alongside a Prometheus-compatible /metrics scrape target. Designed to run
as a canary workload demonstrating Kubernetes liveness/readiness probes,
Argo Rollouts analysis templates, and Prometheus metric collection.
"""

import os
import socket
import time
from typing import Any

import uvicorn
from fastapi import FastAPI, Response, status
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

# ─── Application bootstrap ────────────────────────────────────────────────────

# `or`, not a getenv default: an env var set to "" (e.g. a downward-API
# fieldRef to a missing label) would otherwise make FastAPI refuse to start.
APP_VERSION = os.getenv("APP_VERSION") or "dev"
ENVIRONMENT = os.getenv("ENVIRONMENT", "unknown")
CLUSTER_NAME = os.getenv("CLUSTER_NAME", "unknown")
NAMESPACE = os.getenv("POD_NAMESPACE", "unknown")
POD_NAME = os.getenv("POD_NAME", socket.gethostname())

START_TIME = time.monotonic()

app = FastAPI(
    title="platform-status",
    version=APP_VERSION,
    description=(
        "Platform observability service — health, readiness, and runtime metadata."
    ),
    docs_url="/docs",
    redoc_url=None,
)

# Public, unauthenticated, read-only status data: any origin may GET it.
# Regression case TC-11 asserts non-GET preflights stay rejected.
app.add_middleware(
    CORSMiddleware,
    # nosemgrep: python.fastapi.security.wildcard-cors.wildcard-cors
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)

# ─── Prometheus metrics ───────────────────────────────────────────────────────

REQUEST_COUNT = Counter(
    "platform_status_http_requests_total",
    "Total HTTP requests handled.",
    ["method", "endpoint", "status_code"],
)

REQUEST_LATENCY = Histogram(
    "platform_status_http_request_duration_seconds",
    "HTTP request duration in seconds.",
    ["endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5),
)

UPTIME_GAUGE = Gauge(
    "platform_status_uptime_seconds",
    "Seconds since the process started.",
)

# ─── Middleware — instrument every request ────────────────────────────────────


@app.middleware("http")
async def prometheus_middleware(request: Any, call_next: Any) -> Any:
    start = time.monotonic()
    response = await call_next(request)
    duration = time.monotonic() - start

    endpoint = request.url.path
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=endpoint,
        status_code=response.status_code,
    ).inc()
    REQUEST_LATENCY.labels(endpoint=endpoint).observe(duration)
    UPTIME_GAUGE.set(time.monotonic() - START_TIME)
    return response


# ─── Endpoints ────────────────────────────────────────────────────────────────


@app.get("/health", summary="Liveness probe")
def health() -> dict[str, Any]:
    """
    Kubernetes liveness probe target.
    Returns 200 as long as the process is alive.
    """
    return {
        "status": "healthy",
        "uptime_seconds": round(time.monotonic() - START_TIME, 2),
    }


@app.get("/ready", summary="Readiness probe")
def ready() -> dict[str, Any]:
    """
    Kubernetes readiness probe target.
    Returns 200 when the service is ready to receive traffic.
    Argo Rollouts analysis templates poll this endpoint during canary promotion.
    """
    return {"status": "ready"}


@app.get("/info", summary="Runtime environment metadata")
def info() -> dict[str, Any]:
    """
    Returns structured metadata about the running instance.
    Useful for verifying correct environment promotion in GitOps pipelines.
    """
    return {
        "version": APP_VERSION,
        "environment": ENVIRONMENT,
        "cluster": CLUSTER_NAME,
        "namespace": NAMESPACE,
        "pod": POD_NAME,
        "uptime_seconds": round(time.monotonic() - START_TIME, 2),
    }


@app.get(
    "/metrics",
    summary="Prometheus metrics scrape target",
    include_in_schema=False,
)
def metrics() -> Response:
    """
    Prometheus-format metrics endpoint.
    Scraped by kube-prometheus-stack via PodMonitor or ServiceMonitor CRs.
    """
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/status", summary="Aggregate status check", status_code=status.HTTP_200_OK)
def aggregate_status() -> dict[str, Any]:
    """
    Single endpoint that returns all runtime metadata plus health state.
    Used as the Argo Rollouts AnalysisTemplate success-rate check target.
    """
    return {
        "status": "healthy",
        "version": APP_VERSION,
        "environment": ENVIRONMENT,
        "cluster": CLUSTER_NAME,
        "namespace": NAMESPACE,
        "pod": POD_NAME,
        "uptime_seconds": round(time.monotonic() - START_TIME, 2),
    }


# ─── Entrypoint ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(
        "src.main:app",
        host="0.0.0.0",
        port=8080,
        log_level="info",
    )
