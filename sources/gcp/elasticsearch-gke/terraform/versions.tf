terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    elasticstack = {
      source  = "elastic/elasticstack"
      version = "~> 0.11"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
