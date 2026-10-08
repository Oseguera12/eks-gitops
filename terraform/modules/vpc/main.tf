# VPC module — three-tier networking for EKS.
#
# Architecture:
#   Public subnets  — internet-facing load balancers only (no EKS nodes)
#   Private subnets — EKS managed node groups, all egress via single NAT Gateway
#
# ADR: Single NAT Gateway
#   A production setup uses one NAT Gateway per AZ for HA. For this portfolio
#   project a single NAT Gateway is used to reduce cost from ~$99/mo to ~$33/mo.
#   The tradeoff (AZ-level egress dependency) is explicitly accepted for a
#   non-production workload. Switching to per-AZ NAT requires adding two
#   aws_eip + aws_nat_gateway resources and updating the private route tables.

# ─── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  #checkov:skip=CKV2_AWS_11:Ephemeral demo VPC (destroyed every session); EKS control-plane audit logs are enabled instead. Listed under Future Improvements.
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # Required for EKS node-to-API communication

  tags = {
    Name                                        = var.cluster_name
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ─── Internet Gateway ─────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# ─── Public Subnets ───────────────────────────────────────────────────────────

# Public subnets host only the NAT Gateway and internet-facing load balancers;
# nodes run in the private subnets below.
# nosemgrep: terraform.aws.security.aws-subnet-has-public-ip-address.aws-subnet-has-public-ip-address
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # EKS uses this tag to identify subnets where external-facing LBs are created
    "kubernetes.io/role/elb" = "1"
  }
}

# ─── Private Subnets ──────────────────────────────────────────────────────────

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                        = "${var.cluster_name}-private-${var.availability_zones[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # EKS uses this tag to identify subnets where internal LBs are created
    "kubernetes.io/role/internal-elb" = "1"
    # Cluster Autoscaler uses this tag to identify which ASGs to manage
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }
}

# ─── NAT Gateway (single, in first public subnet) ────────────────────────────

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = "${var.cluster_name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# ─── Route Tables ─────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.cluster_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
