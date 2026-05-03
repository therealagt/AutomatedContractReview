# Runtime service accounts and project-level IAM bindings for pipeline components.
variable "project_id" {
  type = string
}

variable "service_accounts" {
  description = "Map of service account IDs to display names."
  type        = map(string)
}

variable "role_bindings" {
  description = "Map of service account ID to list of project roles."
  type        = map(list(string))
  default     = {}
}

resource "google_service_account" "runtime" {
  for_each = var.service_accounts

  project      = var.project_id
  account_id   = each.key
  display_name = each.value
}

locals {
  expanded_bindings = flatten([
    for sa_name, roles in var.role_bindings : [
      for role in roles : {
        key  = "${sa_name}-${replace(role, "/", "_")}"
        role = role
        sa   = sa_name
      }
    ]
  ])
}

resource "google_project_iam_member" "runtime_roles" {
  for_each = {
    for item in local.expanded_bindings : item.key => item
  }

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.runtime[each.value.sa].email}"
}

output "service_account_emails" {
  value = {
    for name, sa in google_service_account.runtime : name => sa.email
  }
}
