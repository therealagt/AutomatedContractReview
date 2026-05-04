# Automated Contract Review

GCP pipeline: raw PDF → Firestore metadata → Document AI → DLP redaction → Gemini → archived PDF.

## Layout

- Terraform: `infra/terraform/envs/{dev,prod}` (roots) and `infra/terraform/modules`
- Event workflow: `workflows/contract-pipeline.yaml`
- CI: `.github/workflows`

## Terraform

Always run commands from an env directory (not `infra/terraform` alone).

```bash
cd infra/terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars   # edit values
terraform init && terraform validate && terraform plan -var-file=terraform.tfvars
```

Repeat under `envs/prod` with its `terraform.tfvars`.

**State:** `dev` uses a `gcs` backend ([`envs/dev/backend.tf`](infra/terraform/envs/dev/backend.tf)); create the bucket and grant state access before `init`. `prod` has no `backend.tf` yet—add `gcs` when you want remote state. [`infra/terraform/backend.tf`](infra/terraform/backend.tf) is a local-state stub for any legacy root use; env backends are independent.

## GitHub Actions

For `terraform-plan.yml`: set secrets `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_TERRAFORM_SA`. Also run `service-ci.yml` for app lint/test.

## Security

No SA JSON keys in repo or secrets; use OIDC + Workload Identity Federation. Treat raw extracted text as sensitive (short retention); Gemini only sees redacted output.
