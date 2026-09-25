# Contributing & Setup Notes

## Local Development Setup

### Python environment

The application lives in `app/`. Use the `pyproject.toml` in that directory as the source of truth for tool configuration — it matches CI exactly.

```bash
cd app/

# Install runtime and dev dependencies
pip install -r requirements.txt -r requirements-dev.txt

# Run tests with coverage
pytest tests/ -v

# Lint
ruff check src/ tests/

# Format check
ruff format --check src/ tests/
```

### Terraform

```bash
cd terraform/

# Initialize with the state backend configured in .env
terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="dynamodb_table=${TF_STATE_DYNAMODB_TABLE}" \
  -backend-config="region=${AWS_REGION}"

# Validate and format check
terraform validate
terraform fmt -check -recursive
```

See `bootstrap/README.md` for creating the state backend before the first `terraform init`.

---

## Required GitHub Actions Secrets

Set these under Settings → Secrets and variables → Actions:

| Secret | Description |
|--------|-------------|
| `AWS_ROLE_ARN` | ARN of the IAM role GitHub Actions assumes via OIDC |
| `SEMGREP_APP_TOKEN` | Semgrep Cloud token (required for SARIF upload) |
| `ARGOCD_SERVER` | ArgoCD server hostname (set after cluster bootstrap) |
| `ARGOCD_AUTH_TOKEN` | ArgoCD API token (masked) |

AWS credentials are never stored as secrets. The pipeline authenticates to AWS via GitHub OIDC — the workflow exchanges a short-lived GitHub token for temporary credentials scoped to `AWS_ROLE_ARN`.

---

## Pipeline Overview

The CI/CD pipeline runs on every push to `main` and on pull requests. Pull requests run only through the test stage — no build or deploy.

| Stage | Job | Runs on | Description |
|-------|-----|---------|-------------|
| 1 | `secret-scan` | PR + main | Gitleaks full-history credential scan |
| 2 | `sast` | PR + main | Semgrep across Python, Docker, K8s, and secrets rulesets |
| 3 | `sca` | PR + main | pip-audit CVE audit on `requirements.txt` |
| 4 | `lint` | PR + main | Hadolint (Dockerfile) + Ruff (Python) |
| 5 | `test` | PR + main | pytest with 80% coverage floor |
| 6 | `iac-scan` | PR + main | Checkov IaC policy scan on `terraform/` |
| 7 | `build-push` | main only | Multi-platform Docker build, push to ECR |
| 8 | `sign` | main only | Cosign keyless image signing via Sigstore |
| 9 | `scan-image` | main only | Trivy vulnerability scan + Syft SBOM generation |
| 10 | `deploy` | main only | Update image digest in `rollout.yaml`, ArgoCD auto-syncs |

Separate workflows handle Terraform (`terraform.yml` — plan on PR, apply on main) and cluster teardown (`destroy.yml` — manual trigger with `DESTROY` confirmation input).

---

## Commit Conventions

Use the conventional commits format:

```
<type>(<scope>): <description>

Types: feat, fix, chore, docs, refactor, test, ci
Scopes: app, terraform, kubernetes, policies, bootstrap

Examples:
  feat(app): add /status endpoint for rollout analysis
  fix(terraform): correct IRSA trust policy condition
  chore(deploy): update platform-status to sha-abc1234 [skip ci]
  docs(bootstrap): add teardown instructions
```

The deploy job commits image digest updates automatically using `[skip ci]` to avoid re-triggering the pipeline.

---

## Checkov Skip Annotations

Two Checkov checks are intentionally skipped in the pipeline (documented in the README ADR section):

| Check | Reason |
|-------|--------|
| `CKV_AWS_130` | EKS endpoint is private-only by design; Checkov flags the absence of a public endpoint as a finding, but private-only is the more secure configuration |
| `CKV2_AWS_12` | VPC default security group restriction is not required when explicit security groups are applied to all resources |

Do not add new skip annotations without documenting the reason in a comment in `.github/workflows/ci-cd.yml` and a corresponding entry in the README ADR section.
