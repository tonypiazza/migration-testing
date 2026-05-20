output "cluster_name" {
  description = "Generated GKE cluster name"
  value       = local.cluster_name
}

output "elasticsearch_credentials" {
  description = "Run these to set ES_HOST and ES_PASSWORD environment variables"
  value       = <<-EOT
    export ES_PASSWORD=$(kubectl get secret es-source-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
    export ES_HOST=$(kubectl get svc es-source-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  EOT
}
