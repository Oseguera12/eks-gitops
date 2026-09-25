# Root module — composes VPC, EKS, ECR, and IAM (IRSA) submodules.
#
# Architecture Decision Record: Module Boundaries
#   Each submodule is scoped to a single AWS service domain so that changes
#   to networking, compute, registry, or IAM can be planned and applied
#   independently without affecting the other layers. This mirrors how
#   platform teams structure Terraform at scale.

# ─── Networking ───────────────────────────────────────────────────────────────

module "vpc" {
  source = "./modules/vpc"

  cluster_name         = var.cluster_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

# ─── Compute ──────────────────────────────────────────────────────────────────

module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  node_instance_type = var.node_instance_type
  node_min_size      = var.node_min_size
  node_desired_size  = var.node_desired_size
  node_max_size      = var.node_max_size
}

# ─── Container Registry ───────────────────────────────────────────────────────

module "ecr" {
  source = "./modules/ecr"

  repository_name    = var.ecr_repository_name
  image_count_policy = var.ecr_image_retention_count
}

# ─── IAM — GitHub Actions OIDC ───────────────────────────────────────────────
# Allows GitHub Actions to authenticate to AWS without any long-lived
# access keys. The trust policy scopes the role to this specific repository
# and branch to prevent lateral movement from other GitHub repositories.

module "iam_github_oidc" {
  source = "./modules/iam"

  role_name   = "${var.cluster_name}-github-actions"
  description = "Assumed by GitHub Actions via OIDC - no long-lived credentials."

  trusted_oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
  trusted_oidc_subjects = [
    "repo:${var.github_repo_owner}/${var.github_repo_name}:ref:refs/heads/main",
    "repo:${var.github_repo_owner}/${var.github_repo_name}:pull_request",
  ]

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteMultipartUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeRepositories",
        ]
        Resource = [module.ecr.repository_arn]
      },
      {
        Sid    = "EKSDescribe"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
        ]
        Resource = [module.eks.cluster_arn]
      },
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = ["*"]  # Scoped to state bucket at bootstrap time
      },
      {
        Sid    = "TerraformLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = ["*"]  # Scoped to lock table at bootstrap time
      },
    ]
  })
}

# ─── IAM — External Secrets Operator (IRSA) ──────────────────────────────────
# ESO service account assumes this role to read from AWS Secrets Manager.
# Pod-level identity via IRSA — no secrets in the cluster.

module "iam_external_secrets" {
  source = "./modules/iam"

  role_name   = "${var.cluster_name}-external-secrets"
  description = "IRSA role for External Secrets Operator - Secrets Manager read access."

  trusted_oidc_provider_arn = module.eks.oidc_provider_arn
  trusted_oidc_subjects = [
    "system:serviceaccount:external-secrets:external-secrets"
  ]

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = ["arn:aws:secretsmanager:${var.aws_region}:*:secret:eks-gitops/*"]
      },
    ]
  })
}

# ─── IAM — Cluster Autoscaler (IRSA) ─────────────────────────────────────────

module "iam_cluster_autoscaler" {
  source = "./modules/iam"

  role_name   = "${var.cluster_name}-cluster-autoscaler"
  description = "IRSA role for Cluster Autoscaler - EC2 autoscaling group management."

  trusted_oidc_provider_arn = module.eks.oidc_provider_arn
  trusted_oidc_subjects = [
    "system:serviceaccount:kube-system:cluster-autoscaler"
  ]

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AutoscalerRead"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "AutoscalerWrite"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
    ]
  })
}

# ─── GitHub OIDC Identity Provider ───────────────────────────────────────────
# One OIDC provider per AWS account — created here because this is the
# only repository using GitHub Actions OIDC in this account.

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}
