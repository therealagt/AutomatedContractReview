terraform {
  backend "gcs" {
    bucket = "acreview-dev-tfstate"
    prefix = "terraform/dev"
  }
}
