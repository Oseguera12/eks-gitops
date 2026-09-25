# syntax=docker/dockerfile:1.7
# hadolint global ignore=DL3008,DL3009

# ─── Stage 1: dependency builder ──────────────────────────────────────────────
# Isolated build stage keeps the final image free of build tooling.
FROM python:3.12-slim AS builder

WORKDIR /build

# Copy only the dependency manifest first to maximise layer cache reuse.
# The requirements layer is only invalidated when requirements.txt changes.
COPY requirements.txt .

RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ─── Stage 2: production image ────────────────────────────────────────────────
FROM python:3.12-slim AS final

# Non-root user required by OPA Gatekeeper policy and CKS best practices.
RUN useradd --create-home --shell /bin/bash --uid 1001 appuser

WORKDIR /app

# Copy only the installed packages from builder — no pip, no build cache.
COPY --from=builder /install /usr/local

# Copy application source after dependencies to keep the source-change
# layer as thin as possible.
COPY src/ ./src/

# Drop to non-root before process starts.
USER 1001

EXPOSE 8080

# Kubernetes liveness probe polls /health directly via HTTP — no curl/wget
# dependency required in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" \
    || exit 1

ENTRYPOINT ["python", "-m", "uvicorn", "src.main:app", \
            "--host", "0.0.0.0", \
            "--port", "8080", \
            "--log-level", "info", \
            "--no-access-log"]
