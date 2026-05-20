resource "google_container_cluster" "main" {
  name     = local.cluster_name
  project  = var.project_id
  location = var.zone != null ? var.zone : var.region

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  initial_node_count       = 1
  remove_default_node_pool = true

  deletion_protection = false
}

resource "google_container_node_pool" "main" {
  name     = "${local.cluster_name}-pool"
  project  = var.project_id
  location = google_container_cluster.main.location
  cluster  = google_container_cluster.main.name

  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_write",
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }
}

resource "null_resource" "kubeconfig" {
  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${local.cluster_name} --${var.zone != null ? "zone ${var.zone}" : "region ${var.region}"} --project ${var.project_id}"
  }

  depends_on = [google_container_node_pool.main]
}
