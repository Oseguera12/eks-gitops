# platform-status — Regression Test Plan

Black-box regression cases for the `platform-status` service, run against a
real HTTP endpoint (the built container in CI, or a live cluster via
port-forward), never against the Python app in-process. The in-process
unit tests live in `../tests/`; these cases cover what those can't: the
container entrypoint, runtime dependencies, environment wiring, HTTP
semantics, and the contract other systems depend on.

Each case was written as a manual check first (the **Manual steps** column is
exactly what someone would do with `curl` or a browser), then automated in
Playwright. `conftest.py` fails collection if a test references a case ID
that isn't in this table, or if a case marked `automated` has no test.
`scripts/summarize-regression.py` reads the **Status** column to report plan
coverage in `regression-metrics.json`.

| ID | Area | Manual steps | Expected result | Why it matters | Status |
|---|---|---|---|---|---|
| TC-01 | Liveness | `GET /health` | 200, JSON `status: healthy`, numeric `uptime_seconds` ≥ 0 | Kubernetes liveness probe target | automated |
| TC-02 | Readiness | `GET /ready` | 200, JSON `status: ready` | Readiness probe + canary traffic gate | automated |
| TC-03 | Build identity | `GET /info`, read `version` | Matches the image build version (`sha-<7 hex>` in CI and cluster) | Proves which commit is actually running after a GitOps sync | automated |
| TC-04 | Environment wiring | `GET /info` | `environment`, `cluster`, `namespace` match the target environment's test data | Catches a staging pod reporting prod (overlay/patch regressions) | automated |
| TC-05 | Endpoint consistency | `GET /info` then `GET /status` | Same version, environment, cluster, namespace, pod | `/status` is the Argo Rollouts analysis target; it must agree with `/info` | automated |
| TC-06 | Uptime | `GET /health` twice, 1 s apart | Second `uptime_seconds` > first | Detects a restart loop during the run | automated |
| TC-07 | Metrics format | `GET /metrics` | 200, `text/plain`, contains the 3 `platform_status_*` metric families | Prometheus scrape target for the PodMonitor | automated |
| TC-08 | Metrics accuracy | Read request counter for `/ready`, call `/ready` 5×, read again | Counter increased by ≥ 5 | The canary AnalysisTemplate's success-rate query reads this counter | automated |
| TC-09 | Latency budget | `GET /health` 20× | p95 ≤ the environment's budget in test data | Same latency signal the canary analysis gates on | automated |
| TC-10 | Method guard | `POST /health` | 405 | Read-only service: no write verbs accepted | automated |
| TC-11 | CORS policy | Preflight `OPTIONS /info` requesting `POST`; simple `GET /info` with `Origin` | Preflight rejected (400); GET returns `access-control-allow-origin` | Only `GET` is allowed cross-origin | automated |
| TC-12 | Unknown route | `GET /does-not-exist` | 404 JSON `{"detail": "Not Found"}`, no stack trace | No framework internals leak on errors | automated |
| TC-13 | API contract | `GET /openapi.json` | Public paths are exactly `/health`, `/ready`, `/info`, `/status`; `/metrics` hidden; `info.version` matches `/info` | Contract other teams and tools depend on | automated |
| TC-14 | API docs UI | Open `/docs` in a browser | Swagger UI renders and lists all 4 public operations | Human-facing contract; catches a broken docs route or schema | automated |
| TC-15 | Canary routing | During a rollout, request through the Gateway and compare `version` across responses | Mix of old/new versions at roughly the configured weight | Validates Gateway API weighted routing | manual-only |

TC-15 stays manual: it only means something while a rollout is mid-flight,
and the Argo Rollouts analysis already gates on the same traffic split.
