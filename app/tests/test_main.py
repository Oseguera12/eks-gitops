"""Unit tests for platform-status endpoints."""

from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


class TestHealthEndpoints:
    def test_health_returns_200(self) -> None:
        response = client.get("/health")
        assert response.status_code == 200

    def test_health_body_structure(self) -> None:
        body = client.get("/health").json()
        assert body["status"] == "healthy"
        assert "uptime_seconds" in body
        assert isinstance(body["uptime_seconds"], float)

    def test_ready_returns_200(self) -> None:
        response = client.get("/ready")
        assert response.status_code == 200
        assert response.json()["status"] == "ready"


class TestInfoEndpoint:
    def test_info_returns_200(self) -> None:
        response = client.get("/info")
        assert response.status_code == 200

    def test_info_body_has_required_keys(self) -> None:
        body = client.get("/info").json()
        required = {
            "version",
            "environment",
            "cluster",
            "namespace",
            "pod",
            "uptime_seconds",
        }
        assert required.issubset(body.keys())


class TestMetricsEndpoint:
    def test_metrics_returns_prometheus_format(self) -> None:
        response = client.get("/metrics")
        assert response.status_code == 200
        assert "text/plain" in response.headers["content-type"]

    def test_metrics_contains_request_counter(self) -> None:
        # Trigger at least one request first
        client.get("/health")
        body = client.get("/metrics").text
        assert "platform_status_http_requests_total" in body

    def test_metrics_contains_latency_histogram(self) -> None:
        body = client.get("/metrics").text
        assert "platform_status_http_request_duration_seconds" in body


class TestStatusEndpoint:
    def test_status_returns_200(self) -> None:
        response = client.get("/status")
        assert response.status_code == 200

    def test_status_reports_healthy(self) -> None:
        assert client.get("/status").json()["status"] == "healthy"
