variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "name_prefix" {
  description = "Prefix for the OpenSearch domain name (e.g., your name or team). Domain names must be lowercase and start with a letter; the final name is <name_prefix>-<4 hex chars> and must be <= 28 chars."
  type        = string
  default     = "os"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,22}$", var.name_prefix))
    error_message = "name_prefix must start with a lowercase letter, contain only [a-z0-9-], and be at most 23 characters."
  }
}

variable "opensearch_version" {
  description = "Amazon OpenSearch Service engine version, major.minor only (e.g. \"3.5\", \"2.19\"). Rendered as engine_version = OpenSearch_<version>."
  type        = string
  default     = "3.5"

  validation {
    condition     = can(regex("^[0-9]{1,2}\\.[0-9]{1,2}$", var.opensearch_version))
    error_message = "opensearch_version must be major.minor (e.g. \"3.5\"); Amazon OpenSearch Service does not accept patch versions."
  }
}

variable "instance_type" {
  description = "OpenSearch Service data node instance type (note the .search suffix)"
  type        = string
  default     = "r6g.large.search"
}

variable "node_count" {
  description = "Number of data nodes. Must be a multiple of availability_zone_count."
  type        = number
  default     = 3
}

variable "availability_zone_count" {
  description = "Number of AZs to spread data nodes across (1 = zone awareness disabled). node_count must be a multiple of this."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 3], var.availability_zone_count)
    error_message = "availability_zone_count must be 1, 2, or 3."
  }
}

variable "disk_size_gb" {
  description = "EBS (gp3) volume size in GB per data node"
  type        = number
  default     = 80
}

variable "dedicated_master_enabled" {
  description = "Provision 3 dedicated master nodes (dedicated_master_type). Off by default to keep the test target cheap."
  type        = bool
  default     = false
}

variable "dedicated_master_type" {
  description = "Instance type for dedicated master nodes (only used when dedicated_master_enabled = true)"
  type        = string
  default     = "m6g.large.search"
}

variable "master_user_name" {
  description = "Fine-grained access control master user (internal user database). cluster.sh prints this as the User."
  type        = string
  default     = "admin"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the public domain endpoint via the domain access policy (default: unrestricted). Ignored when the domain is VPC-resident (enable_psc = true or vpc_peering enabled) — network reachability is the boundary there."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_psc" {
  description = "Deploy the domain inside a VPC (no public endpoint) and authorize privatelink_allowed_accounts to create OpenSearch-managed VPC endpoints against it — the AWS analog of GCP Private Service Connect. Named enable_psc for parity with the other configs and the cluster.sh --private-networking flag."
  type        = bool
  default     = false
}

variable "privatelink_allowed_accounts" {
  description = "AWS account IDs (12 digits) authorized to create OpenSearch-managed VPC endpoints for this domain (analog of psc_consumer_project_ids). Only used when enable_psc = true."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.privatelink_allowed_accounts : can(regex("^[0-9]{12}$", a))])
    error_message = "privatelink_allowed_accounts entries must be 12-digit AWS account IDs."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the VPC the domain is placed in when it is VPC-resident (enable_psc = true or vpc_peering enabled). Unused for a public domain."
  type        = string
  default     = "10.0.0.0/16"
}

variable "vpc_peering" {
  description = "VPC peering configuration. Set mode to 'enabled' to peer with the migration cluster VPC (this also makes the domain VPC-resident)."
  type = object({
    mode          = optional(string, "none")
    peer_owner_id = optional(string, "")
    peer_vpc_id   = optional(string, "")
    peer_region   = optional(string, "")
    peer_cidrs    = optional(list(string), [])
  })
  default = { mode = "none" }
}
