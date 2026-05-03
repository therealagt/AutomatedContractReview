# Raw and processed PDF buckets with versioning, uniform access, and lifecycle rules.
variable "project_id" {
  type = string
}

variable "location" {
  type = string
}

variable "raw_bucket_name" {
  type = string
}

variable "processed_bucket_name" {
  type = string
}

variable "versioning_enabled" {
  type    = bool
  default = true
}

variable "lifecycle_days_raw" {
  type    = number
  default = 30
}

variable "lifecycle_days_processed" {
  type    = number
  default = 365
}

resource "google_storage_bucket" "raw" {
  name                        = var.raw_bucket_name
  location                    = var.location
  project                     = var.project_id
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = var.versioning_enabled
  }

  lifecycle_rule {
    condition {
      age = var.lifecycle_days_raw
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket" "processed" {
  name                        = var.processed_bucket_name
  location                    = var.location
  project                     = var.project_id
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = var.versioning_enabled
  }

  lifecycle_rule {
    condition {
      age = var.lifecycle_days_processed
    }
    action {
      type = "Delete"
    }
  }
}

output "raw_bucket_name" {
  value = google_storage_bucket.raw.name
}

output "processed_bucket_name" {
  value = google_storage_bucket.processed.name
}
