# Input variables for the dev stack (tfvars supply project, region, vertex model overrides).
variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "environment" {
  type = string
}

variable "enabled_apis" {
  description = "GCP service APIs that must be enabled for the pipeline."
  type        = set(string)
  default = [
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "firestore.googleapis.com",
    "run.googleapis.com",
    "workflows.googleapis.com",
    "workflowexecutions.googleapis.com",
    "documentai.googleapis.com",
    "dlp.googleapis.com",
    "aiplatform.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "eventarc.googleapis.com",
  ]
}

variable "vertex_model" {
  type    = string
  default = "gemini-1.5-pro"
}

variable "artifact_registry_repo_id" {
  type        = string
  default     = "acr"
  description = "Artifact Registry Docker repo for pipeline images."
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Tag pulled by Cloud Run services. Pin to a SHA in CI for prod-like rollouts."
}

variable "ci_writer_members" {
  type        = list(string)
  default     = []
  description = "Principals (CI SAs) granted artifactregistry.writer on the dev repo."
}

variable "docai_location" {
  type    = string
  default = "eu"
}

variable "gemini_max_instances" {
  type        = number
  default     = 5
  description = "Hard cap on parallel Gemini Cloud Run instances; sized to stay within Vertex quotas."
}

variable "gemini_timeout_seconds" {
  type    = number
  default = 1800
}

variable "docai_timeout_seconds" {
  type    = number
  default = 1800
}

variable "dispatcher_max_instances" {
  type        = number
  default     = 5
  description = "Hard cap on parallel workflow executions started from Pub/Sub."
}

variable "gemini_batch_char_threshold" {
  type        = number
  default     = 200000
  description = "Above this redacted-text length, Gemini step uses Vertex AI Batch Prediction."
}

variable "terraform_state_bucket_name" {
  type        = string
  description = "GCS backend bucket; must match envs/dev/backend.tf"
  default     = "acreview-dev-tfstate"
}

variable "terraform_state_access_members" {
  type        = list(string)
  description = "Principals granted roles/storage.objectAdmin on the remote state bucket (humans, CI Terraform SA)."
  default     = []
}
