resource "google_compute_network" "main" {
  name                    = "${local.cluster_name}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${local.cluster_name}-subnet"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = "10.0.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.4.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.8.0.0/20"
  }
}

resource "google_compute_subnetwork" "psc" {
  count = var.enable_psc ? 1 : 0

  name          = "${local.cluster_name}-psc-nat"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = "10.100.0.0/24"
  purpose       = "PRIVATE_SERVICE_CONNECT"
}
