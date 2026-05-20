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

  depends_on = [helm_release.eck_operator]
}
