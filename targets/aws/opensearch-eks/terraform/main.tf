resource "random_id" "cluster" {
  byte_length = 2
}

locals {
  cluster_name        = "${var.name_prefix}-${random_id.cluster.hex}"
  admin_password_hash = bcrypt(random_password.opensearch_admin.result)
  # Tag the OpenSearch Service applies to its NLB, used by data.aws_lb below to wire PrivateLink.
  nlb_tag_key   = "os-privatelink"
  nlb_tag_value = local.cluster_name
}

provider "aws" {
  region = var.region
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.cluster.cluster_name
}

provider "kubernetes" {
  host                   = module.cluster.endpoint
  cluster_ca_certificate = base64decode(module.cluster.ca_certificate)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.endpoint
    cluster_ca_certificate = base64decode(module.cluster.ca_certificate)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

module "cluster" {
  source = "../../../../modules/eks-cluster"

  cluster_name       = local.cluster_name
  region             = var.region
  kubernetes_version = var.kubernetes_version
  instance_type      = var.instance_type
  node_count         = var.node_count
  disk_size_gb       = var.disk_size_gb
}

# ---------------------------------------------------------------------------
# IRSA — AWS Load Balancer Controller
# ---------------------------------------------------------------------------
module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                                   = "${local.cluster_name}-lb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.cluster.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "kubernetes_service_account" "lb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.lb_controller_irsa.arn
    }
  }

  depends_on = [module.cluster]
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_version
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.cluster.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.cluster.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  # The module dependency keeps the IRSA policy attachment alive during destroy: without
  # it Terraform detaches the controller's IAM policy immediately (nothing references it),
  # leaving the controller unable to delete the NLB, so the Service finalizer never clears.
  depends_on = [kubernetes_service_account.lb_controller, module.lb_controller_irsa]
}

# ---------------------------------------------------------------------------
# Default StorageClass — EKS ships gp2 but does not mark it default, so PVCs with no
# storageClassName (the operator's volumeClaimTemplates) never bind. Backed by the EBS
# CSI addon.
# ---------------------------------------------------------------------------
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }

  depends_on = [module.cluster]
}

resource "random_password" "opensearch_admin" {
  length  = 24
  special = false
}

# ---------------------------------------------------------------------------
# cert-manager + OpenSearch operator + OpenSearch
# ---------------------------------------------------------------------------
# cert-manager: the OpenSearch operator (>= 2.8.0) webhook issues its serving cert via
# cert-manager (webhook.certManager.enabled defaults true), so its CRDs must exist first.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  # Install cert-manager's CRDs (Certificate, Issuer, ...) with the chart.
  set {
    name  = "crds.enabled"
    value = "true"
  }

  # The LB controller chart registers a mutating webhook for every Service in the cluster;
  # creating cert-manager's Services before the controller pods are ready fails with
  # "no endpoints available for service aws-load-balancer-webhook-service".
  depends_on = [module.cluster, helm_release.lb_controller]
}

# Give the cert-manager webhook time to become ready before the operator install
# renders Certificate/Issuer resources that the webhook must admit.
resource "time_sleep" "wait_for_cert_manager" {
  create_duration = "60s"

  depends_on = [helm_release.cert_manager]
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

  depends_on = [module.cluster, time_sleep.wait_for_cert_manager]
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
    name  = "http.internal"
    value = tostring(var.enable_psc)
  }

  set {
    name  = "http.allowedCIDRs"
    value = "{${join(",", var.allowed_cidrs)}}"
  }

  set {
    name  = "http.nlbTag"
    value = "${local.nlb_tag_key}=${local.nlb_tag_value}"
  }

  set {
    name  = "http.dnsName"
    value = var.psc_dns_name
  }

  lifecycle {
    ignore_changes = [set]
  }

  depends_on = [time_sleep.wait_for_crds, helm_release.lb_controller, kubernetes_storage_class_v1.gp3]
}

# ---------------------------------------------------------------------------
# PrivateLink (AWS analog of GCP PSC ServiceAttachment)
# ---------------------------------------------------------------------------
# Give the LB controller time to reconcile the internal NLB before discovering it.
resource "time_sleep" "wait_for_nlb" {
  count           = var.enable_psc ? 1 : 0
  depends_on      = [helm_release.opensearch]
  create_duration = "180s"
}

# Discover the controller-created NLB by the tag the OpenSearch Service set. This is an
# AWS API lookup (no kubernetes data source) — the "no k8s in terraform" property holds.
data "aws_lb" "os_nlb" {
  count = var.enable_psc ? 1 : 0

  tags = {
    (local.nlb_tag_key) = local.nlb_tag_value
  }

  depends_on = [time_sleep.wait_for_nlb]
}

resource "aws_vpc_endpoint_service" "os" {
  count = var.enable_psc ? 1 : 0

  acceptance_required        = false
  network_load_balancer_arns = [data.aws_lb.os_nlb[0].arn]
  allowed_principals         = var.privatelink_allowed_principals
}

# ---------------------------------------------------------------------------
# VPC peering with the migration cluster (AWS analog of google_compute_network_peering)
# ---------------------------------------------------------------------------
resource "aws_vpc_peering_connection" "migration" {
  count = var.vpc_peering.mode == "enabled" ? 1 : 0

  vpc_id        = module.cluster.vpc_id
  peer_vpc_id   = var.vpc_peering.peer_vpc_id
  peer_owner_id = var.vpc_peering.peer_owner_id
  peer_region   = var.vpc_peering.peer_region
  auto_accept   = false

  tags = {
    Name = "${local.cluster_name}-peer-migration"
  }
}

resource "aws_route" "peer" {
  count = var.vpc_peering.mode == "enabled" && length(var.vpc_peering.peer_cidrs) > 0 ? length(module.cluster.private_route_table_ids) * length(var.vpc_peering.peer_cidrs) : 0

  route_table_id            = module.cluster.private_route_table_ids[floor(count.index / length(var.vpc_peering.peer_cidrs))]
  destination_cidr_block    = var.vpc_peering.peer_cidrs[count.index % length(var.vpc_peering.peer_cidrs)]
  vpc_peering_connection_id = aws_vpc_peering_connection.migration[0].id
}

resource "aws_security_group_rule" "peer_ingress" {
  count = var.vpc_peering.mode == "enabled" && length(var.vpc_peering.peer_cidrs) > 0 ? 1 : 0

  type              = "ingress"
  from_port         = 9200
  to_port           = 9200
  protocol          = "tcp"
  cidr_blocks       = var.vpc_peering.peer_cidrs
  security_group_id = module.cluster.node_security_group_id
  description       = "OpenSearch HTTP from peered migration VPC"
}
