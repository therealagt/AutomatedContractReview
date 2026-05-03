# Root outputs when using infra/terraform as a single workspace.
output "project_id" {
  description = "Configured GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "Configured GCP region"
  value       = var.region
}
