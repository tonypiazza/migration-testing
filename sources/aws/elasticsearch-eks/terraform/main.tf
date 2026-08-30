resource "random_id" "cluster" {
  byte_length = 2
}

locals {
  cluster_name = "${var.name_prefix}-${random_id.cluster.hex}"
  # Tag the ES Service applies to its NLB, used by data.aws_lb below to wire PrivateLink.
  nlb_tag_key   = "es-privatelink"
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
# Snapshot bucket — use the caller-supplied bucket, or create one when none is given.
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

locals {
  create_snapshot_bucket = var.snapshot_bucket == ""
  # Bucket names are global and must be lowercase; the account ID keeps the generated name unique.
  generated_snapshot_bucket = lower("${local.cluster_name}-es-snapshots-${data.aws_caller_identity.current.account_id}")
  snapshot_bucket           = local.create_snapshot_bucket ? aws_s3_bucket.snapshots[0].bucket : var.snapshot_bucket
}

resource "aws_s3_bucket" "snapshots" {
  count = local.create_snapshot_bucket ? 1 : 0

  bucket = local.generated_snapshot_bucket
  # Test/demo environment: let `destroy` remove the bucket even if it holds snapshots.
  force_destroy = true

  tags = {
    Name    = local.generated_snapshot_bucket
    Cluster = local.cluster_name
  }
}

resource "aws_s3_bucket_public_access_block" "snapshots" {
  count = local.create_snapshot_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.snapshots[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IRSA — Elasticsearch S3 snapshots
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "es_snapshots" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
      "s3:ListBucketVersions",
    ]
    resources = ["arn:aws:s3:::${local.snapshot_bucket}"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["arn:aws:s3:::${local.snapshot_bucket}/*"]
  }
}

resource "aws_iam_policy" "es_snapshots" {
  name   = "${local.cluster_name}-es-snapshots"
  policy = data.aws_iam_policy_document.es_snapshots.json
}

module "es_snapshots_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name = "${local.cluster_name}-es-snapshots"

  policies = {
    snapshots = aws_iam_policy.es_snapshots.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.cluster.oidc_provider_arn
      namespace_service_accounts = ["default:es-source"]
    }
  }
}

# ---------------------------------------------------------------------------
# Default StorageClass — EKS ships gp2 but does not mark it default, so PVCs with no
# storageClassName (ECK's volumeClaimTemplates) never bind. Backed by the EBS CSI addon.
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

# ---------------------------------------------------------------------------
# ECK operator + Elasticsearch
# ---------------------------------------------------------------------------
resource "helm_release" "eck_operator" {
  name             = "elastic-operator"
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = var.eck_version
  namespace        = "elastic-system"
  create_namespace = true

  # The LB controller chart registers a mutating webhook for every Service in the cluster;
  # creating the operator's webhook Service before the controller pods are ready fails with
  # "no endpoints available for service aws-load-balancer-webhook-service".
  depends_on = [module.cluster, helm_release.lb_controller]
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
    name  = "serviceAccountName"
    value = "es-source"
  }

  set {
    name  = "irsaRoleArn"
    value = module.es_snapshots_irsa.arn
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

  # Uninstall waits on ECK to clear its finalizers on the Elasticsearch CR, which can
  # outlast helm's 300s default and fail with "context deadline exceeded".
  timeout = 900

  depends_on = [helm_release.eck_operator, helm_release.lb_controller, kubernetes_storage_class_v1.gp3]
}

# ---------------------------------------------------------------------------
# PrivateLink (AWS analog of GCP PSC ServiceAttachment)
# ---------------------------------------------------------------------------
# Give the LB controller time to reconcile the internal NLB before discovering it.
resource "time_sleep" "wait_for_nlb" {
  count           = var.enable_psc ? 1 : 0
  depends_on      = [helm_release.elasticsearch]
  create_duration = "180s"
}

# Discover the controller-created NLB by the tag the ES Service set. This is an AWS API
# lookup (no kubernetes data source) — the "no k8s in terraform" property holds.
data "aws_lb" "es_nlb" {
  count = var.enable_psc ? 1 : 0

  tags = {
    (local.nlb_tag_key) = local.nlb_tag_value
  }

  depends_on = [time_sleep.wait_for_nlb]
}

resource "aws_vpc_endpoint_service" "es" {
  count = var.enable_psc ? 1 : 0

  acceptance_required        = false
  network_load_balancer_arns = [data.aws_lb.es_nlb[0].arn]
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
  description       = "Elasticsearch HTTP from peered migration VPC"
}

# ---------------------------------------------------------------------------
# Snapshot repository registration (engine/cloud-agnostic shared module, type = s3).
# Runs in-cluster over service DNS, so it works whether the NLB is public or internal.
# ---------------------------------------------------------------------------
module "snapshot_repo" {
  source = "../../../../modules/snapshot-repo"

  name               = "default"
  endpoint           = "https://es-source-es-http.default.svc:9200"
  namespace          = "default"
  username           = "elastic"
  credentials_secret = "es-source-es-elastic-user"
  password_key       = "elastic"
  repo_type          = "s3"
  repo_settings = {
    bucket    = local.snapshot_bucket
    base_path = var.snapshot_base_path
  }

  depends_on = [helm_release.elasticsearch]
}
