variable "project_id" {
  type = string
}

variable "environment" {
  type        = string
  description = "Env label for display names (dev, prod, preview, …)."
}

variable "workflow_id" {
  type        = string
  description = "Full workflow id, e.g. projects/p/locations/l/workflows/name (Terraform google_workflows_workflow.id)."
}

variable "pubsub_subscription_id" {
  type        = string
  default     = ""
  description = "Full subscription resource id (projects/.../subscriptions/...). Empty skips DLQ alert."
}

variable "notification_channel_ids" {
  type        = list(string)
  default     = []
  description = "Existing Monitoring notification channel resource names."
}

variable "alert_email_addresses" {
  type        = list(string)
  default     = []
  description = "Email addresses; Terraform creates google_monitoring_notification_channel for each."
}

variable "error_rate_threshold" {
  type    = number
  default = 1
}

variable "dlq_message_threshold" {
  type        = number
  default     = 0
  description = "Alert when dead_letter_message_count delta exceeds this in the alignment window."
}

variable "enable_workflow_failure_alert" {
  type    = bool
  default = true
}

variable "enable_pubsub_dlq_alert" {
  type    = bool
  default = true
}

variable "cloud_run_service_names" {
  type        = list(string)
  default     = []
  description = "Cloud Run (v2) service_name labels to watch for 5xx and latency."
}

variable "enable_cloud_run_alerts" {
  type    = bool
  default = true
}

variable "cloud_run_5xx_threshold_per_series" {
  type        = number
  default     = 5
  description = "5xx request_count delta per 300s alignment, per series, before alert."
}

variable "cloud_run_latency_threshold_seconds" {
  type        = number
  default     = 3600
  description = "P95 request latency (seconds) above this triggers alert; dispatcher uses cloud_run_dispatcher_latency_seconds."
}

variable "cloud_run_dispatcher_latency_seconds" {
  type        = number
  default     = 45
  description = "P95 latency threshold for services whose name contains \"dispatcher\"."
}

variable "enable_dashboard" {
  type    = bool
  default = true
}

variable "enable_log_export" {
  type        = bool
  default     = false
  description = "When true, creates a GCS bucket and project log sink (regulated copy of logs)."
}

variable "log_export_bucket_name" {
  type        = string
  default     = ""
  description = "Globally unique GCS bucket name for log export; required when enable_log_export is true."
}

variable "log_export_filter" {
  type        = string
  default     = "severity>=DEFAULT"
  description = "Log Router filter for the sink."
}

variable "log_export_retention_days" {
  type        = number
  default     = 365
  description = "Lifecycle rule: delete log objects after this many days."
}

variable "log_export_bucket_location" {
  type        = string
  default     = ""
  description = "GCS location for log bucket; defaults to multi-region EU when empty."
}
