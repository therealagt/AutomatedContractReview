# dispatcher

Pub/Sub push receiver that starts Cloud Workflows executions with bounded concurrency.

Backpressure is enforced by Cloud Run, not by this code:

- `max_instance_count = 5`
- `max_instance_request_concurrency = 1`

On `ResourceExhausted` the service returns 429, so Pub/Sub re-delivers with retry backoff (configured on the subscription). On other API errors it returns 503.

Logs are JSON to stdout (`severity`, `message`, `jobId`, `executionName` when a run starts) for Cloud Logging.

## Env

- `PROJECT_ID`
- `WORKFLOW_ID` - full resource name `projects/<id>/locations/<region>/workflows/<name>`

## Local

```bash
go mod tidy
PORT=8080 PROJECT_ID=your-project WORKFLOW_ID=projects/your-project/locations/europe-west1/workflows/your-workflow go run ./main.go
```

## Dev smoke

After deploy, run [`scripts/e2e-dev.sh`](../../scripts/e2e-dev.sh) with `PROJECT_ID`, `RAW_BUCKET`, and a local `TEST_PDF` path.
