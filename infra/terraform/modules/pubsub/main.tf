# Job topic, pull subscription, and DLQ for pipeline work items.
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
  type    = number
  default = 30
}

variable "max_delivery_attempts" {
  type    = number
  default = 10
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

  ack_deadline_seconds = var.ack_deadline_seconds

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = var.max_delivery_attempts
  }
}

output "topic_id" {
  value = google_pubsub_topic.main.id
}

output "subscription_id" {
  value = google_pubsub_subscription.main.id
}

output "dead_letter_topic_id" {
  value = google_pubsub_topic.dead_letter.id
}
