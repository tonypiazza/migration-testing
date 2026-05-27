output "cluster_name" {
  description = "Generated GKE cluster name"
  value       = local.cluster_name
}

output "opensearch_password" {
  description = "OpenSearch admin password"
  value       = random_password.opensearch_admin.result
  sensitive   = true
}

output "env_vars" {
  description = "Run: eval \"$(terraform -chdir=targets/opensearch-gke/terraform output -raw env_vars)\""
  sensitive   = true
  value       = <<-EOT
    export TARGET_USER=admin
    export TARGET_PASSWORD=${random_password.opensearch_admin.result}
    export TARGET_HOST=$(kubectl get svc os-target-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  EOT
}
