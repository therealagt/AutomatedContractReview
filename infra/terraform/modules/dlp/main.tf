# DLP inspect + de-identify templates used by pii-redaction-service to redact extracted text before Gemini.
variable "project_id" {
  type = string
}

variable "parent" {
  type        = string
  default     = null
  description = "DLP parent resource. Defaults to projects/<project_id>/locations/global."
}

variable "info_types" {
  type = list(string)
  default = [
    "EMAIL_ADDRESS",
    "PERSON_NAME",
    "PHONE_NUMBER",
    "STREET_ADDRESS",
    "IBAN_CODE",
    "CREDIT_CARD_NUMBER",
    "DATE_OF_BIRTH",
  ]
}

variable "min_likelihood" {
  type    = string
  default = "POSSIBLE"
}

locals {
  resolved_parent = coalesce(var.parent, "projects/${var.project_id}/locations/global")
}

resource "google_data_loss_prevention_inspect_template" "inspect" {
  parent       = local.resolved_parent
  display_name = "acr-inspect-pii"
  description  = "PII inspect template for contract text"

  inspect_config {
    min_likelihood = var.min_likelihood

    dynamic "info_types" {
      for_each = var.info_types
      content {
        name = info_types.value
      }
    }
  }
}

resource "google_data_loss_prevention_deidentify_template" "deidentify" {
  parent       = local.resolved_parent
  display_name = "acr-deidentify-pii"
  description  = "Replace PII with info-type tokens before LLM analysis"

  deidentify_config {
    info_type_transformations {
      transformations {
        primitive_transformation {
          replace_with_info_type_config = true
        }
      }
    }
  }
}

output "inspect_template_id" {
  value = google_data_loss_prevention_inspect_template.inspect.id
}

output "deidentify_template_id" {
  value = google_data_loss_prevention_deidentify_template.deidentify.id
}
