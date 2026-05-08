# docai

Contract stage service for Document AI extraction status handoff.

## Contract

- Input: shared `contracts.JobMessage` (`schemaVersion`, `jobId`, `source`)
- Reads current Firestore `contractJobs/{jobId}.status`
- Validates transition `queued -> docai_done`
- Writes merged fields: `status`, `schemaVersion`, `docaiCompletedAt`, `docaiResult.extractedTextRef`

## Endpoints

- `GET /healthz`
- `POST /extract`

## Env

- `PROJECT_ID`
- `PROCESSED_BUCKET`

## Local

```bash
go mod tidy
PROJECT_ID=your-project PROCESSED_BUCKET=your-processed-bucket go run ./main.go
```
