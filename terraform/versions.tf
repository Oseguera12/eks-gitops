terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Upgraded from ~> 5.80 to ~> 6.0 (current stable: 6.52.0, June 2026).
      # Breaking changes reviewed before upgrading:
      #   - OpsWorks Stacks, SimpleDB, Worklink removed: none used in this stack.
      #   - Nullable boolean validation: attributes require true/false, not 0/1.
      #     Reviewed all resource configurations — no 0/1 boolean patterns present.
      #   - S3 global endpoint deprecation: the state bucket is created by
      #     bootstrap/setup.sh (not Terraform), so no aws_s3_bucket resource is
      #     affected.
      #   - aws_ami data source requires explicit owners: no aws_ami usage in stack.
      # The ~> 6.0 constraint allows any 6.x patch without allowing 7.0.
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "github.com/Oseguera12/eks-gitops"
    }
  }
}
