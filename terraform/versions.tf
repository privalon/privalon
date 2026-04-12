terraform {
  required_version = ">= 1.3.0"

  required_providers {
    grid = {
      source  = "threefoldtech/grid"
      version = ">= 1.11.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}
