terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      # terraform-aws-modules/opensearch v2.11 requires >= 6.51
      source  = "hashicorp/aws"
      version = "~> 6.51"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
