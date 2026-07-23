output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "location" {
  description = "Cluster location (region) — mirrors gke-cluster's location output for cluster.sh"
  value       = var.region
}

output "endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "ca_certificate" {
  description = "EKS cluster CA certificate (base64 encoded)"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnets
}

output "private_route_table_ids" {
  description = "Private route table IDs (for VPC peering routes)"
  value       = module.vpc.private_route_table_ids
}

output "node_security_group_id" {
  description = "EKS node security group ID (for peer ingress rules)"
  value       = module.eks.node_security_group_id
}
