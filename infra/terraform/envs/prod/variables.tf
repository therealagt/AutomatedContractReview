# Input variables for the prod stack (tfvars supply project, region, AI/DLP ids, images).
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
    "documentai.googleapis.com",
    "dlp.googleapis.com",
    "aiplatform.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "artifactregistry.googleapis.com",
    "eventarc.googleapis.com",
  ]
}

variable "docai_processor_id" {
  type = string
}

variable "vertex_model" {
  type = string
}

variable "dlp_template_ids" {
  type = object({
    inspect    = string
    deidentify = string
  })
}

variable "service_images" {
  description = "Container images per service."
  type = object({
    docai           = string
    pii_redaction   = string
    gemini_analysis = string
    finalize        = string
  })
}
