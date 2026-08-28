variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "name_prefix" {
  description = "Prefix for resource names (e.g., your name or team)"
  type        = string
  default     = "os"
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
  default     = 5
}

variable "disk_size_gb" {
  description = "EBS volume size in GB for each node"
  type        = number
  default     = 80
}

variable "opensearch_version" {
  description = "OpenSearch version to deploy"
  type        = string
  default     = "3.5.0"
}

variable "operator_version" {
  # 2.8.0 is the floor: it is the first operator release that (a) supports OpenSearch 3.x
  # and (b) defines the tls.http.customFQDN field that psc_dns_name relies on. On 2.7.0 the
  # customFQDN field is silently pruned by the Kubernetes API (no error), so the hostname
  # never lands in the served cert's SANs.
  description = "OpenSearch Kubernetes Operator Helm chart version (>= 2.8.0 required for OpenSearch 3.x and psc_dns_name/customFQDN)"
  type        = string
  default     = "2.8.4"
}

variable "cert_manager_version" {
  # Required by operator >= 2.8.0: the operator chart's admission webhook renders
  # cert-manager Certificate/Issuer resources (webhook.certManager.enabled defaults true),
  # so cert-manager and its CRDs must be present before the operator installs.
  description = "cert-manager Helm chart version (dependency of the OpenSearch operator webhook)"
  type        = string
  default     = "v1.19.6"
}

variable "lb_controller_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.8.1"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach OpenSearch (default: unrestricted). Ignored when enable_psc = true (internal NLB)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_psc" {
  description = "Expose OpenSearch via AWS PrivateLink (internal NLB + VPC endpoint service) instead of a public NLB. Named enable_psc for parity with the GCP target and the cluster.sh --private-networking flag."
  type        = bool
  default     = false
}

variable "privatelink_allowed_principals" {
  description = "AWS principal ARNs (accounts/roles) allowed to connect via PrivateLink (analog of psc_consumer_project_ids). Required when enable_psc = true."
  type        = list(string)
  default     = []
}

variable "psc_dns_name" {
  description = "Optional hostname to add as a SAN on the OpenSearch HTTP cert so a PrivateLink consumer can connect by hostname with valid TLS. Requires operator_version >= 2.8.0 (the customFQDN CRD field); on older operators the hostname is silently dropped from the cert. Empty leaves the operator's default cert unchanged."
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
