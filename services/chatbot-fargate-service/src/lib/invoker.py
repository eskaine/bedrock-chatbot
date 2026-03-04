"""
invoker.py — chatbot-fargate-service

Handles communication with the downstream streaming Lambda.

This is the primary swap point for the underlying LLM backend. To replace
the orchestration Lambda with a different provider (e.g. direct Bedrock,
OpenAI, a local model), only this module needs to change.
"""

import json
import logging
from collections.abc import Generator

import boto3

from shared.exceptions import ExternalServiceError
from lib.config import config

logger = logging.getLogger(__name__)

_lambda_client = boto3.client("lambda", region_name=config.region)


def invoke_streaming(
    message: str,
    category: str | None,
    session_id: str | None,
) -> Generator[str, None, None]:
    """
    Invoke the orchestration Lambda and stream its response chunks.

    Yields raw payload bytes (NDJSON lines) as they arrive from the Lambda
    event stream. The caller is responsible for catching exceptions.
    """
    payload = json.dumps({
        "headers": {"x-session-id": session_id or ""},
        "body": json.dumps({"message": message, "category": category}),
    })

    try:
        response = _lambda_client.invoke_with_response_stream(
            FunctionName=config.streaming_lambda_arn,
            InvocationType="RequestResponse",
            Payload=payload,
        )
    except Exception as e:
        raise ExternalServiceError(
            "Failed to invoke streaming Lambda",
            context={"arn": config.streaming_lambda_arn},
        ) from e

    for event in response["EventStream"]:
        if "PayloadChunk" in event:
            yield event["PayloadChunk"]["Payload"]
        elif "InvokeComplete" in event:
            error_code = event["InvokeComplete"].get("ErrorCode")
            if error_code:
                logger.error("Lambda invocation error: %s", error_code)
                yield json.dumps({"error": "Internal server error"}) + "\n"
            break
