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
  description = "Source cluster connection details"
  sensitive   = true
  value       = <<-EOT
    export SOURCE_USER=elastic
    export SOURCE_PASSWORD=$(kubectl get secret es-source-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
    export SOURCE_HOST=$(kubectl get svc es-source-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  EOT
}

output "psc_service_attachment" {
  description = "Retrieve PSC service attachment URI"
  value       = var.enable_psc ? "kubectl get serviceattachment es-source-psc -o jsonpath='{.status.serviceAttachmentURI}'" : null
}
