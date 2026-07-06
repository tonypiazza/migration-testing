output "repo_name" {
  description = "Name of the registered snapshot repository."
  value       = var.name
}

output "job_name" {
  description = "Name of the Kubernetes Job that performed the registration."
  value       = kubernetes_job_v1.register.metadata[0].name
}
