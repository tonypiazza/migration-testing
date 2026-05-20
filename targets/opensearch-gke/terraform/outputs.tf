output "cluster_name" {
  description = "Generated GKE cluster name"
  value       = local.cluster_name
}

output "opensearch_password" {
  description = "OpenSearch admin password"
  value       = random_password.opensearch_admin.result
  sensitive   = true
}

output "opensearch_endpoint" {
  description = "OpenSearch endpoint IP (HTTPS with self-signed cert)"
  value       = "kubectl get svc os-target-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}
