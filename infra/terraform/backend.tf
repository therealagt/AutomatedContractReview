# Local state fallback for root layout; prefer envs/<env>/backend.tf (GCS) for real runs.
terraform {
  backend "local" {
    path = ".terraform/terraform.tfstate"
  }
}
