import re
import time

from shared.exceptions import ValidationError
from lib.constants import (
    MAX_MESSAGE_LENGTH,
    MIN_MESSAGE_LENGTH,
    RATE_LIMIT_MAX_REQUESTS,
    RATE_LIMIT_WINDOW_SECONDS,
)

# Simple in-memory rate limiter (use Redis/DynamoDB in production)
request_tracker: dict[str, list[float]] = {}


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

    if not re.match(r'^[\w\s\.,!?\-\'\"()\n]+$', user_message, re.UNICODE):
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
    """Raise ValidationError if the client has exceeded the rate limit."""
    if not client_ip:
        return

    current_time = time.time()

    request_tracker[client_ip] = [
        ts for ts in request_tracker.get(client_ip, [])
        if current_time - ts < window_seconds
    ]

    if len(request_tracker[client_ip]) >= max_requests:
        raise ValidationError(
            "Rate limit exceeded",
            context={"ip": client_ip, "limit": max_requests, "window_seconds": window_seconds},
        )

    request_tracker[client_ip].append(current_time)


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
