# ingest_fn

GCS finalize -> Firestore job record -> Pub/Sub publish.

Triggered by `google.cloud.storage.object.v1.finalized` on the raw PDF bucket. Creates `contractJobs/{jobId}` and publishes a job event onto the pipeline topic. Cloud Workflows is started by the `dispatcher` service downstream.

## Env

- `PROJECT_ID`
- `JOBS_TOPIC_NAME`

## Local

```bash
pip install -r requirements.txt
functions-framework --target=ingest --signature-type=cloudevent
```
