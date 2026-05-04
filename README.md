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

**State:** `dev` uses `gcs` ([`envs/dev/backend.tf`](infra/terraform/envs/dev/backend.tf)). Set `terraform_state_access_members` in `terraform.tfvars` so Terraform can manage bucket IAM for that backend. `prod` has no `backend.tf` yet. [`infra/terraform/backend.tf`](infra/terraform/backend.tf) is a local-state stub for legacy root use.

## GitHub Actions

For `terraform-plan.yml`: set secrets `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_TERRAFORM_SA`. Also run `service-ci.yml` for app lint/test.

## Security

No SA JSON keys in repo or secrets; use OIDC + Workload Identity Federation. Treat raw extracted text as sensitive (short retention); Gemini only sees redacted output.
