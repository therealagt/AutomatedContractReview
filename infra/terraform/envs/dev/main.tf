# Dev environment: shared platform (APIs, buckets, Pub/Sub, Firestore, IAM) plus
# Cloud Run pipeline services, dispatcher, ingest function and Workflows.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
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

resource "google_storage_bucket_iam_member" "terraform_state_access" {
  for_each = toset(var.terraform_state_access_members)
  bucket   = var.terraform_state_bucket_name
  role     = "roles/storage.objectAdmin"
  member   = each.value

  depends_on = [module.apis]
}

locals {
  prefix = "acr-${var.environment}"

  service_accounts = {
    "ingest-fn"        = "Ingest function runtime SA"
    dispatcher         = "Dispatcher Cloud Run runtime SA"
    "docai-service"    = "Document AI service runtime SA"
    "dlp-service"      = "PII redaction service runtime SA"
    "gemini-service"   = "Gemini analysis service runtime SA"
    "finalize-service" = "Finalize service runtime SA"
    "workflow-sa"      = "Workflow runtime SA"
  }

  service_image_names = [
    "ingest-fn",
    "dispatcher",
    "docai",
    "pii-redaction",
    "gemini-analysis",
    "finalize",
  ]

  images = {
    dispatcher      = "${module.artifact_registry.repository_uri}/dispatcher:${var.image_tag}"
    docai           = "${module.artifact_registry.repository_uri}/docai:${var.image_tag}"
    pii_redaction   = "${module.artifact_registry.repository_uri}/pii-redaction:${var.image_tag}"
    gemini_analysis = "${module.artifact_registry.repository_uri}/gemini-analysis:${var.image_tag}"
    finalize        = "${module.artifact_registry.repository_uri}/finalize:${var.image_tag}"
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

  project_id                 = var.project_id
  topic_name                 = "${local.prefix}-jobs"
  subscription_name          = "${local.prefix}-jobs-sub"
  dead_letter_topic_name     = "${local.prefix}-jobs-dlq"
  ack_deadline_seconds       = 600
  max_delivery_attempts      = 10
  message_retention_duration = "604800s"
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
    "ingest-fn" = [
      "roles/pubsub.publisher",
      "roles/datastore.user",
      "roles/eventarc.eventReceiver",
      "roles/run.invoker",
    ]
    dispatcher = [
      "roles/workflows.invoker",
      "roles/datastore.user",
      "roles/eventarc.eventReceiver",
      "roles/run.invoker",
    ]
    "docai-service" = [
      "roles/documentai.apiUser",
      "roles/storage.objectAdmin",
      "roles/datastore.user",
    ]
    "dlp-service" = [
      "roles/dlp.user",
      "roles/storage.objectAdmin",
      "roles/datastore.user",
    ]
    "gemini-service" = [
      "roles/aiplatform.user",
      "roles/storage.objectAdmin",
      "roles/datastore.user",
    ]
    "finalize-service" = [
      "roles/storage.objectAdmin",
      "roles/datastore.user",
    ]
    "workflow-sa" = [
      "roles/workflows.invoker",
      "roles/run.invoker",
      "roles/datastore.user",
      "roles/documentai.apiUser",
      "roles/aiplatform.user",
      "roles/iam.serviceAccountTokenCreator",
    ]
  }
}

module "artifact_registry" {
  source = "../../modules/artifact_registry"

  depends_on = [module.apis]

  project_id = var.project_id
  region     = var.region
  repo_id    = var.artifact_registry_repo_id

  reader_members = {
    for k in keys(local.service_accounts) : k => "serviceAccount:${k}@${var.project_id}.iam.gserviceaccount.com"
  }

  writer_members = var.ci_writer_members
}

module "docai" {
  source = "../../modules/docai"

  depends_on = [module.apis]

  project_id   = var.project_id
  location     = var.docai_location
  display_name = "${local.prefix}-form-parser"
}

module "dlp" {
  source = "../../modules/dlp"

  depends_on = [module.apis]

  project_id = var.project_id
}

module "ingest_function" {
  source = "../../modules/ingest_function"

  depends_on = [module.apis, module.iam, module.storage, module.pubsub]

