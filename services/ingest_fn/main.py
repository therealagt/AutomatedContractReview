"""Ingest function: GCS finalize -> Firestore job record -> Pub/Sub publish.

Stub implementation; Phase 2 will replace with proper validation, content-type checks,
and structured logging via google-cloud-logging.
"""

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timezone

import functions_framework
from cloudevents.http import CloudEvent
from google.cloud import firestore, pubsub_v1


_PROJECT_ID = os.environ["PROJECT_ID"]
_JOBS_TOPIC = os.environ["JOBS_TOPIC_NAME"]

_firestore_client = firestore.Client(project=_PROJECT_ID)
_publisher = pubsub_v1.PublisherClient()
_topic_path = _publisher.topic_path(_PROJECT_ID, _JOBS_TOPIC)


@functions_framework.cloud_event
def ingest(event: CloudEvent) -> None:
    data = event.data or {}
    bucket = data.get("bucket")
    name = data.get("name")
    generation = data.get("generation")

    if not bucket or not name:
        return

    if not name.lower().endswith(".pdf"):
        return

    job_id = uuid.uuid4().hex
    now = datetime.now(timezone.utc).isoformat()

    _firestore_client.collection("contractJobs").document(job_id).set(
        {
            "jobId": job_id,
            "status": "queued",
            "createdAt": now,
            "source": {
                "bucket": bucket,
                "object": name,
                "generation": generation,
            },
        }
    )

    payload = json.dumps(
        {
            "jobId": job_id,
            "source": {
                "bucket": bucket,
                "object": name,
                "generation": generation,
            },
        }
    ).encode("utf-8")

    future = _publisher.publish(_topic_path, payload, jobId=job_id)
    future.result(timeout=30)
