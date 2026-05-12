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

variable "monitoring_notification_channel_ids" {
  type        = list(string)
  default     = []
  description = "Optional Cloud Monitoring notification channel ids for alert policies."
}

variable "monitoring_alert_emails" {
  type        = list(string)
  default     = []
  description = "Email addresses for Terraform-managed Monitoring notification channels."
}

variable "monitoring_enable_log_export" {
  type    = bool
  default = false
}

variable "monitoring_log_export_bucket_name" {
  type    = string
  default = ""
}

variable "monitoring_log_export_filter" {
  type    = string
  default = "severity>=DEFAULT"
}

variable "monitoring_log_export_retention_days" {
  type    = number
  default = 365
}

variable "monitoring_log_export_bucket_location" {
  type    = string
  default = ""
}

variable "monitoring_cloud_run_5xx_threshold" {
  type    = number
  default = 5
}

variable "monitoring_cloud_run_latency_seconds" {
  type    = number
  default = 3600
}

variable "monitoring_cloud_run_dispatcher_latency_seconds" {
  type    = number
  default = 45
}

variable "monitoring_enable_dashboard" {
  type    = bool
  default = true
}

variable "monitoring_enable_pubsub_dlq_alert" {
  type    = bool
  default = true
}

variable "monitoring_enable_workflow_alert" {
  type    = bool
  default = true
}

variable "monitoring_enable_cloud_run_alerts" {
  type    = bool
  default = true
}
