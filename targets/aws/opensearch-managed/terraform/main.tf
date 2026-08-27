resource "random_id" "cluster" {
  byte_length = 2
}

locals {
  # Amazon OpenSearch Service domain name (3-28 chars, lowercase, starts with a letter).
  cluster_name = "${var.name_prefix}-${random_id.cluster.hex}"

  # The domain must live inside a VPC for either private-networking mode: OpenSearch-managed
  # VPC endpoints (enable_psc) and VPC peering both require a VPC-resident domain. A public
  # domain (the default) needs no VPC at all.
  in_vpc = var.enable_psc || var.vpc_peering.mode == "enabled"

  # OpenSearch-managed VPC endpoints deliver consumer traffic to the domain ENIs from
  # addresses we cannot know ahead of time, so in PrivateLink mode the domain SG allows 443
  # from anywhere — the VPC itself (no IGW, no public endpoint) is the boundary. In plain
  # peering mode restrict to this VPC and the peer CIDRs.
  sg_ingress_cidrs = var.enable_psc ? ["0.0.0.0/0"] : concat([var.vpc_cidr], var.vpc_peering.peer_cidrs)
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "random_password" "opensearch_admin" {
  # Fine-grained access control requires >= 8 chars with upper, lower, digit, and special.
  # '$' is deliberately excluded from the special set so the password can be pasted into
  # shell commands without quoting surprises.
  length           = 24
  special          = true
  override_special = "!#%^*()-_=+"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

# ---------------------------------------------------------------------------
# VPC (only for VPC-resident domains). Private subnets only: the domain needs no egress
# and nothing here needs a NAT gateway or internet gateway.
# ---------------------------------------------------------------------------
module "vpc" {
  count = local.in_vpc ? 1 : 0

  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for k in range(3) : cidrsubnet(var.vpc_cidr, 4, k)]

  enable_nat_gateway = false
}

# ---------------------------------------------------------------------------
# Amazon OpenSearch Service domain
# ---------------------------------------------------------------------------
module "opensearch" {
  source  = "terraform-aws-modules/opensearch/aws"
  version = "~> 2.11"

  domain_name    = local.cluster_name
  engine_version = "OpenSearch_${var.opensearch_version}"

  cluster_config = {
    instance_type            = var.instance_type
    instance_count           = var.node_count
    dedicated_master_enabled = var.dedicated_master_enabled
    dedicated_master_count   = var.dedicated_master_enabled ? 3 : null
    dedicated_master_type    = var.dedicated_master_enabled ? var.dedicated_master_type : null
    zone_awareness_enabled   = var.availability_zone_count > 1
    zone_awareness_config = {
      availability_zone_count = var.availability_zone_count
    }
  }

  ebs_options = {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.disk_size_gb
  }

  # Fine-grained access control with the internal user database: basic auth with a
  # master user/password, same shape as the GKE target's admin user. FGAC requires
  # encryption at rest, node-to-node encryption, and enforced HTTPS (module defaults).
  advanced_security_options = {
    enabled                        = true
    anonymous_auth_enabled         = false
    internal_user_database_enabled = true
    master_user_options = {
      master_user_name     = var.master_user_name
      master_user_password = random_password.opensearch_admin.result
    }
  }

  # Domain access policy. With FGAC the policy only gates network-level access; the
  # internal user database does authentication. Public domains are restricted by source
  # IP; VPC-resident domains rely on the VPC/SG boundary instead.
  access_policy_statements = {
    allow_all = {
      effect  = "Allow"
      actions = ["es:*"]
      principals = [{
        type        = "AWS"
        identifiers = ["*"]
      }]
      conditions = local.in_vpc ? [] : [{
        test     = "IpAddress"
        variable = "aws:SourceIp"
        values   = var.allowed_cidrs
      }]
    }
  }

  vpc_options = local.in_vpc ? {
    subnet_ids = slice(module.vpc[0].private_subnets, 0, var.availability_zone_count)
  } : {}

  security_group_rules = local.in_vpc ? {
    for i, cidr in local.sg_ingress_cidrs : "https_${i}" => {
      type        = "ingress"
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      cidr_ipv4   = cidr
      description = "OpenSearch HTTPS from ${cidr}"
    }
  } : {}

  # Throwaway test target: skip slow-log publishing (and the CloudWatch log groups +
  # account-level resource policy the module would otherwise create for it).
  log_publishing_options       = []
  create_cloudwatch_log_groups = false

  # Let AWS pick the maintenance window; Auto-Tune is left at the module default.
  software_update_options = {
    auto_software_update_enabled = false
  }

  tags = {
    Name = local.cluster_name
  }
}

# ---------------------------------------------------------------------------
# PrivateLink analog: OpenSearch-managed VPC endpoints. Each authorized account can create
# an aws_opensearch_vpc_endpoint in its own VPC referencing this domain's ARN, which
# OpenSearch Service then wires to the VPC-resident domain over PrivateLink.
# ---------------------------------------------------------------------------
resource "aws_opensearch_authorize_vpc_endpoint_access" "consumer" {
  for_each = var.enable_psc ? toset(var.privatelink_allowed_accounts) : toset([])

  domain_name = module.opensearch.domain_name
  account     = each.value
}

# ---------------------------------------------------------------------------
# VPC peering with the migration cluster
# ---------------------------------------------------------------------------
resource "aws_vpc_peering_connection" "migration" {
  count = var.vpc_peering.mode == "enabled" ? 1 : 0

  vpc_id        = module.vpc[0].vpc_id
  peer_vpc_id   = var.vpc_peering.peer_vpc_id
  peer_owner_id = var.vpc_peering.peer_owner_id
  peer_region   = var.vpc_peering.peer_region
  auto_accept   = false

  tags = {
    Name = "${local.cluster_name}-peer-migration"
  }
}

resource "aws_route" "peer" {
  count = var.vpc_peering.mode == "enabled" && length(var.vpc_peering.peer_cidrs) > 0 ? length(module.vpc[0].private_route_table_ids) * length(var.vpc_peering.peer_cidrs) : 0

  route_table_id            = module.vpc[0].private_route_table_ids[floor(count.index / length(var.vpc_peering.peer_cidrs))]
  destination_cidr_block    = var.vpc_peering.peer_cidrs[count.index % length(var.vpc_peering.peer_cidrs)]
  vpc_peering_connection_id = aws_vpc_peering_connection.migration[0].id
}
