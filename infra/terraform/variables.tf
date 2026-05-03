# Root module variables (legacy layout; env stacks use envs/*/variables.tf).
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Primary GCP region"
  type        = string
}
