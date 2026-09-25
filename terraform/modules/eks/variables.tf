variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.32"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Private subnets for EKS node groups."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets — used for the cluster endpoint (if public) and load balancers."
  type        = list(string)
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}
