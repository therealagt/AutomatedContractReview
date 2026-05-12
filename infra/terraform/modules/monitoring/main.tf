locals {
  workflow_short = element(reverse(split("/", var.workflow_id)), 0)

  all_notification_channel_ids = distinct(concat(
    var.notification_channel_ids,
    [for _, ch in google_monitoring_notification_channel.email : ch.name],
  ))

  cloud_run_services = toset(var.cloud_run_service_names)

  log_bucket_location = var.log_export_bucket_location != "" ? var.log_export_bucket_location : "EU"

  dashboard_workflow_fail_filter = format(
    "resource.type=\"workflows.googleapis.com/Workflow\" AND resource.labels.workflow_id=%s AND metric.type=\"workflows.googleapis.com/workflow/finished_execution_count\" AND metric.labels.status=\"FAILED\"",
    jsonencode(var.workflow_id),
  )

  dashboard_pubsub_backlog_filter = var.pubsub_subscription_id == "" ? "" : format(
    "resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=%s AND metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\"",
    jsonencode(var.pubsub_subscription_id),
  )
}

resource "google_monitoring_notification_channel" "email" {
  for_each = toset(distinct(var.alert_email_addresses))

  project      = var.project_id
  display_name = "acr-${var.environment}: ${each.value}"
  type         = "email"

  labels = {
    email_address = each.value
  }
}

resource "google_monitoring_alert_policy" "workflow_errors" {
  count = var.enable_workflow_failure_alert ? 1 : 0

  display_name = "Workflow failures: ${local.workflow_short} (${var.environment})"
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

  notification_channels = local.all_notification_channel_ids
}

resource "google_monitoring_alert_policy" "pubsub_dlq" {
  count = var.enable_pubsub_dlq_alert && var.pubsub_subscription_id != "" ? 1 : 0

  display_name = "Pub/Sub DLQ: ${var.pubsub_subscription_id} (${var.environment})"
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

  notification_channels = local.all_notification_channel_ids
}

resource "google_monitoring_alert_policy" "cloud_run_health" {
  for_each = var.enable_cloud_run_alerts ? local.cloud_run_services : toset([])

  display_name = "Cloud Run ${each.key}: 5xx or high latency (${var.environment})"
  project      = var.project_id
  combiner     = "OR"

  conditions {
    display_name = "5xx responses (300s)"
    condition_threshold {
      filter = format(
        "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=%s AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"5xx\"",
        jsonencode(each.key),
      )
      comparison      = "COMPARISON_GT"
      threshold_value = var.cloud_run_5xx_threshold_per_series
      duration        = "0s"
      trigger {
        count = 1
      }
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = []
      }
    }
  }

  conditions {
    display_name = "P95 latency (300s)"
    condition_threshold {
      filter = format(
        "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=%s AND metric.type=\"run.googleapis.com/request_latencies\"",
        jsonencode(each.key),
      )
      comparison      = "COMPARISON_GT"
      threshold_value = strcontains(each.key, "dispatcher") ? var.cloud_run_dispatcher_latency_seconds : var.cloud_run_latency_threshold_seconds
      duration        = "0s"
      trigger {
        count = 1
      }
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = []
      }
    }
  }

  notification_channels = local.all_notification_channel_ids
}

resource "google_storage_bucket" "log_export" {
  count = var.enable_log_export ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.log_export_bucket_name != ""
      error_message = "log_export_bucket_name must be set when enable_log_export is true."
    }
  }

  name                        = var.log_export_bucket_name
  project                     = var.project_id
  location                    = local.log_bucket_location
  uniform_bucket_level_access = true
  force_destroy               = false

  public_access_prevention = "enforced"

  lifecycle_rule {
    condition {
      age = var.log_export_retention_days
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_logging_project_sink" "regulated" {
  count = var.enable_log_export ? 1 : 0

  name        = "acr-${var.environment}-regulated-logs"
  project     = var.project_id
  destination = "storage.googleapis.com/${google_storage_bucket.log_export[0].name}"
  filter      = var.log_export_filter

  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "log_sink_writer" {
  count = var.enable_log_export ? 1 : 0

  bucket = google_storage_bucket.log_export[0].name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.regulated[0].writer_identity
}

resource "google_monitoring_dashboard" "pipeline" {
  count = var.enable_dashboard ? 1 : 0

  project = var.project_id

  dashboard_json = jsonencode({
    displayName = "acr-${var.environment}-pipeline"
    mosaicLayout = {
      columns = 12
      tiles = concat(
        [
          {
            width  = 6
            height = 4
            widget = {
              title = "Workflow failed executions"
              xyChart = {
                dataSets = [
                  {
                    plotType = "LINE"
                    timeSeriesQuery = {
                      timeSeriesFilter = {
                        filter = local.dashboard_workflow_fail_filter
                        aggregation = {
                          alignmentPeriod    = "300s"
                          perSeriesAligner   = "ALIGN_DELTA"
                          crossSeriesReducer = "REDUCE_SUM"
                          groupByFields      = []
                        }
                      }
                    }
                  }
                ]
              }
            }
          },
        ],
        var.pubsub_subscription_id == "" ? [] : [
          {
            xPos   = 6
            width  = 6
            height = 4
            widget = {
              title = "Pub/Sub undelivered messages"
              xyChart = {
                dataSets = [
                  {
                    plotType = "LINE"
                    timeSeriesQuery = {
                      timeSeriesFilter = {
                        filter = local.dashboard_pubsub_backlog_filter
                        aggregation = {
                          alignmentPeriod    = "60s"
                          perSeriesAligner   = "ALIGN_MEAN"
                          crossSeriesReducer = "REDUCE_SUM"
                          groupByFields      = []
                        }
                      }
                    }
                  }
                ]
              }
            }
          },
        ],
        length(local.cloud_run_services) == 0 ? [] : [
          {
            yPos   = 4
            width  = 12
            height = 4
            widget = {
              title = "Cloud Run 5xx (all pipeline services)"
              xyChart = {
                dataSets = [
                  {
                    plotType = "LINE"
                    timeSeriesQuery = {
                      timeSeriesFilter = {
                        filter = length(local.cloud_run_services) == 1 ? format("resource.type=\"cloud_run_revision\" AND resource.labels.service_name=%s AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"5xx\"", jsonencode(one(local.cloud_run_services))) : join(" OR ", [for s in sort(tolist(local.cloud_run_services)) : format("resource.type=\"cloud_run_revision\" AND resource.labels.service_name=%s AND metric.type=\"run.googleapis.com/request_count\" AND metric.labels.response_code_class=\"5xx\"", jsonencode(s))])
                        aggregation = {
                          alignmentPeriod    = "300s"
                          perSeriesAligner   = "ALIGN_DELTA"
                          crossSeriesReducer = "REDUCE_SUM"
                          groupByFields = [
                            "resource.label.service_name",
                          ]
                        }
                      }
                    }
                  }
                ]
              }
            }
          },
        ],
      )
    }
  })
}

output "alert_policy_ids" {
  value = compact(concat(
    [for p in google_monitoring_alert_policy.workflow_errors : p.id],
    [for p in google_monitoring_alert_policy.pubsub_dlq : p.id],
    [for p in google_monitoring_alert_policy.cloud_run_health : p.id],
  ))
}

output "notification_channel_ids_created" {
  value = [for _, ch in google_monitoring_notification_channel.email : ch.name]
}

output "log_export_bucket" {
  value = var.enable_log_export ? google_storage_bucket.log_export[0].name : null
}

output "dashboard_id" {
  value = var.enable_dashboard ? google_monitoring_dashboard.pipeline[0].id : null
}
