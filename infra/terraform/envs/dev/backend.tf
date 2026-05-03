# Remote state for dev; bucket and prefix are fixed (not variable-driven).
terraform {
  backend "gcs" {
    bucket = "acreview-dev-tfstate"
    prefix = "terraform/dev"
  }
}
