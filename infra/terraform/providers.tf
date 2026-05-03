# Default Google provider for root layout when not using envs/*/ stacks.
provider "google" {
  project = var.project_id
  region  = var.region
}
