# Docker repository for pipeline service images.
# - reader binding for runtime SAs that pull images
# - writer bindings for CI/deploy SAs that push images
variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "repo_id" {
  type        = string
  description = "Artifact Registry repository ID (short name, no path)."
}

variable "description" {
  type    = string
  default = "Container images for the contract review pipeline"
}

variable "reader_members" {
  type        = list(string)
  description = "Principals (e.g. serviceAccount:foo@..) that pull images at runtime."
  default     = []
}

variable "writer_members" {
  type        = list(string)
  description = "Principals that push images (CI service accounts)."
  default     = []
}

resource "google_artifact_registry_repository" "repo" {
  project       = var.project_id
  location      = var.region
  repository_id = var.repo_id
  description   = var.description
  format        = "DOCKER"
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = toset(var.reader_members)

  project    = var.project_id
  location   = google_artifact_registry_repository.repo.location
  repository = google_artifact_registry_repository.repo.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each = toset(var.writer_members)

  project    = var.project_id
  location   = google_artifact_registry_repository.repo.location
  repository = google_artifact_registry_repository.repo.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

output "repository_id" {
  value = google_artifact_registry_repository.repo.repository_id
}

output "repository_uri" {
  description = "Base URI for image refs, e.g. region-docker.pkg.dev/project/repo"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}"
}
