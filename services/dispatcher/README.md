# dispatcher

Pub/Sub push receiver that starts Cloud Workflows executions with bounded concurrency.

Backpressure is enforced by Cloud Run, not by this code:

- `max_instance_count = 5`
- `max_instance_request_concurrency = 1`

On `ResourceExhausted` the service returns 429, so Pub/Sub re-delivers with retry backoff (configured on the subscription). On other API errors it returns 503.

## Env

- `PROJECT_ID`
- `WORKFLOW_ID` - full resource name `projects/<id>/locations/<region>/workflows/<name>`
