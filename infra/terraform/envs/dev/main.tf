terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "apis" {
  source = "../../modules/apis"

  project_id = var.project_id
  services   = var.enabled_apis
}

locals {
  prefix = "acr-${var.environment}"
  service_accounts = {
    ingest_fn        = "Ingest function runtime SA"
    docai_service    = "Document AI service runtime SA"
    dlp_service      = "PII redaction service runtime SA"
    gemini_service   = "Gemini analysis service runtime SA"
    finalize_service = "Finalize service runtime SA"
    workflow_sa      = "Workflow runtime SA"
  }
}

module "storage" {
  source = "../../modules/storage"

  depends_on = [module.apis]

  project_id               = var.project_id
  location                 = var.region
  raw_bucket_name          = "${local.prefix}-raw-pdf"
  processed_bucket_name    = "${local.prefix}-processed-pdf"
  versioning_enabled       = true
  lifecycle_days_raw       = 30
  lifecycle_days_processed = 365
}

module "pubsub" {
  source = "../../modules/pubsub"

  depends_on = [module.apis]

  project_id             = var.project_id
  topic_name             = "${local.prefix}-jobs"
  subscription_name      = "${local.prefix}-jobs-sub"
  dead_letter_topic_name = "${local.prefix}-jobs-dlq"
  ack_deadline_seconds   = 30
  max_delivery_attempts  = 10
}

module "firestore" {
  source = "../../modules/firestore"

  depends_on = [module.apis]

  project_id  = var.project_id
  location_id = var.region
}

module "iam" {
  source = "../../modules/iam"

  depends_on = [module.apis]

  project_id       = var.project_id
  service_accounts = local.service_accounts
  role_bindings = {
    ingest_fn = [
      "roles/pubsub.publisher",
      "roles/datastore.user"
    ]
    docai_service = [
      "roles/documentai.apiUser",
      "roles/storage.objectViewer",
      "roles/datastore.user"
    ]
    dlp_service = [
      "roles/dlp.user",
      "roles/datastore.user"
    ]
    gemini_service = [
      "roles/aiplatform.user",
      "roles/datastore.user"
    ]
    finalize_service = [
      "roles/storage.objectAdmin",
      "roles/datastore.user"
    ]
    workflow_sa = [
      "roles/workflows.invoker",
      "roles/run.invoker",
      "roles/datastore.user"
    ]
  }
}

module "docai_service" {
  source = "../../modules/run_services"

  depends_on = [module.apis]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-docai"
  image                 = var.service_images.docai
  service_account_email = module.iam.service_account_emails["docai_service"]
  env_vars = {
    PROJECT_ID         = var.project_id
    DOCAI_PROCESSOR_ID = var.docai_processor_id
  }
}

module "dlp_service" {
  source = "../../modules/run_services"

  depends_on = [module.apis]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-pii-redaction"
  image                 = var.service_images.pii_redaction
  service_account_email = module.iam.service_account_emails["dlp_service"]
  env_vars = {
    PROJECT_ID          = var.project_id
    DLP_INSPECT_TMPL    = var.dlp_template_ids.inspect
    DLP_DEIDENTIFY_TMPL = var.dlp_template_ids.deidentify
  }
}

module "gemini_service" {
  source = "../../modules/run_services"

  depends_on = [module.apis]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-gemini-analysis"
  image                 = var.service_images.gemini_analysis
  service_account_email = module.iam.service_account_emails["gemini_service"]
  env_vars = {
    PROJECT_ID   = var.project_id
    VERTEX_MODEL = var.vertex_model
  }
}

module "finalize_service" {
  source = "../../modules/run_services"

  depends_on = [module.apis]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-finalize"
  image                 = var.service_images.finalize
  service_account_email = module.iam.service_account_emails["finalize_service"]
  env_vars = {
    PROJECT_ID       = var.project_id
    PROCESSED_BUCKET = module.storage.processed_bucket_name
  }
}

module "workflows" {
  source = "../../modules/workflows"

  depends_on = [module.apis]

  project_id           = var.project_id
  region               = var.region
  workflow_name        = "${local.prefix}-contract-pipeline"
  workflow_source_path = "../../../workflows/contract-pipeline.yaml"
}
