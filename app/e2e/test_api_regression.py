"""HTTP-level regression cases (TC-01 … TC-13) — see MANUAL_TEST_PLAN.md."""

from __future__ import annotations

import math
import re
import time
from collections.abc import Callable

import pytest
from playwright.sync_api import APIRequestContext, APIResponse
from targets import Target

PUBLIC_PATHS = {"/health", "/ready", "/info", "/status"}
METRIC_FAMILIES = (
    "platform_status_http_requests_total",
    "platform_status_http_request_duration_seconds",
    "platform_status_uptime_seconds",
)
IDENTITY_FIELDS = ("version", "environment", "cluster", "namespace", "pod")

_SAMPLE = re.compile(
    r"^(?P<name>[a-zA-Z_:][\w:]*)(?:\{(?P<labels>[^}]*)\})?\s+(?P<value>\S+)"
)
_LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')


def metric_value(exposition: str, name: str, **labels: str) -> float:
    """Sum of every sample of `name` whose labels include `labels`."""
    total = 0.0
    for line in exposition.splitlines():
        match = _SAMPLE.match(line)
        if not match or match["name"] != name:
            continue
        sample_labels = dict(_LABEL.findall(match["labels"] or ""))
        if all(sample_labels.get(k) == v for k, v in labels.items()):
            total += float(match["value"])
    return total


def json_ok(response: APIResponse) -> dict:
    assert response.status == 200, f"{response.url} → {response.status}"
    assert response.headers["content-type"].startswith("application/json")
    return response.json()


@pytest.mark.case("TC-01")
def test_health_reports_healthy(timed_get: Callable[[str], APIResponse]) -> None:
    body = json_ok(timed_get("/health"))
    assert body["status"] == "healthy"
    assert isinstance(body["uptime_seconds"], int | float)
    assert body["uptime_seconds"] >= 0


@pytest.mark.case("TC-02")
def test_ready_reports_ready(timed_get: Callable[[str], APIResponse]) -> None:
    assert json_ok(timed_get("/ready")) == {"status": "ready"}


@pytest.mark.case("TC-03")
def test_build_version_is_stamped(
    timed_get: Callable[[str], APIResponse], target: Target
) -> None:
    running = json_ok(timed_get("/info"))["version"]
    assert re.fullmatch(target.version_pattern, running), (
        f"version {running!r} does not match {target.version_pattern!r} — "
        "the image was built without APP_VERSION"
    )
    if target.expected_version:
        assert running == target.expected_version


@pytest.mark.case("TC-04")
def test_environment_wiring_matches_target(
    timed_get: Callable[[str], APIResponse], target: Target
) -> None:
    body = json_ok(timed_get("/info"))
    actual = {key: body[key] for key in target.expected}
    assert actual == target.expected


@pytest.mark.case("TC-05")
def test_status_agrees_with_info(timed_get: Callable[[str], APIResponse]) -> None:
    info = json_ok(timed_get("/info"))
    status = json_ok(timed_get("/status"))
    assert status["status"] == "healthy"
    for key in IDENTITY_FIELDS:
        assert status[key] == info[key], key


@pytest.mark.case("TC-06")
def test_uptime_increases(timed_get: Callable[[str], APIResponse]) -> None:
    first = json_ok(timed_get("/health"))["uptime_seconds"]
    time.sleep(1.1)
    second = json_ok(timed_get("/health"))["uptime_seconds"]
    assert second > first, "uptime went backwards — the process restarted mid-run"


@pytest.mark.case("TC-07")
def test_metrics_exposition(timed_get: Callable[[str], APIResponse]) -> None:
    response = timed_get("/metrics")
    assert response.status == 200
    assert response.headers["content-type"].startswith("text/plain")
    text = response.text()
    for family in METRIC_FAMILIES:
        assert f"# TYPE {family.removesuffix('_total')}" in text, family


@pytest.mark.case("TC-08")
def test_request_counter_tracks_traffic(
    api: APIRequestContext, timed_get: Callable[[str], APIResponse]
) -> None:
    labels = {"method": "GET", "endpoint": "/ready", "status_code": "200"}
    before = metric_value(
        timed_get("/metrics").text(), "platform_status_http_requests_total", **labels
    )
    for _ in range(5):
        assert api.get("/ready").ok
    after = metric_value(
        timed_get("/metrics").text(), "platform_status_http_requests_total", **labels
    )
    # ≥, not ==: kubelet readiness probes also hit /ready on a live pod.
    assert after - before >= 5


@pytest.mark.case("TC-09")
def test_health_latency_within_budget(
    timed_get: Callable[[str], APIResponse], target: Target
) -> None:
    samples: list[float] = []
    for _ in range(20):
        start = time.perf_counter()
        assert timed_get("/health").ok
        samples.append((time.perf_counter() - start) * 1000)
    samples.sort()
    p95 = samples[math.ceil(0.95 * len(samples)) - 1]
    assert p95 <= target.latency_p95_budget_ms, (
        f"p95 {p95:.1f} ms > {target.latency_p95_budget_ms} ms budget"
    )


@pytest.mark.case("TC-10")
def test_write_methods_rejected(api: APIRequestContext) -> None:
    assert api.post("/health").status == 405


@pytest.mark.case("TC-11")
def test_cors_allows_only_get(api: APIRequestContext) -> None:
    origin = "https://example.com"
    preflight = api.fetch(
        "/info",
        method="OPTIONS",
        headers={"Origin": origin, "Access-Control-Request-Method": "POST"},
    )
    assert preflight.status == 400

    simple = api.get("/info", headers={"Origin": origin})
    assert simple.ok
    assert simple.headers.get("access-control-allow-origin") == "*"


@pytest.mark.case("TC-12")
def test_unknown_route_is_clean_404(api: APIRequestContext) -> None:
    response = api.get("/does-not-exist")
    assert response.status == 404
    assert response.json() == {"detail": "Not Found"}


@pytest.mark.case("TC-13")
def test_openapi_contract(timed_get: Callable[[str], APIResponse]) -> None:
    spec = json_ok(timed_get("/openapi.json"))
    assert set(spec["paths"]) == PUBLIC_PATHS
    for path in PUBLIC_PATHS:
        assert set(spec["paths"][path]) == {"get"}, path
    assert spec["info"]["version"] == json_ok(timed_get("/info"))["version"]