  project_id            = var.project_id
  region                = var.region
  function_name         = "${local.prefix}-ingest"
  raw_bucket_name       = module.storage.raw_bucket_name
  jobs_topic_name       = module.pubsub.topic_name
  service_account_email = module.iam.service_account_emails["ingest-fn"]
  source_dir            = "${path.root}/../../../../services/ingest_fn"
  source_bucket_name    = "${local.prefix}-fn-src-${var.project_id}"

  extra_event_receivers = [
    "serviceAccount:service-${data.google_project.this.number}@gs-project-accounts.iam.gserviceaccount.com",
  ]
}

data "google_project" "this" {
  project_id = var.project_id
}

module "docai_service" {
  source = "../../modules/run_services"

  depends_on = [module.apis]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-docai"
  image                 = local.images.docai
  service_account_email = module.iam.service_account_emails["docai-service"]
  timeout_seconds       = var.docai_timeout_seconds
  env_vars = {
    PROJECT_ID           = var.project_id
    DOCAI_PROCESSOR_NAME = module.docai.processor_id
    DOCAI_LOCATION       = module.docai.processor_location
    PROCESSED_BUCKET     = module.storage.processed_bucket_name
  }
}

module "dlp_service" {
  source = "../../modules/run_services"

  depends_on = [module.apis]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-pii-redaction"
  image                 = local.images.pii_redaction
  service_account_email = module.iam.service_account_emails["dlp-service"]
  timeout_seconds       = var.docai_timeout_seconds
  env_vars = {
    PROJECT_ID          = var.project_id
    DLP_INSPECT_TMPL    = module.dlp.inspect_template_id
    DLP_DEIDENTIFY_TMPL = module.dlp.deidentify_template_id
  }
}

module "gemini_service" {
  source = "../../modules/run_services"

  depends_on = [module.apis]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-gemini-analysis"
  image                 = local.images.gemini_analysis
  service_account_email = module.iam.service_account_emails["gemini-service"]
  max_instances         = var.gemini_max_instances
  container_concurrency = 1
  timeout_seconds       = var.gemini_timeout_seconds
  env_vars = {
    PROJECT_ID                  = var.project_id
    REGION                      = var.region
    VERTEX_MODEL                = var.vertex_model
    PROCESSED_BUCKET            = module.storage.processed_bucket_name
    GEMINI_BATCH_CHAR_THRESHOLD = tostring(var.gemini_batch_char_threshold)
  }
}

module "finalize_service" {
  source = "../../modules/run_services"

  depends_on = [module.apis]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-finalize"
  image                 = local.images.finalize
  service_account_email = module.iam.service_account_emails["finalize-service"]
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
  service_account_email = module.iam.service_account_emails["workflow-sa"]

  user_env_vars = {
    GOOGLE_CLOUD_PROJECT_ID     = var.project_id
    VERTEX_REGION               = var.region
    DOCAI_SERVICE_URL           = module.docai_service.service_url
    DLP_SERVICE_URL             = module.dlp_service.service_url
    GEMINI_SERVICE_URL          = module.gemini_service.service_url
    FINALIZE_SERVICE_URL        = module.finalize_service.service_url
    DOCAI_PROCESSOR_NAME        = module.docai.processor_id
    PROCESSED_BUCKET            = module.storage.processed_bucket_name
    GEMINI_BATCH_CHAR_THRESHOLD = tostring(var.gemini_batch_char_threshold)
  }
}

module "dispatcher" {
  source = "../../modules/dispatcher_service"

  depends_on = [module.apis, module.iam, module.workflows, module.pubsub, google_service_account_iam_member.pubsub_token_creator]

  project_id            = var.project_id
  region                = var.region
  service_name          = "${local.prefix}-dispatcher"
  image                 = local.images.dispatcher
  service_account_email = module.iam.service_account_emails["dispatcher"]
  workflow_id           = module.workflows.workflow_id
  jobs_topic_id         = module.pubsub.topic_id
  max_instances         = var.dispatcher_max_instances
}

module "monitoring" {
  source = "../../modules/monitoring"

  depends_on = [module.apis, module.workflows, module.pubsub]

  project_id               = var.project_id
  environment              = var.environment
  workflow_id              = module.workflows.workflow_id
  pubsub_subscription_id   = "${local.prefix}-jobs-sub"
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
    module.dispatcher.service_name,
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

# Pub/Sub service agent must mint OIDC tokens for Eventarc push to Cloud Run.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${module.iam.service_account_emails["dispatcher"]}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"

  depends_on = [module.apis]
}
