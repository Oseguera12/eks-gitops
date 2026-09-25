# Bootstrap — Terraform State Backend

`setup.sh` is a one-time script that provisions the AWS resources required for the Terraform remote state backend. It must be run once from a local workstation before the first `terraform init`. After this, all infrastructure management flows through GitHub Actions using OIDC — no long-lived AWS credentials are stored anywhere.

The state backend resources are intentionally **not** managed by Terraform. If they were, a failed state write could leave Terraform unable to recover its own state. They outlive the cluster and must be deleted manually only when you are permanently done with the project.

## Resources Created

| Resource | Name pattern | Purpose |
|----------|-------------|---------|
| S3 bucket | `eks-gitops-tfstate-<account-id>` | Stores `terraform.tfstate` with versioning and AES-256 encryption |
| DynamoDB table | `eks-gitops-tfstate-lock` | Prevents concurrent `terraform apply` runs from corrupting state |

Both resources use pay-per-request / pay-per-GB pricing. Combined cost is under $1/month at this project's scale.

## Prerequisites

- AWS CLI installed and configured (`aws configure` or environment variables)
- IAM permissions to create S3 buckets, configure bucket policies, and create DynamoDB tables
- `AWS_REGION` and `AWS_ACCOUNT_ID` set as environment variables

## Usage

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=123456789012

chmod +x bootstrap/setup.sh
./bootstrap/setup.sh
```

The script outputs the exact variable values to add to your `.env` file and GitHub Actions secrets.

## What the Script Does

1. Creates an S3 bucket named `eks-gitops-tfstate-<account-id>` with:
   - Versioning enabled (allows state recovery from accidental corruption)
   - AES-256 server-side encryption
   - All public access blocked
2. Creates a DynamoDB table `eks-gitops-tfstate-lock` with pay-per-request billing for state locking.

The DynamoDB create call is idempotent — if the table already exists, the script continues without error.

## After Running

Add the following to your `.env` (copy from `.env.example`) and as GitHub Actions repository secrets:

```
TF_STATE_BUCKET=eks-gitops-tfstate-<your-account-id>
TF_STATE_DYNAMODB_TABLE=eks-gitops-tfstate-lock
AWS_REGION=us-east-1
```

Then initialize Terraform:

```bash
cd terraform/
terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="dynamodb_table=${TF_STATE_DYNAMODB_TABLE}" \
  -backend-config="region=${AWS_REGION}"
```

## Teardown

These resources are **not** deleted by `terraform destroy`. They persist to preserve the state file so the cluster can be rebuilt. Delete them manually only when permanently done with this project:

```bash
# Empty the bucket first (required before deletion)
aws s3 rm "s3://eks-gitops-tfstate-${AWS_ACCOUNT_ID}" --recursive

# Delete the bucket
aws s3api delete-bucket \
  --bucket "eks-gitops-tfstate-${AWS_ACCOUNT_ID}" \
  --region "${AWS_REGION}"

# Delete the DynamoDB table
aws dynamodb delete-table \
  --table-name eks-gitops-tfstate-lock \
  --region "${AWS_REGION}"
```

Ongoing cost while retained: under $1/month.
