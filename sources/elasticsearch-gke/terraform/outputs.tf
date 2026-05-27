output "cluster_name" {
  description = "Generated GKE cluster name"
  value       = local.cluster_name
}

output "env_vars" {
  description = "Run: eval \"$(terraform -chdir=sources/elasticsearch-gke/terraform output -raw env_vars)\""
  value       = <<-EOT
    export SOURCE_USER=elastic
    export SOURCE_PASSWORD=$(kubectl get secret es-source-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
    export SOURCE_HOST=$(kubectl get svc es-source-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  EOT
}

output "psc_service_attachment" {
  description = "Retrieve PSC service attachment URI with: kubectl get serviceattachment es-source-psc -o jsonpath='{.status.serviceAttachmentURI}'"
  value       = var.enable_psc ? "kubectl get serviceattachment es-source-psc -o jsonpath='{.status.serviceAttachmentURI}'" : null
}
