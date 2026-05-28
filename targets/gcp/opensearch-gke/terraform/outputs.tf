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

output "get_credentials_command" {
  description = "Command to point kubectl at this cluster"
  value       = "gcloud container clusters get-credentials ${local.cluster_name} --location ${module.cluster.location} --project ${var.project_id}"
}

output "connection_info" {
  description = "Target cluster connection details"
  sensitive   = true
  value       = <<-EOT
    export TARGET_USER=admin
    export TARGET_PASSWORD=${random_password.opensearch_admin.result}
    export TARGET_HOST=$(kubectl get svc os-target-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  EOT
}
