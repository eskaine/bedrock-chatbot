import json
import logging
from collections.abc import Generator

from shared.exceptions import ValidationError
from lib.constants import ERROR_MESSAGE
from lib.invoker import invoke_streaming
from lib.validators import check_rate_limit, detect_prompt_injection, validate_user_input

logger = logging.getLogger(__name__)


def stream_chat_response(
    user_message: str,
    category: str | None,
    client_ip: str | None,
    session_id: str | None,
) -> Generator[str, None, None]:
    """
    Orchestrate the full chat pipeline: validate → invoke → stream.

    Yields NDJSON strings suitable for a FastAPI StreamingResponse.
    All errors are caught and surfaced as JSON error lines so the HTTP
    connection stays open and the client receives a structured response.
    """
    try:
        check_rate_limit(client_ip)
        sanitized = validate_user_input(user_message)

        if detect_prompt_injection(sanitized):
            logger.warning("Prompt injection detected from %s", client_ip)
            yield json.dumps({"error": ERROR_MESSAGE}) + "\n"
            return

        yield from invoke_streaming(sanitized, category, session_id)

    except ValidationError as e:
        logger.warning("Validation error: %s", e)
        yield json.dumps({"error": str(e)}) + "\n"
    except Exception as e:
        logger.error("Unhandled error: %s", e, exc_info=True)
        yield json.dumps({"error": "Internal server error"}) + "\n"
