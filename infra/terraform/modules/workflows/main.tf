# Deploys workflow source from disk path into Google Cloud Workflows.
variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "workflow_name" {
  type = string
}

variable "workflow_source_path" {
  type = string
}

resource "google_workflows_workflow" "pipeline" {
  project         = var.project_id
  region          = var.region
  name            = var.workflow_name
  source_contents = file(var.workflow_source_path)
}

output "workflow_id" {
  value = google_workflows_workflow.pipeline.id
}

output "workflow_name" {
  value = google_workflows_workflow.pipeline.name
}
