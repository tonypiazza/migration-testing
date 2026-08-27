output "software" {
  description = "Software name and version"
  value       = "OpenSearch v${var.opensearch_version} (Amazon OpenSearch Service)"
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "cluster_name" {
  description = "Generated OpenSearch Service domain name"
  value       = local.cluster_name
}

output "location" {
  description = "Cluster location (region) — consumed by cluster.sh"
  value       = var.region
}

output "cluster_endpoint" {
  description = "Domain endpoint hostname (HTTPS on port 443). Only reachable from inside the VPC / via VPC endpoints when the domain is VPC-resident."
  value       = module.opensearch.domain_endpoint
}

output "dashboards_endpoint" {
  description = "OpenSearch Dashboards endpoint hostname"
  value       = module.opensearch.domain_dashboard_endpoint
}

output "cluster_user" {
  description = "Fine-grained access control master user name"
  value       = var.master_user_name
}

output "cluster_password" {
  description = "Fine-grained access control master user password"
  sensitive   = true
  value       = random_password.opensearch_admin.result
}

output "domain_arn" {
  description = "Domain ARN. With enable_psc = true, the migration consumer creates an OpenSearch-managed VPC endpoint (aws_opensearch_vpc_endpoint) against this ARN — it plays the role of the PSC service attachment / PrivateLink service name."
  value       = module.opensearch.domain_arn
}

output "psc_enabled" {
  description = "Whether private networking (VPC-resident domain + OpenSearch-managed VPC endpoint authorization) is enabled"
  value       = var.enable_psc
}

output "vpc_id" {
  description = "VPC ID when the domain is VPC-resident (peer must target this for the reciprocal peering); empty for a public domain"
  value       = local.in_vpc ? module.vpc[0].vpc_id : ""
}

output "peering_connection_id" {
  description = "VPC peering connection ID (empty when peering is not enabled). The peer must accept it."
  value       = var.vpc_peering.mode == "enabled" ? aws_vpc_peering_connection.migration[0].id : ""
}
