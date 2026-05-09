# pii-redaction

DLP de-identify stage: reads extracted text from GCS, runs `DeidentifyContent` with Terraform-managed templates, writes redacted UTF-8 text, updates Firestore.

## Contract

- Input (workflow): `jobId`, `extractedTextRef` (`gs://` prefix or object path under processed bucket)
- Requires Firestore status `docai_done`; transitions to `redacted`
- Response body: `jobId`, `status`, `redactedTextRef`, `redactedTextLength` (rune count for Gemini threshold)

## Endpoints

- `GET /healthz`
- `POST /` (Cloud Workflows posts to service root URL)

## Env

- `PROJECT_ID`
- `DLP_INSPECT_TMPL` (full inspect template resource name)
- `DLP_DEIDENTIFY_TMPL` (full de-identify template resource name)

Runtime SA needs Firestore update, GCS read under `extracted/`, GCS write under `redacted/`, and `roles/dlp.user`.

## Local

```bash
go mod tidy
PROJECT_ID=... DLP_INSPECT_TMPL=... DLP_DEIDENTIFY_TMPL=... go run ./main.go
```
