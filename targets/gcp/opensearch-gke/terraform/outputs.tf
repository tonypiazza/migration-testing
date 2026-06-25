output "software" {
  description = "Software name and version"
  value       = "OpenSearch v${var.opensearch_version}"
}

output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "cluster_name" {
  description = "Generated GKE cluster name"
  value       = local.cluster_name
}

output "location" {
  description = "GKE cluster location"
  value       = module.cluster.location
}

output "cluster_ip" {
  description = "OpenSearch load balancer IP"
  value       = data.kubernetes_service.os_http.status[0].load_balancer[0].ingress[0].ip
}

output "cluster_password" {
  description = "OpenSearch admin password"
  sensitive   = true
  value       = random_password.opensearch_admin.result
}

output "vpc_network_self_link" {
  description = "VPC network self-link"
  value       = module.cluster.network_self_link
}

output "vpc_subnet_self_link" {
  description = "Subnet self-link"
  value       = module.cluster.subnet_self_link
}

output "psc_enabled" {
  description = "Whether PSC producer is enabled"
  value       = var.enable_psc
}
