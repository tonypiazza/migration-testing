output "software" {
  description = "Software name and version"
  value       = "Elasticsearch v${var.elasticsearch_version}"
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "cluster_name" {
  description = "Generated EKS cluster name"
  value       = local.cluster_name
}

output "location" {
  description = "Cluster location (region) — consumed by cluster.sh"
  value       = module.cluster.location
}

output "psc_enabled" {
  description = "Whether PrivateLink (private networking) is enabled"
  value       = var.enable_psc
}

output "privatelink_service_name" {
  description = "PrivateLink VPC endpoint service name to give the migration consumer as source_connectivity.service_attachment. Empty when enable_psc = false."
  value       = var.enable_psc ? aws_vpc_endpoint_service.es[0].service_name : ""
}

output "vpc_id" {
  description = "VPC ID (peer must target this for the reciprocal peering)"
  value       = module.cluster.vpc_id
}

output "peering_connection_id" {
  description = "VPC peering connection ID (empty when peering is not enabled). The peer must accept it."
  value       = var.vpc_peering.mode == "enabled" ? aws_vpc_peering_connection.migration[0].id : ""
}
