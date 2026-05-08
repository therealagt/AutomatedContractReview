# Cloud Functions 2nd gen ingest entrypoint: storage finalize trigger -> Firestore record + Pub/Sub publish.
# - source code zipped from var.source_dir and uploaded to a dedicated GCS source bucket
# - Eventarc trigger filters on the raw bucket only
# - GCS service agent receives roles/pubsub.publisher (required by storage triggers)
variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "function_name" {
  type = string
}

variable "raw_bucket_name" {
  type        = string
  description = "Bucket whose finalize events trigger the function."
}

variable "jobs_topic_name" {
  type        = string
  description = "Pub/Sub topic the ingest function publishes job events to."
}

variable "service_account_email" {
  type = string
}

variable "source_dir" {
  type        = string
  description = "Local directory containing function source (e.g. ../../../services/ingest_fn)."
}

variable "source_bucket_name" {
  type        = string
  description = "GCS bucket that stores the function source archive."
}

variable "runtime" {
  type    = string
  default = "go122"
}

variable "entry_point" {
  type    = string
  default = "Ingest"
}

variable "memory" {
  type    = string
  default = "256Mi"
}

variable "timeout_seconds" {
  type    = number
  default = 60
}

variable "max_instance_count" {
  type    = number
  default = 10
}

variable "extra_event_receivers" {
  type        = list(string)
  description = "Additional principals granted roles/pubsub.publisher on the project (e.g. GCS service agent)."
  default     = []
}

resource "google_storage_bucket" "source" {
  project                     = var.project_id
  name                        = var.source_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true
}

data "archive_file" "source" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/${var.function_name}.zip"
  excludes    = [".git", ".gitignore", ".DS_Store"]
}

resource "google_storage_bucket_object" "source" {
  name   = "${var.function_name}-${data.archive_file.source.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.source.output_path
}

resource "google_project_iam_member" "gcs_pubsub_publisher" {
  for_each = toset(var.extra_event_receivers)

  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = each.value
}

resource "google_cloudfunctions2_function" "ingest" {
  project  = var.project_id
  location = var.region
  name     = var.function_name

  build_config {
    runtime     = var.runtime
    entry_point = var.entry_point
    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.source.name
      }
    }
  }

  service_config {
    service_account_email = var.service_account_email
    available_memory      = var.memory
    timeout_seconds       = var.timeout_seconds
    max_instance_count    = var.max_instance_count
    environment_variables = {
      PROJECT_ID      = var.project_id
      JOBS_TOPIC_NAME = var.jobs_topic_name
    }
    ingress_settings = "ALLOW_INTERNAL_ONLY"
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.storage.object.v1.finalized"
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = var.service_account_email

    event_filters {
      attribute = "bucket"
      value     = var.raw_bucket_name
    }
  }

  depends_on = [google_project_iam_member.gcs_pubsub_publisher]
}

output "function_name" {
  value = google_cloudfunctions2_function.ingest.name
}

output "function_uri" {
  value = google_cloudfunctions2_function.ingest.service_config[0].uri
}
