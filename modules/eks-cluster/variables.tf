variable "cluster_name" {
  description = "Name for the EKS cluster and associated resources"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-2"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "instance_type" {
  description = "EC2 instance type for EKS managed node group"
  type        = string
  default     = "m5.xlarge"
}

variable "node_count" {
  description = "Number of nodes in the managed node group"
  type        = number
  default     = 3
}

variable "disk_size_gb" {
  description = "EBS volume size in GB for each node"
  type        = number
  default     = 80
}

variable "vpc_cidr" {
  description = "CIDR block for the cluster VPC"
  type        = string
  default     = "10.0.0.0/16"
}
