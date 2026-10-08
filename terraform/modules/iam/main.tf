# Generic IAM role with OIDC trust — used for both IRSA and GitHub Actions OIDC.

data "aws_iam_openid_connect_provider" "this" {
  arn = var.trusted_oidc_provider_arn
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.trusted_oidc_provider_arn]
    }

    # Condition keys are "<issuer host>:sub" / ":aud" — the issuer URL without https://.
    condition {
      test     = "StringLike"
      variable = "${replace(data.aws_iam_openid_connect_provider.this.url, "https://", "")}:sub"
      values   = var.trusted_oidc_subjects
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.this.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  description        = var.description
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy" "inline" {
  #checkov:skip=CKV_AWS_355:Only actions with no resource-level support use "*" (ecr:GetAuthorizationToken, autoscaling/ec2 Describe*); autoscaler writes are tag-conditioned.
  name   = "${var.role_name}-policy"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
