# ingest_fn

GCS finalize -> Firestore job record -> Pub/Sub publish.

Triggered by `google.cloud.storage.object.v1.finalized` on the raw PDF bucket. Creates `contractJobs/{jobId}` and publishes a job event onto the pipeline topic. Cloud Workflows is started by the `dispatcher` service downstream.

Terraform deploy uses Cloud Functions 2nd gen runtime **`go125`** (see ingest module). Successful publishes log JSON with `jobId`, `bucket`, `object`.

## Env

- `PROJECT_ID`
- `JOBS_TOPIC_NAME`

## Local

```bash
go mod tidy
go run github.com/GoogleCloudPlatform/functions-framework-go/funcframework \
  --target=Ingest \
  --signature-type=cloudevent
```

## Dev smoke

See [`scripts/e2e-dev.sh`](../../scripts/e2e-dev.sh): upload a PDF to the raw bucket and confirm Firestore plus logs.
