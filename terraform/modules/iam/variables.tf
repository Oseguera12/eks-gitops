# Generic IRSA / OIDC role module.
# Accepts either an EKS cluster OIDC provider or GitHub's OIDC provider ARN.

variable "role_name" {
  type = string
}

variable "description" {
  type    = string
  default = ""
}

variable "trusted_oidc_provider_arn" {
  description = "ARN of the OIDC identity provider that may assume this role."
  type        = string
}

variable "trusted_oidc_subjects" {
  description = "List of OIDC subject claim values allowed to assume this role."
  type        = list(string)
}

variable "policy_json" {
  description = "JSON-encoded IAM policy document to attach inline to the role."
  type        = string
}
