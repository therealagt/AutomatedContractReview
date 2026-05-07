# Cloud Run (v2) service template: container image, runtime SA, env map, autoscaling and concurrency bounds.
# - container_concurrency caps parallel requests per instance (set 1 for quota-sensitive services)
# - timeout_seconds allows raising for long-running calls (DocAI/Vertex)
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

variable "env_vars" {
  type    = map(string)
  default = {}
}

variable "min_instances" {
  type    = number
  default = 0
}

variable "max_instances" {
  type    = number
  default = 10
}

variable "container_concurrency" {
  type        = number
  default     = 80
  description = "Max concurrent requests per instance. Set to 1 for hard rate limiting."
}

variable "timeout_seconds" {
  type        = number
  default     = 300
  description = "Per-request timeout. Raise for long sync calls (DocAI/Vertex up to 3600)."
}

variable "ingress" {
  type    = string
  default = "INGRESS_TRAFFIC_INTERNAL_ONLY"
}

resource "google_cloud_run_v2_service" "service" {
  project  = var.project_id
  location = var.region
  name     = var.service_name

  template {
    service_account                  = var.service_account_email
    timeout                          = "${var.timeout_seconds}s"
    max_instance_request_concurrency = var.container_concurrency

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.image

      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  ingress = var.ingress
}

output "service_url" {
  value = google_cloud_run_v2_service.service.uri
}

output "service_name" {
  value = google_cloud_run_v2_service.service.name
}

output "service_id" {
  value = google_cloud_run_v2_service.service.id
}
