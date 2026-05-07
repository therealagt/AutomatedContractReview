# Document AI processor used by docai-service to extract text from contract PDFs.
# Location is hard-set to the Document AI multi-region (eu/us) which differs from Cloud Run regions.
variable "project_id" {
  type = string
}

variable "location" {
  type        = string
  default     = "eu"
  description = "Document AI multi-region: 'eu' or 'us'."

  validation {
    condition     = contains(["eu", "us"], var.location)
    error_message = "Document AI location must be 'eu' or 'us'."
  }
}

variable "display_name" {
  type    = string
  default = "acr-form-parser"
}

variable "processor_type" {
  type        = string
  default     = "FORM_PARSER_PROCESSOR"
  description = "Processor type: FORM_PARSER_PROCESSOR, OCR_PROCESSOR, LAYOUT_PARSER_PROCESSOR, ..."
}

resource "google_document_ai_processor" "processor" {
  project      = var.project_id
  location     = var.location
  display_name = var.display_name
  type         = var.processor_type
}

output "processor_id" {
  description = "Full processor resource name, e.g. projects/PROJECT/locations/eu/processors/PROCESSOR_ID"
  value       = google_document_ai_processor.processor.name
}

output "processor_short_id" {
  value = google_document_ai_processor.processor.id
}

output "processor_location" {
  value = google_document_ai_processor.processor.location
}
