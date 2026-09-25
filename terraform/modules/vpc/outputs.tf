output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "vpc_cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "nat_gateway_ip" {
  description = "Public IP of the NAT Gateway. Used in resume metric: egress IP for all node traffic."
  value       = aws_eip.nat.public_ip
}
