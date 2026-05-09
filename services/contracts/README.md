# contracts

Shared payload/status contract for all pipeline stages.

## Job payload (`schemaVersion: v1`)

```json
{
  "schemaVersion": "v1",
  "jobId": "uuid",
  "source": {
    "bucket": "raw-bucket",
    "object": "path/file.pdf",
    "generation": "1234567890"
  }
}
```

## Firestore status model

- `queued`
- `docai_done`
- `redacted`
- `analyzed`
- `finalized`
- `failed`

## Allowed transitions

- `queued -> docai_done`
- `docai_done -> redacted`
- `redacted -> analyzed`
- `analyzed -> finalized`
- `* -> failed`

The finalize Cloud Run service also accepts `redacted` when the workflow used the Gemini **batch** path: the workflow polls Vertex until output exists, then finalize copies the source PDF and sets `finalized` without a separate `analyzed` Firestore write from the Gemini service.
