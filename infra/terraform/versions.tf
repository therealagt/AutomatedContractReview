# Provider pins for optional root layout; env stacks duplicate required_providers in main.tf.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
}
