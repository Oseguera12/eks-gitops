output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint. Used by kubectl and ArgoCD."
  value       = module.eks.cluster_endpoint
  sensitive   = false
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for the cluster. Used to create IRSA trust policies."
  value       = module.eks.cluster_oidc_issuer_url
}

output "ecr_repository_url" {
  description = "Full ECR repository URL for the platform-status image."
  value       = module.ecr.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN that GitHub Actions assumes via OIDC. Set as ACTIONS_ROLE_ARN secret."
  value       = module.iam_github_oidc.role_arn
}

output "external_secrets_role_arn" {
  description = "IRSA role ARN for the External Secrets Operator service account."
  value       = module.iam_external_secrets.role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for the Cluster Autoscaler service account."
  value       = module.iam_cluster_autoscaler.role_arn
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs where EKS nodes run."
  value       = module.vpc.private_subnet_ids
}

output "kubeconfig_command" {
  description = "AWS CLI command to update local kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
