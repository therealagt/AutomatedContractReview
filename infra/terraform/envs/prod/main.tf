# Prod environment: same topology as dev; Cloud Run scaling defaults are higher for finalize.
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
  lifecycle_days_raw       = 14
  lifecycle_days_processed = 730
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
      "roles/storage.objectAdmin",
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
      "roles/datastore.user",
      "roles/documentai.apiUser",
      "roles/aiplatform.user",
      "roles/iam.serviceAccountTokenCreator",
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
  min_instances         = 1
  max_instances         = 20
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
  min_instances         = 1
  max_instances         = 20
  timeout_seconds       = 1800
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
  min_instances         = 1
  max_instances         = 20
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
  min_instances         = 1
  max_instances         = 20
  env_vars = {
    PROJECT_ID       = var.project_id
    PROCESSED_BUCKET = module.storage.processed_bucket_name
  }
}

module "workflows" {
  source = "../../modules/workflows"

  depends_on = [module.apis, module.docai_service, module.dlp_service, module.gemini_service, module.finalize_service]

  project_id            = var.project_id
  region                = var.region
  workflow_name         = "${local.prefix}-contract-pipeline"
  workflow_source_path  = "${path.root}/../../../../workflows/contract-pipeline.yaml"
  service_account_email = module.iam.service_account_emails["workflow_sa"]
  user_env_vars = {
    GOOGLE_CLOUD_PROJECT_ID     = var.project_id
    VERTEX_REGION               = var.region
    DOCAI_SERVICE_URL           = module.docai_service.service_url
    DLP_SERVICE_URL             = module.dlp_service.service_url
    GEMINI_SERVICE_URL          = module.gemini_service.service_url
    FINALIZE_SERVICE_URL        = module.finalize_service.service_url
    DOCAI_PROCESSOR_NAME        = var.docai_processor_id
    PROCESSED_BUCKET            = module.storage.processed_bucket_name
    GEMINI_BATCH_CHAR_THRESHOLD = "200000"
  }
}

module "monitoring" {
  source = "../../modules/monitoring"

  depends_on = [module.apis, module.workflows, module.pubsub]

  project_id               = var.project_id
  environment              = var.environment
  workflow_id              = module.workflows.workflow_id
  pubsub_subscription_id   = module.pubsub.subscription_id
  notification_channel_ids = var.monitoring_notification_channel_ids
  alert_email_addresses    = var.monitoring_alert_emails

  enable_workflow_failure_alert = var.monitoring_enable_workflow_alert
  enable_pubsub_dlq_alert       = var.monitoring_enable_pubsub_dlq_alert
  enable_cloud_run_alerts       = var.monitoring_enable_cloud_run_alerts
  enable_dashboard              = var.monitoring_enable_dashboard

  cloud_run_service_names = compact([
    module.docai_service.service_name,
    module.dlp_service.service_name,
    module.gemini_service.service_name,
    module.finalize_service.service_name,
  ])

  cloud_run_5xx_threshold_per_series   = var.monitoring_cloud_run_5xx_threshold
  cloud_run_latency_threshold_seconds  = var.monitoring_cloud_run_latency_seconds
  cloud_run_dispatcher_latency_seconds = var.monitoring_cloud_run_dispatcher_latency_seconds

  enable_log_export          = var.monitoring_enable_log_export
  log_export_bucket_name     = var.monitoring_log_export_bucket_name
  log_export_filter          = var.monitoring_log_export_filter
  log_export_retention_days  = var.monitoring_log_export_retention_days
  log_export_bucket_location = var.monitoring_log_export_bucket_location
}
