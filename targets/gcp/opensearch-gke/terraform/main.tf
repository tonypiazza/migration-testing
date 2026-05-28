resource "random_id" "cluster" {
  byte_length = 2
}

locals {
  cluster_name        = "${var.name_prefix}-${random_id.cluster.hex}"
  admin_password_hash = bcrypt(random_password.opensearch_admin.result)
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

resource "random_password" "opensearch_admin" {
  length  = 24
  special = false
}

resource "helm_release" "opensearch_operator" {
  name             = "opensearch-operator"
  repository       = "https://opensearch-project.github.io/opensearch-k8s-operator/"
  chart            = "opensearch-operator"
  version          = var.operator_version
  namespace        = "opensearch-operator-system"
  create_namespace = true

  set {
    name  = "kubeRbacProxy.image.repository"
    value = "registry.k8s.io/kubebuilder/kube-rbac-proxy"
  }

  depends_on = [module.cluster]
}

resource "time_sleep" "wait_for_crds" {
  create_duration = "30s"

  depends_on = [helm_release.opensearch_operator]
}

resource "helm_release" "opensearch" {
  name             = "opensearch"
  chart            = "${path.module}/../charts/opensearch"
  namespace        = "default"
  create_namespace = false

  set {
    name  = "version"
    value = var.opensearch_version
  }

  set {
    name  = "adminPassword"
    value = random_password.opensearch_admin.result
  }

  set {
    name  = "adminPasswordHash"
    value = local.admin_password_hash
  }

  set {
    name  = "http.allowedCIDRs"
    value = "{${join(",", var.allowed_cidrs)}}"
  }

  lifecycle {
    ignore_changes = [set]
  }

  depends_on = [time_sleep.wait_for_crds]
}
