variable "name" {
  description = "Snapshot repository name to register (PUT _snapshot/<name>)."
  type        = string
  default     = "default"
}

variable "endpoint" {
  description = "In-cluster HTTPS endpoint of the search cluster, e.g. https://es-source-es-http.default.svc:9200. Uses service DNS so registration works regardless of whether the external endpoint is public or PSC-internal (the apply host only needs Kubernetes API access, not data-plane reachability)."
  type        = string
}

variable "namespace" {
  description = "Namespace to run the registration Job in (also where the credentials secret lives)."
  type        = string
  default     = "default"
}

variable "username" {
  description = "Username for the search cluster admin/superuser."
  type        = string
}

variable "credentials_secret" {
  description = "Name of the Kubernetes secret holding the password."
  type        = string
}

variable "password_key" {
  description = "Key within credentials_secret that holds the password (e.g. 'elastic' for ECK, 'password' for others)."
  type        = string
}

variable "repo_type" {
  description = "Snapshot repository backend type: gcs | s3 | azure."
  type        = string

  validation {
    condition     = contains(["gcs", "s3", "azure"], var.repo_type)
    error_message = "repo_type must be one of: gcs, s3, azure."
  }
}

variable "repo_settings" {
  description = "Backend-specific settings map (e.g. { bucket = ..., base_path = ... } for gcs/s3). Passed through verbatim as the repository 'settings' body."
  type        = map(string)
}

variable "job_name" {
  description = "Name for the registration Job. Defaults to snapshot-repo-<name>."
  type        = string
  default     = ""
}

variable "curl_image" {
  description = "Container image providing curl for the registration Job."
  type        = string
  default     = "curlimages/curl:8.10.1"
}
