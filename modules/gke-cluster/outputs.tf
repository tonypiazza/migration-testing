output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.main.name
}

output "location" {
  description = "GKE cluster location"
  value       = google_container_cluster.main.location
}

output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "endpoint" {
  description = "GKE cluster endpoint"
  value       = google_container_cluster.main.endpoint
}

output "ca_certificate" {
  description = "GKE cluster CA certificate (base64 encoded)"
  value       = google_container_cluster.main.master_auth[0].cluster_ca_certificate
}

output "network_id" {
  description = "VPC network ID"
  value       = google_compute_network.main.id
}

output "subnet_name" {
  description = "Subnet name"
  value       = google_compute_subnetwork.main.name
}

output "subnet_self_link" {
  description = "Subnet self-link (needed for PSC NAT subnet and peering)"
  value       = google_compute_subnetwork.main.self_link
}

output "network_self_link" {
  description = "VPC network self-link (needed for VPC peering)"
  value       = google_compute_network.main.self_link
}
