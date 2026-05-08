# ingest_fn

GCS finalize -> Firestore job record -> Pub/Sub publish.

Triggered by `google.cloud.storage.object.v1.finalized` on the raw PDF bucket. Creates `contractJobs/{jobId}` and publishes a job event onto the pipeline topic. Cloud Workflows is started by the `dispatcher` service downstream.

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
