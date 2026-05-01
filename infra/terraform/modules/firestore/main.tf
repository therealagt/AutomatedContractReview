variable "project_id" {
  type = string
}

variable "database_name" {
  type    = string
  default = "(default)"
}

variable "location_id" {
  type = string
}

variable "deletion_policy" {
  type    = string
  default = "DELETE"
}

resource "google_firestore_database" "main" {
  project     = var.project_id
  name        = var.database_name
  location_id = var.location_id
  type        = "FIRESTORE_NATIVE"
}

output "database_id" {
  value = google_firestore_database.main.id
}
