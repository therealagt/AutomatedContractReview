# Job topic, push subscription with backpressure controls, and DLQ for pipeline work items.
# - 7d retention buffers bursts; backlog acts as alerting signal
# - retry_policy + DLQ shield pipeline from poison messages
# - exactly_once_delivery prevents duplicate workflow executions
variable "project_id" {
  type = string
}

variable "topic_name" {
  type = string
}

variable "subscription_name" {
  type = string
}

variable "dead_letter_topic_name" {
  type = string
}

variable "ack_deadline_seconds" {
  type        = number
  default     = 600
  description = "Ack deadline; raise for slow consumers (e.g. dispatcher invoking workflows)."
}

variable "max_delivery_attempts" {
  type    = number
  default = 10
}

variable "message_retention_duration" {
  type        = string
  default     = "604800s"
  description = "How long Pub/Sub buffers unacked messages. Default 7 days."
}

variable "minimum_backoff" {
  type    = string
  default = "10s"
}

variable "maximum_backoff" {
  type    = string
  default = "600s"
}

variable "enable_exactly_once_delivery" {
  type    = bool
  default = true
}

resource "google_pubsub_topic" "main" {
  name    = var.topic_name
  project = var.project_id
}

resource "google_pubsub_topic" "dead_letter" {
  name    = var.dead_letter_topic_name
  project = var.project_id
}

resource "google_pubsub_subscription" "main" {
  name    = var.subscription_name
  topic   = google_pubsub_topic.main.id
  project = var.project_id

  ack_deadline_seconds         = var.ack_deadline_seconds
  message_retention_duration   = var.message_retention_duration
  enable_exactly_once_delivery = var.enable_exactly_once_delivery

  retry_policy {
    minimum_backoff = var.minimum_backoff
    maximum_backoff = var.maximum_backoff
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = var.max_delivery_attempts
  }
}

output "topic_id" {
  value = google_pubsub_topic.main.id
}

output "topic_name" {
  value = google_pubsub_topic.main.name
}

output "subscription_id" {
  value = google_pubsub_subscription.main.id
}

output "dead_letter_topic_id" {
  value = google_pubsub_topic.dead_letter.id
}
