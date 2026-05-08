# Automated Contract Review

GCP pipeline: raw PDF → Firestore metadata → Document AI → DLP redaction → Gemini → archived PDF.

## Layout

- Terraform: `infra/terraform/envs/{dev,prod}` (roots) and `infra/terraform/modules`
- Pipeline workflow: `workflows/contract-pipeline.yaml`
- Service code: `services/{ingest_fn,dispatcher,docai,pii-redaction,gemini-analysis,finalize}` (Phase 2 stubs land here)
- Shared payload/status contract: `services/contracts`
- CI: `.github/workflows`

## Pipeline

```
raw GCS finalize -> ingest_fn (Cloud Function gen2)
                  -> contractJobs/{jobId} in Firestore
                  -> Pub/Sub jobs topic (7d retention buffer)
                  -> dispatcher Cloud Run (max=5, concurrency=1)
                  -> Cloud Workflows execution
                       docai service (/extract -> docai_done + extractedTextRef)
                       DLP de-identify
                       Gemini sync OR Vertex Batch Prediction (LRO + poll)
                       finalize (move to processed bucket)
```

Backpressure is enforced at the dispatcher (Cloud Run scaling caps), and Pub/Sub buffers anything beyond that. Long-running document analyses run as LROs so no HTTP timeouts apply.

## Terraform

Always run commands from an env directory (not `infra/terraform` alone).

```bash
cd infra/terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars   # edit values
terraform init && terraform validate && terraform plan -var-file=terraform.tfvars
```

Repeat under `envs/prod` with its `terraform.tfvars`.

**State:** `dev` uses `gcs` ([`envs/dev/backend.tf`](infra/terraform/envs/dev/backend.tf)). Set `terraform_state_access_members` in `terraform.tfvars` so Terraform can manage bucket IAM for that backend. `prod` has no `backend.tf` yet. [`infra/terraform/backend.tf`](infra/terraform/backend.tf) is a local-state stub for legacy root use.

The dev stack provisions Document AI processor and DLP templates as Terraform-managed resources, so `terraform apply` is fully self-contained — no manual processor/template IDs in tfvars.

## Image build

Cloud Run services pull images from Artifact Registry (repo created by Terraform). Push images via `service-build.yml` on `main`:

```bash
gh workflow run service-build.yml
```

Required secrets:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_BUILD_SA` - service account with `roles/artifactregistry.writer`
- `GCP_PROJECT_ID`

The build SA principal also needs to be in `ci_writer_members` in tfvars so the AR repo grants it write access.

## GitHub Actions

For `terraform-plan.yml`: set secrets `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_TERRAFORM_SA`. Also run `service-ci.yml` for app lint/test.

## Security

No SA JSON keys in repo or secrets; use OIDC + Workload Identity Federation. Treat raw extracted text as sensitive (short retention); Gemini only sees redacted output.
