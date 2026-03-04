import logging
import time
from functools import wraps
from typing import Callable, TypeVar

from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)

_RETRYABLE_CODES = frozenset({
    'ThrottlingException',
    'TooManyRequestsException',
    'ServiceUnavailableException',
})

F = TypeVar('F', bound=Callable)


def aws_retry(max_attempts: int = 3, base_delay: float = 1.0) -> Callable[[F], F]:
    """
    Decorator: retry an AWS SDK call with exponential backoff on throttling.

    Non-throttling ClientErrors and all other exceptions propagate immediately.
    Only ClientErrors with codes in _RETRYABLE_CODES trigger a retry.

    Usage:
        @aws_retry(max_attempts=3, base_delay=1.0)
        def call_bedrock(...):
            ...
    """
    def decorator(func: F) -> F:
        @wraps(func)
        def wrapper(*args, **kwargs):
            last_error: ClientError | None = None
            for attempt in range(max_attempts):
                try:
                    return func(*args, **kwargs)
                except ClientError as e:
                    if e.response['Error']['Code'] not in _RETRYABLE_CODES:
                        raise
                    last_error = e
                    if attempt < max_attempts - 1:
                        delay = base_delay * (2 ** attempt)
                        logger.warning(
                            "AWS throttled [%s], retrying in %.1fs (%d/%d)",
                            e.response['Error']['Code'], delay, attempt + 1, max_attempts,
                        )
                        time.sleep(delay)
            raise last_error  # type: ignore[misc]
        return wrapper  # type: ignore[return-value]
    return decorator
