# Automated Contract Review

Event-driven legal document pipeline on GCP:

1. PDF uploaded to raw bucket
2. Ingest metadata written to Firestore
3. Text extracted with Document AI
4. PII redacted with Cloud DLP
5. Redacted text analyzed with Vertex AI Gemini
6. PDF archived in processed bucket

## Bootstrap Guide

This project is intentionally set up for **local-first infrastructure authoring** so you can progress before full cloud access is available.

### 1) Prerequisites

- Terraform `>= 1.6`
- `gcloud` CLI
- GitHub repository with Actions enabled
- A GCP project ID (dev/prod can be placeholders initially)

### 2) Repository Layout

- Infrastructure: `infra/terraform`
- Runtime workflow: `workflows/contract-pipeline.yaml`
- CI workflows: `.github/workflows`

### 3) Local Terraform Bootstrap (No Remote State Yet)

The root Terraform backend currently uses local state (`infra/terraform/backend.tf`).

```bash
cd infra/terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your values
terraform init
terraform validate
terraform plan -var-file=terraform.tfvars
```

Run the same flow for prod:

```bash
cd infra/terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your values
terraform init
terraform validate
terraform plan -var-file=terraform.tfvars
```

### 4) Switch to GCS Remote State (When Ready)

Once billing/project linkage is ready, create the state bucket(s), then change backend from local to `gcs` in `infra/terraform/backend.tf`.

Recommended pattern:
- One state bucket per environment, or one bucket with per-env prefixes
- Versioning enabled
- Uniform bucket-level access enabled
- Public access prevention enforced

Then reinitialize:

```bash
cd infra/terraform/envs/dev
terraform init -reconfigure
```

### 5) GitHub Actions Setup

Workflows:
- `terraform-plan.yml`: runs `fmt`, `init`, `validate`, `plan` on push/PR to `main`
- `service-ci.yml`: lint/test scaffold

Configure these repository secrets for Terraform workflow:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_TERRAFORM_SA`

### 6) First Successful Plan Checklist

- `terraform fmt -check -recursive` passes
- `terraform validate` passes for `dev` and `prod`
- `terraform plan` generates `tfplan`
- GitHub Action uploads plan artifact for both environments

## Security Notes

- No service account JSON keys in repository or GitHub secrets
- Use GitHub OIDC + Workload Identity Federation
- Gemini analysis only receives redacted text output
- Raw extracted text is treated as sensitive and should be short-retention
