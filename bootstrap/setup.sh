#!/usr/bin/env bash
# bootstrap/setup.sh
#
# One-time setup script that creates the S3 bucket and DynamoDB table used
# as the Terraform remote state backend.
#
# Run this ONCE from a workstation with AWS credentials before the first
# `terraform init`. After this, all subsequent infrastructure management
# goes through GitHub Actions with OIDC — no long-lived credentials needed.
#
# Usage:
#   AWS_REGION=us-east-1 AWS_ACCOUNT_ID=123456789012 ./bootstrap/setup.sh

set -euo pipefail

: "${AWS_REGION:?AWS_REGION must be set}"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID must be set}"

BUCKET_NAME="eks-gitops-tfstate-${AWS_ACCOUNT_ID}"
TABLE_NAME="eks-gitops-tfstate-lock"

echo "==> Creating S3 state bucket: ${BUCKET_NAME}"
if [[ "${AWS_REGION}" == "us-east-1" ]]; then
  # us-east-1 does not accept a LocationConstraint
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${AWS_REGION}"
else
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"
fi

echo "==> Enabling versioning on ${BUCKET_NAME}"
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "==> Enabling AES-256 server-side encryption"
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

echo "==> Blocking all public access to state bucket"
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "==> Creating DynamoDB lock table: ${TABLE_NAME}"
aws dynamodb create-table \
  --table-name "${TABLE_NAME}" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "${AWS_REGION}" || true  # idempotent — ignore if already exists

echo ""
echo "State backend ready."
echo "Add the following to your .env (and as GitHub Actions secrets):"
echo ""
echo "  TF_STATE_BUCKET=${BUCKET_NAME}"
echo "  TF_STATE_DYNAMODB_TABLE=${TABLE_NAME}"
echo "  AWS_REGION=${AWS_REGION}"
