variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone (single-zone cluster for cost savings; set to null for regional)"
  type        = string
  default     = "us-central1-c"
}

variable "name_prefix" {
  description = "Prefix for resource names (e.g., your name or team)"
  type        = string
  default     = "es"
}

variable "machine_type" {
  description = "Machine type for GKE nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "node_count" {
  description = "Number of nodes in the node pool"
  type        = number
  default     = 3
}

variable "disk_size_gb" {
  description = "Boot disk size in GB for each node"
  type        = number
  default     = 50
}

variable "elasticsearch_version" {
  description = "Elasticsearch version to deploy"
  type        = string
  default     = "8.17.0"
}

variable "eck_version" {
  description = "ECK operator version"
  type        = string
  default     = "2.14.0"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach Elasticsearch (default: unrestricted)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_psc" {
  description = "Expose Elasticsearch via Private Service Connect instead of external LoadBalancer"
  type        = bool
  default     = false
}

variable "psc_consumer_project_ids" {
  description = "GCP project IDs allowed to connect via PSC (required when enable_psc = true)"
  type        = list(string)
  default     = []
}
