variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "environment" {
  type = string
}

variable "docai_processor_id" {
  type = string
}

variable "vertex_model" {
  type = string
}

variable "dlp_template_ids" {
  type = object({
    inspect    = string
    deidentify = string
  })
}

variable "service_images" {
  description = "Container images per service."
  type = object({
    docai           = string
    pii_redaction   = string
    gemini_analysis = string
    finalize        = string
  })
}
