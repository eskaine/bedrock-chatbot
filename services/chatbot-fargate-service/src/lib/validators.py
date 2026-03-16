import logging
import re
import time

import boto3

from shared.exceptions import ValidationError
from lib.config import config
from lib.constants import (
    MAX_MESSAGE_LENGTH,
    MIN_MESSAGE_LENGTH,
    RATE_LIMIT_MAX_REQUESTS,
    RATE_LIMIT_WINDOW_SECONDS,
)

logger = logging.getLogger(__name__)

# In-memory fallback — used only when SESSIONS_TABLE is not configured
_request_tracker: dict[str, list[float]] = {}

# DynamoDB table reference — initialised once at module load if sessions_table is set
_rate_limit_table = (
    boto3.resource('dynamodb', region_name=config.region).Table(config.sessions_table)
    if config.sessions_table
    else None
)


def validate_user_input(user_message: str) -> str:
    """Validate and sanitize user input. Raises ValidationError on failure."""
    if not user_message or not user_message.strip():
        raise ValidationError("Message cannot be empty")

    if len(user_message) > MAX_MESSAGE_LENGTH:
        raise ValidationError(
            "Message too long",
            context={"length": len(user_message), "max": MAX_MESSAGE_LENGTH},
        )

    if len(user_message.strip()) < MIN_MESSAGE_LENGTH:
        raise ValidationError(
            "Message too short",
            context={"length": len(user_message.strip()), "min": MIN_MESSAGE_LENGTH},
        )

    if re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', user_message):
        raise ValidationError("Message contains invalid characters")

    sanitized = user_message.strip()
    sanitized = re.sub(r'\s+', ' ', sanitized)
    sanitized = re.sub(r'\n{3,}', '\n\n', sanitized)

    return sanitized


def check_rate_limit(
    client_ip: str | None,
    max_requests: int = RATE_LIMIT_MAX_REQUESTS,
    window_seconds: int = RATE_LIMIT_WINDOW_SECONDS,
) -> None:
    """Raise ValidationError if the client has exceeded the rate limit.

    Uses DynamoDB atomic counters when SESSIONS_TABLE is configured so the
    limit is enforced consistently across all Fargate tasks. Falls back to
    an in-memory tracker if the table is not available.
    """
    if not client_ip:
        raise ValidationError("Request origin could not be determined")

    if _rate_limit_table is not None:
        _check_rate_limit_dynamo(client_ip, max_requests, window_seconds)
    else:
        _check_rate_limit_memory(client_ip, max_requests, window_seconds)


def _check_rate_limit_dynamo(client_ip: str, max_requests: int, window_seconds: int) -> None:
    window = int(time.time()) // window_seconds
    key = f"ratelimit#{client_ip}#{window}"
    ttl = (window + 1) * window_seconds + 60  # expire 60 s after the window ends

    try:
        response = _rate_limit_table.update_item(
            Key={'sessionId': key},
            UpdateExpression='ADD #cnt :one SET #ttl = if_not_exists(#ttl, :ttl)',
            ExpressionAttributeNames={'#cnt': 'count', '#ttl': 'ttl'},
            ExpressionAttributeValues={':one': 1, ':ttl': ttl},
            ReturnValues='UPDATED_NEW',
        )
        count = int(response['Attributes']['count'])
        if count > max_requests:
            raise ValidationError(
                "Rate limit exceeded",
                context={"ip": client_ip, "limit": max_requests, "window_seconds": window_seconds},
            )
    except ValidationError:
        raise
    except Exception as e:
        logger.warning("DynamoDB rate limit check failed, falling back to memory: %s", e)
        _check_rate_limit_memory(client_ip, max_requests, window_seconds)


def _check_rate_limit_memory(client_ip: str, max_requests: int, window_seconds: int) -> None:
    current_time = time.time()
    _request_tracker[client_ip] = [
        ts for ts in _request_tracker.get(client_ip, [])
        if current_time - ts < window_seconds
    ]
    if len(_request_tracker[client_ip]) >= max_requests:
        raise ValidationError(
            "Rate limit exceeded",
            context={"ip": client_ip, "limit": max_requests, "window_seconds": window_seconds},
        )
    _request_tracker[client_ip].append(current_time)


def detect_prompt_injection(user_message: str) -> bool:
    """Return True if the message matches known prompt injection patterns."""
    injection_patterns = [
        r'ignore\s+(previous|above|all)\s+instructions',
        r'system\s*:',
        r'<\|.*?\|>',
        r'you\s+are\s+now',
        r'forget\s+everything',
        r'new\s+instructions',
        r'developer\s+mode',
    ]

    message_lower = user_message.lower()
    return any(re.search(pattern, message_lower) for pattern in injection_patterns)
