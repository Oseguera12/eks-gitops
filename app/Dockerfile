# syntax=docker/dockerfile:1.7

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

# Build identity is baked into the image so it travels with the signed digest
# through staging → prod promotion. /info and /status report it.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
LABEL org.opencontainers.image.version=${APP_VERSION}

# Non-root user required by OPA Gatekeeper policy and CKS best practices.
RUN useradd --create-home --shell /bin/bash --uid 1001 appuser

WORKDIR /app

# Copy only the installed packages from builder — no pip, no build cache.
COPY --from=builder /install /usr/local

# Copy application source after dependencies to keep the source-change
# layer as thin as possible. Explicit owner/mode so the image doesn't inherit
# the build context's permissions: root-owned and world-readable means UID
# 1001 can run the code but not modify it. --chmod requires BuildKit.
COPY --chown=root:root --chmod=0755 src/ ./src/

# Drop to non-root before process starts.
USER 1001

EXPOSE 8080

# Kubernetes liveness probe polls /health directly via HTTP — no curl/wget
# dependency required in the image.
# Exec form: any non-2xx or connection error raises, which exits 1 (unhealthy).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3)"]

ENTRYPOINT ["python", "-m", "uvicorn", "src.main:app", \
            "--host", "0.0.0.0", \
            "--port", "8080", \
            "--log-level", "info", \
            "--no-access-log"]
