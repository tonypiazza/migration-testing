variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "name_prefix" {
  description = "Prefix for resource names (e.g., your name or team)"
  type        = string
  default     = "es"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "instance_type" {
  description = "EC2 instance type for EKS nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "node_count" {
  description = "Number of nodes in the node group"
  type        = number
  default     = 3
}

variable "disk_size_gb" {
  description = "EBS volume size in GB for each node"
  type        = number
  default     = 80
}

variable "elasticsearch_version" {
  description = "Elasticsearch version to deploy"
  type        = string
  default     = "8.19.15"
}

variable "eck_version" {
  description = "ECK operator version"
  type        = string
  default     = "2.14.0"
}

variable "lb_controller_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.8.1"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach Elasticsearch (default: unrestricted). Ignored when enable_psc = true (internal NLB)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_psc" {
  description = "Expose Elasticsearch via AWS PrivateLink (internal NLB + VPC endpoint service) instead of a public NLB. Named enable_psc for parity with the GCP source and the cluster.sh --private-networking flag."
  type        = bool
  default     = false
}

variable "privatelink_allowed_principals" {
  description = "AWS principal ARNs (accounts/roles) allowed to connect via PrivateLink (analog of psc_consumer_project_ids). Required when enable_psc = true."
  type        = list(string)
  default     = []
}

variable "psc_dns_name" {
  description = "Optional hostname to add as a SAN on the Elasticsearch HTTP cert so a PrivateLink consumer can connect by hostname with valid TLS. Empty leaves the operator's default cert unchanged."
  type        = string
  default     = ""
}

variable "vpc_peering" {
  description = "VPC peering configuration. Set mode to 'enabled' to peer with the migration cluster VPC."
  type = object({
    mode          = optional(string, "none")
    peer_owner_id = optional(string, "")
    peer_vpc_id   = optional(string, "")
    peer_region   = optional(string, "")
    peer_cidrs    = optional(list(string), [])
  })
  default = { mode = "none" }
}

variable "snapshot_bucket" {
  description = "S3 bucket for Elasticsearch snapshots (must already exist)"
  type        = string
  default     = "aiven-sa-demo-es-snapshots"
}

variable "snapshot_base_path" {
  description = "Base path within the snapshot bucket"
  type        = string
  default     = "snapshots/optimized"
}
