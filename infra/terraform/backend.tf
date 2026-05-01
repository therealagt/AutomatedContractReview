terraform {
  # Local backend for local-first development.
  # Switch to GCS backend when project billing and state bucket are ready.
  backend "local" {
    path = ".terraform/terraform.tfstate"
  }
}
