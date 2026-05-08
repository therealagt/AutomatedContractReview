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
