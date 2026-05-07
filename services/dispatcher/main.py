"""Dispatcher: Pub/Sub push -> Cloud Workflows execution.

Rate limiting comes from Cloud Run knobs (max_instances + concurrency=1), not from
this code. Returns 5xx on quota errors so Pub/Sub retries with backoff.
"""

from __future__ import annotations

import base64
import json
import logging
import os

from fastapi import FastAPI, HTTPException, Request, status
from google.api_core import exceptions as gax_exceptions
from google.cloud import workflows_v1
from google.cloud.workflows import executions_v1
from google.cloud.workflows.executions_v1.types import Execution


_PROJECT_ID = os.environ["PROJECT_ID"]
_WORKFLOW_ID = os.environ["WORKFLOW_ID"]

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("dispatcher")

app = FastAPI()
_executions_client = executions_v1.ExecutionsClient()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/dispatch", status_code=status.HTTP_202_ACCEPTED)
async def dispatch(request: Request) -> dict[str, str]:
    envelope = await request.json()
    message = (envelope or {}).get("message") or {}
    raw = message.get("data")
    if not raw:
        raise HTTPException(status_code=400, detail="empty message")

    try:
        payload = json.loads(base64.b64decode(raw).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise HTTPException(status_code=400, detail=f"bad payload: {exc}") from exc

    job_id = payload.get("jobId")
    if not job_id:
        raise HTTPException(status_code=400, detail="missing jobId")

    execution = Execution(argument=json.dumps(payload))
    try:
        response = _executions_client.create_execution(
            parent=_WORKFLOW_ID,
            execution=execution,
        )
    except gax_exceptions.ResourceExhausted as exc:
        logger.warning("workflows quota hit, will retry: %s", exc)
        raise HTTPException(status_code=429, detail="workflows quota") from exc
    except gax_exceptions.GoogleAPICallError as exc:
        logger.error("workflow start failed: %s", exc)
        raise HTTPException(status_code=503, detail="workflow start failed") from exc

    logger.info("started workflow execution %s for job %s", response.name, job_id)
    return {"jobId": job_id, "executionName": response.name}
