# Dispatcher Cloud Run + Eventarc trigger.
# Sits between Pub/Sub and Cloud Workflows to provide rate limiting:
# - max_instance_count caps total parallel jobs
# - max_instance_request_concurrency=1 forces one job per instance
# - on workflows.executions quota errors, return 5xx so Pub/Sub re-delivers with backoff
variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "service_name" {
  type = string
}

variable "image" {
  type = string
}

variable "service_account_email" {
  type = string
}

variable "workflow_id" {
  type        = string
  description = "Workflow resource id (projects/.../workflows/...) to invoke."
}

variable "jobs_topic_id" {
  type        = string
  description = "Pub/Sub topic id (projects/.../topics/...) to subscribe Eventarc to."
}

variable "max_instances" {
  type        = number
  default     = 5
  description = "Hard cap on parallel workflow executions started."
}

variable "min_instances" {
  type    = number
  default = 0
}

variable "timeout_seconds" {
  type    = number
  default = 60
}

variable "extra_env_vars" {
  type    = map(string)
  default = {}
}

resource "google_cloud_run_v2_service" "dispatcher" {
  project  = var.project_id
  location = var.region
  name     = var.service_name
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account                  = var.service_account_email
    timeout                          = "${var.timeout_seconds}s"
    max_instance_request_concurrency = 1

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.image

      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "WORKFLOW_ID"
        value = var.workflow_id
      }

      dynamic "env" {
        for_each = var.extra_env_vars
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }
}

resource "google_eventarc_trigger" "jobs_to_dispatcher" {
  project         = var.project_id
  location        = var.region
  name            = "${var.service_name}-trg"
  service_account = var.service_account_email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = var.jobs_topic_id
    }
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.dispatcher.name
      region  = var.region
      path    = "/dispatch"
    }
  }
}

output "service_url" {
  value = google_cloud_run_v2_service.dispatcher.uri
}

output "service_name" {
  value = google_cloud_run_v2_service.dispatcher.name
}

output "trigger_id" {
  value = google_eventarc_trigger.jobs_to_dispatcher.id
}
