# Architecture Decisions

## Context

This system processes legal PDFs and must enforce privacy controls before any LLM analysis. The design prioritizes strong data handling guarantees, operational simplicity, and incremental rollout.

## Core Decisions

### 1) Serverless-First Runtime

- Use managed services first: Cloud Storage, Pub/Sub, Cloud Workflows, Cloud Run, Firestore.
- Avoid VM-based/self-managed orchestration.
- Benefit: lower ops overhead, easier scaling, cleaner IAM boundaries.

### 2) Privacy-First Processing

- Document AI extraction is followed by mandatory Cloud DLP redaction.
- Vertex AI Gemini receives **redacted text only**.
- Any non-redacted payload to analysis service is rejected by contract.
- Raw extracted text is treated as sensitive and should have strict retention and access controls.

### 3) Event-Driven Orchestration With Explicit Workflow

- Storage finalize event starts ingestion.
- Ingestion publishes job event to Pub/Sub.
- A bounded-concurrency dispatcher Cloud Run service reads from Pub/Sub and starts Cloud Workflows executions.
- Cloud Workflows executes a deterministic, step-based pipeline with retry semantics and built-in LRO polling.
- Firestore acts as source of truth for job status and audit fields.

### 4) Backpressure and Quota Resilience

- **Buffer:** Pub/Sub topic with 7-day retention puffers bursts. The pull subscription has `retry_policy`, dead-letter, and `enable_exactly_once_delivery`.
- **Backpressure:** The dispatcher Cloud Run service has `max_instance_count = 5` and `max_instance_request_concurrency = 1`. At most 5 workflow executions are started in parallel; the rest stays queued in Pub/Sub.
- **Async LRO for long documents:** The workflow calls Document AI `batchProcessDocuments` and polls operations until done. Long Gemini analyses route through Vertex AI Batch Prediction (GCS in/out, no HTTP timeout).
- **Gemini quota:** The `gemini-analysis` Cloud Run service has `max_instance_count = 5` and `max_instance_request_concurrency = 1`, capping concurrent Vertex calls. Service code applies exponential backoff on `RESOURCE_EXHAUSTED`.

### 5) Infrastructure as Code via Terraform

- All resources provisioned from `infra/terraform`.
- Reusable modules for storage, pubsub, firestore, iam, run services, workflows, monitoring, artifact_registry, docai, dlp, ingest_function, dispatcher_service.
- Document AI processor and DLP templates are Terraform-managed; no manual IDs in tfvars.
- GCS backend used for dev (`envs/dev/backend.tf`); prod backend pending.

### 6) Least Privilege IAM

- Dedicated service account per runtime component (ingest, dispatcher, docai, dlp, gemini, finalize, workflow).
- Roles assigned per component scope only.
- CI uses Workload Identity Federation from GitHub OIDC (no static keys).
- Pub/Sub service agent has `iam.serviceAccountTokenCreator` on the dispatcher SA so Eventarc can mint OIDC tokens for Cloud Run pushes.

### 7) CI/CD Guardrails

- GitHub Actions runs Terraform checks/plans on push/PR to `main`.
- `service-build.yml` builds and pushes Cloud Run images to Artifact Registry on changes under `services/**`.
- Plan artifacts are retained for review/audit.
- Branch protections should require Terraform plan job success.

## Data Flow

1. User uploads PDF to raw bucket.
2. Ingest function creates `contractJobs/{jobId}` record in Firestore.
3. Ingest function publishes `{jobId, source}` to Pub/Sub.
4. Dispatcher Cloud Run consumes (Eventarc push) and calls `workflows.executions.create`.
5. Workflow calls Document AI `batchProcessDocuments` (LRO) and polls until done.
6. Workflow calls DLP service to redact extracted text.
7. Workflow routes to Gemini sync or Vertex Batch Prediction based on `GEMINI_BATCH_CHAR_THRESHOLD`.
8. Finalizer moves PDF to processed bucket and marks job complete.

## Mermaid Architecture Diagram

```mermaid
flowchart LR
    user[UserUploader] --> rawBucket[RawPdfBucket]
    rawBucket --> ingestFn[IngestFunction]
    ingestFn -->|Create job metadata| firestore[(Firestore contractJobs)]
    ingestFn -->|Publish jobCreated| jobsTopic[PubSubJobsTopic]
    jobsTopic -->|Eventarc push| dispatcher[DispatcherRun]
    dispatcher -->|executions.create rate-limited| workflow[CloudWorkflowsPipeline]

    workflow --> docAiSvc[DocAiService]
    docAiSvc --> docaiProc[DocAiProcessorEU]
    docAiSvc -->|Extracted text ref| firestore

    workflow --> dlpSvc[PiiRedactionService]
    dlpSvc -->|Redacted text ref and findings| firestore

    workflow --> geminiSvc[GeminiAnalysisService]
    geminiSvc -->|sync online predict| vertex[VertexAiGemini]
    geminiSvc -->|long doc batch predict| vertexBatch[VertexBatchPrediction]
    geminiSvc -->|Analysis result ref| firestore

    workflow --> finalizeSvc[FinalizeService]
    finalizeSvc --> processedBucket[ProcessedPdfBucket]
    finalizeSvc -->|status processed| firestore

    subgraph securityBoundaries [SecurityBoundaries]
      iam[IamLeastPrivilege]
      oidc[GitHubOidcWorkloadIdentity]
      redactionGate[RedactionBeforeLLM]
      backpressure[DispatcherBackpressure]
      lro[AsyncLROForLongDocs]
    end
```

## Non-Goals (Current Iteration)

- No direct end-user UI in this repository yet.
- No synchronous request/response processing path.
- No custom model fine-tuning pipeline.
