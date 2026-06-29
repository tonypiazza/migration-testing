variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-south1"
}

variable "zone" {
  description = "GCP zone (single-zone cluster for cost savings; set to null for regional)"
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Prefix for resource names (e.g., your name or team)"
  type        = string
  default     = "os"
}

variable "machine_type" {
  description = "Machine type for GKE nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "node_count" {
  description = "Number of nodes in the node pool"
  type        = number
  default     = 5
}

variable "disk_size_gb" {
  description = "Boot disk size in GB for each node"
  type        = number
  default     = 80
}

variable "opensearch_version" {
  description = "OpenSearch version to deploy"
  type        = string
  default     = "3.5.0"
}

variable "operator_version" {
  description = "OpenSearch Kubernetes Operator Helm chart version"
  type        = string
  default     = "2.7.0"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach OpenSearch (default: unrestricted)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_psc" {
  description = "Expose OpenSearch via Private Service Connect instead of external LoadBalancer"
  type        = bool
  default     = false
}

variable "psc_consumer_project_ids" {
  description = "GCP project IDs allowed to connect via PSC (required when enable_psc = true)"
  type        = list(string)
  default     = []
}

variable "vpc_peering" {
  description = "VPC peering configuration. Set mode to 'enabled' to peer with the migration cluster VPC."
  type = object({
    mode               = optional(string, "none")
    peer_project       = optional(string, "")
    peer_vpc_self_link = optional(string, "")
    peer_cidrs         = optional(list(string), [])
  })
  default = { mode = "none" }
}

variable "psc_dns_name" {
  description = "Optional hostname to add as a SAN on the OpenSearch HTTP cert (so a PSC consumer can connect by hostname with valid TLS). Only meaningful with enable_psc = true; empty leaves the operator's default cert unchanged."
  type        = string
  default     = ""
}

variable "connection_limit" {
  description = "Per-consumer-project connection limit on the PSC service attachment."
  type        = number
  default     = 10
}

variable "psc_nat_cidr" {
  description = "IP range for the PSC NAT subnet (PRIVATE_SERVICE_CONNECT purpose)."
  type        = string
  default     = "10.100.0.0/24"
}
