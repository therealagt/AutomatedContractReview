# Alerting: workflow execution failures and Pub/Sub dead-letter traffic (optional channels).
variable "project_id" {
  type = string
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
  type    = list(string)
  default = []
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

locals {
  workflow_short = element(reverse(split("/", var.workflow_id)), 0)
}

resource "google_monitoring_alert_policy" "workflow_errors" {
  display_name = "Workflow failures: ${local.workflow_short}"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "Finished execution with failed status"
    condition_threshold {
      filter          = "resource.type=\"workflows.googleapis.com/Workflow\" AND resource.labels.workflow_id=${jsonencode(var.workflow_id)} AND metric.type=\"workflows.googleapis.com/workflow/finished_execution_count\" AND metric.labels.status=\"FAILED\""
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

resource "google_monitoring_alert_policy" "pubsub_dlq" {
  count = var.pubsub_subscription_id == "" ? 0 : 1

  display_name = "Pub/Sub DLQ: ${var.pubsub_subscription_id}"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "Messages sent to dead-letter topic"
    condition_threshold {
      filter          = "resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=${jsonencode(var.pubsub_subscription_id)} AND metric.type=\"pubsub.googleapis.com/subscription/dead_letter_message_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.dlq_message_threshold
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
  value = compact(concat(
    [google_monitoring_alert_policy.workflow_errors.id],
    [for p in google_monitoring_alert_policy.pubsub_dlq : p.id],
  ))
}
