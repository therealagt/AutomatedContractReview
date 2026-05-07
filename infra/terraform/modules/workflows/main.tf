# Deploys workflow source from disk into Google Cloud Workflows.
# - service_account is used by the workflow to mint OIDC tokens for Cloud Run callees
# - user_env_vars makes service URLs and other config available to the workflow YAML via sys.get_env()
# - the workflow is started by the dispatcher service, so no Eventarc trigger is created here
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

variable "service_account_email" {
  type        = string
  description = "Workflow runtime SA used for OIDC calls to Cloud Run services."
}

variable "user_env_vars" {
  type        = map(string)
  default     = {}
  description = "Env vars exposed to the workflow YAML (e.g. service URLs, processor names)."
}

resource "google_workflows_workflow" "pipeline" {
  project         = var.project_id
  region          = var.region
  name            = var.workflow_name
  service_account = var.service_account_email
  source_contents = file(var.workflow_source_path)
  user_env_vars   = var.user_env_vars
}

output "workflow_id" {
  value = google_workflows_workflow.pipeline.id
}

output "workflow_name" {
  value = google_workflows_workflow.pipeline.name
}
