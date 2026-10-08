variable "aws_region" {
  description = "AWS region where all resources are created."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name used for the EKS cluster and all associated resources."
  type        = string
  default     = "eks-gitops"
}

variable "environment" {
  description = "Deployment environment label (e.g. prod, staging)."
  type        = string
  default     = "prod"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  # 1.32 left EKS standard support on 2026-03-23; running it now bills the
  # control plane at the extended-support rate ($0.60/hr vs $0.10/hr).
  # 1.35 is in standard support until 2027-03-27. The three managed addons below
  # (vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver) omit addon_version, so
  # AWS auto-selects the latest addon build compatible with this cluster
  # version — no addon pins needed to move with this bump.
  default = "1.35"
}

# ─── VPC ──────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to deploy subnets into. Must contain exactly 3 values."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Exactly 3 availability zones are required."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the 3 public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the 3 private subnets (one per AZ). EKS nodes run here."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}

# ─── EKS Nodes ────────────────────────────────────────────────────────────────

variable "node_instance_type" {
  description = "EC2 instance type for managed node group workers."
  type        = string
  # 2 vCPU / 4 GB — sized for the full platform stack (ArgoCD, Prometheus
  # stack, Gatekeeper, Falco, Argo Rollouts, Cluster Autoscaler, ESO) to
  # schedule cleanly. t3.micro (1 GB) is Free Tier eligible but too small —
  # combined pod memory requests exceed what 2-3 micro nodes can allocate.
  default = "t3.medium"
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_desired_size" {
  description = "Desired number of nodes at cluster creation."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of nodes the Cluster Autoscaler can scale to."
  type        = number
  default     = 3
}

# ─── Container Registry ───────────────────────────────────────────────────────

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the platform-status image."
  type        = string
  default     = "platform-status"
}

variable "ecr_image_retention_count" {
  description = "Number of tagged images to retain per repository."
  type        = number
  default     = 10
}

# ─── GitHub OIDC ──────────────────────────────────────────────────────────────

variable "github_repo_owner" {
  description = "GitHub username that owns the repository."
  type        = string
  default     = "Oseguera12"
}

variable "github_repo_name" {
  description = "GitHub repository name (without owner prefix)."
  type        = string
  default     = "eks-gitops"
}
