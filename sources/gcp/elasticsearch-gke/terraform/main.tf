resource "random_id" "cluster" {
  byte_length = 2
}

locals {
  cluster_name = "${var.name_prefix}-${random_id.cluster.hex}"
}

data "google_client_config" "default" {}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "kubernetes" {
  host                   = "https://${module.cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.cluster.ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.cluster.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.cluster.ca_certificate)
  }
}

module "cluster" {
  source = "../../../../modules/gke-cluster"

  project_id   = var.project_id
  region       = var.region
  zone         = var.zone
  cluster_name = local.cluster_name
  machine_type = var.machine_type
  node_count   = var.node_count
  disk_size_gb = var.disk_size_gb
}

resource "helm_release" "eck_operator" {
  name             = "elastic-operator"
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = var.eck_version
  namespace        = "elastic-system"
  create_namespace = true

  depends_on = [module.cluster]
}

resource "helm_release" "elasticsearch" {
  name             = "elasticsearch"
  chart            = "${path.module}/../charts/elasticsearch"
  namespace        = "default"
  create_namespace = false

  set {
    name  = "version"
    value = var.elasticsearch_version
  }

  set {
    name  = "http.allowedCIDRs"
    value = "{${join(",", var.allowed_cidrs)}}"
  }

  set {
    name  = "http.psc.enabled"
    value = tostring(var.enable_psc)
  }

  set {
    name  = "http.psc.subnet"
    value = var.enable_psc ? module.cluster.subnet_name : ""
  }

  set {
    name  = "http.psc.natSubnet"
    value = var.enable_psc ? google_compute_subnetwork.psc[0].id : ""
  }

  set {
    name  = "http.psc.consumerProjectIds"
    value = "{${join(",", var.psc_consumer_project_ids)}}"
  }

  depends_on = [helm_release.eck_operator]
}

resource "google_compute_subnetwork" "psc" {
  count = var.enable_psc ? 1 : 0

  name          = "${local.cluster_name}-psc-nat"
  project       = var.project_id
  region        = var.region
  network       = module.cluster.network_id
  ip_cidr_range = "10.100.0.0/24"
  purpose       = "PRIVATE_SERVICE_CONNECT"
}
