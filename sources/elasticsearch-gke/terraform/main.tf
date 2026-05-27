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
  host                   = "https://${google_container_cluster.main.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.main.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.main.master_auth[0].cluster_ca_certificate)
  }
}

resource "helm_release" "eck_operator" {
  name             = "elastic-operator"
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = var.eck_version
  namespace        = "elastic-system"
  create_namespace = true

  depends_on = [google_container_node_pool.main]
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
    value = var.enable_psc ? google_compute_subnetwork.main.name : ""
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
