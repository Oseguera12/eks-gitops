# Remote state backend: S3 + DynamoDB.
#
# The bucket and table must exist before running `terraform init`.
# Run `bootstrap/setup.sh` once to create them.
#
# Backend configuration is intentionally kept as a partial config so that
# the bucket name (which contains the account ID) is injected at init time
# rather than hardcoded here. This keeps the file safe to commit.
#
# Usage:
#   terraform init \
#     -backend-config="bucket=${TF_STATE_BUCKET}" \
#     -backend-config="dynamodb_table=${TF_STATE_DYNAMODB_TABLE}" \
#     -backend-config="region=${AWS_REGION}"

terraform {
  backend "s3" {
    key     = "eks-gitops/terraform.tfstate"
    encrypt = true
    # bucket, dynamodb_table, and region are injected via -backend-config
    # in the GitHub Actions workflow — not hardcoded here.
  }
}
