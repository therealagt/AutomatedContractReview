variable "project_id" {
  type = string
}

variable "services" {
  description = "Set of GCP service APIs to enable for the project (e.g., run.googleapis.com)."
  type        = set(string)
}
