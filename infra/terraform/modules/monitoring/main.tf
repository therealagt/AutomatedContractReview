variable "project_id" {
  type = string
}

variable "workflow_name" {
  type = string
}

variable "notification_channel_ids" {
  type    = list(string)
  default = []
}

variable "error_rate_threshold" {
  type    = number
  default = 1
}

resource "google_monitoring_alert_policy" "workflow_errors" {
  display_name = "Workflow errors: ${var.workflow_name}"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "Workflow execution failed"
    condition_threshold {
      filter          = "resource.type=\"workflows.googleapis.com/Workflow\" AND resource.label.workflow_name=\"${var.workflow_name}\" AND metric.type=\"workflows.googleapis.com/workflow/execution_count\" AND metric.label.status=\"failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.error_rate_threshold
      duration        = "0s"
      trigger {
        count = 1
      }
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = var.notification_channel_ids
}

output "alert_policy_ids" {
  value = [google_monitoring_alert_policy.workflow_errors.id]
}
