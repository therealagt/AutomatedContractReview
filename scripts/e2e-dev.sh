#!/usr/bin/env bash
# Manual smoke: upload a PDF to the raw bucket and verify Firestore job + Pub/Sub flow.
# Prerequisites: gcloud auth, PROJECT_ID, raw bucket name, Firestore contractJobs access.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${RAW_BUCKET:?set RAW_BUCKET (acr-dev-raw-pdf or your stack raw bucket)}"
: "${TEST_PDF:?set TEST_PDF to a local .pdf path}"

if [[ ! "${TEST_PDF}" =~ \.[pP][dD][fF]$ ]]; then
	echo "TEST_PDF must end in .pdf" >&2
	exit 1
fi

obj="e2e/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "${TEST_PDF}")"
echo "Uploading gs://${RAW_BUCKET}/${obj}"
gcloud storage cp "${TEST_PDF}" "gs://${RAW_BUCKET}/${obj}" --project="${PROJECT_ID}"

echo "Waiting for ingest (finalize)…"
sleep 15

echo "Verify in console or API: Firestore collection contractJobs for a new jobId (status queued → …)."
echo "Check Cloud Logging: ingest_fn and dispatcher JSON logs (jobId, executionName); Workflows execution state."
