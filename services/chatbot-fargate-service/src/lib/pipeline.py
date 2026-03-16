import base64
import json
import logging
import re
from collections.abc import Generator

from shared.exceptions import ValidationError
from lib.constants import ERROR_MESSAGE
from lib.invoker import invoke_streaming
from lib.polly import synthesize
from lib.validators import check_rate_limit, detect_prompt_injection, validate_user_input

logger = logging.getLogger(__name__)

# Split on sentence-ending punctuation followed by whitespace
_SENTENCE_RE = re.compile(r'(?<=[.!?])\s+')


def stream_voice_response(
    transcription: str,
    client_ip: str | None,
    session_id: str | None,
) -> Generator[str, None, None]:
    """Stream voice pipeline: validate → LLM stream → Polly per sentence → NDJSON.

    Yields:
        {"type": "transcription", "text": "..."}  — once, immediately
        {"type": "chunk", "text": "..."}          — raw LLM text for real-time display
        {"type": "audio", "audio": "..."}         — base64 MP3 per synthesized sentence
        {"type": "done"}                          — when complete
        {"type": "error", "error": "..."}         — on failure
    """
    try:
        check_rate_limit(client_ip)
        sanitized = validate_user_input(transcription)

        if detect_prompt_injection(sanitized):
            logger.warning("Prompt injection detected in voice input from %s", client_ip)
            raise ValidationError(ERROR_MESSAGE)

        yield json.dumps({"type": "transcription", "text": sanitized}) + "\n"

        def _synthesize_sentence(sentence: str) -> str | None:
            """Synthesize a sentence and return an audio-only JSON line."""
            sentence = sentence.strip()
            if not sentence:
                return None
            try:
                audio_data = synthesize(sentence)
                return json.dumps({
                    "type": "audio",
                    "audio": base64.b64encode(audio_data).decode(),
                }) + "\n"
            except Exception:
                logger.exception("Polly synthesis failed for sentence")
                return None

        buffer = ""
        for raw in invoke_streaming(sanitized, session_id):
            for line in raw.decode("utf-8", errors="replace").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                    if "chunk" in data:
                        buffer += data["chunk"]
                        # Stream raw text immediately for real-time display
                        yield json.dumps({"type": "chunk", "text": data["chunk"]}) + "\n"
                        # Synthesize complete sentences for audio
                        parts = _SENTENCE_RE.split(buffer)
                        for sentence in parts[:-1]:
                            result = _synthesize_sentence(sentence)
                            if result:
                                yield result
                        buffer = parts[-1]
                    elif "response" in data:
                        buffer = data["response"]
                        yield json.dumps({"type": "chunk", "text": data["response"]}) + "\n"
                    elif "error" in data:
                        raise RuntimeError(data["error"])
                except json.JSONDecodeError:
                    pass

        if buffer.strip():
            result = _synthesize_sentence(buffer)
            if result:
                yield result

        yield json.dumps({"type": "done"}) + "\n"

    except ValidationError as e:
        logger.warning("Voice validation error: %s", e)
        yield json.dumps({"type": "error", "error": str(e)}) + "\n"
    except Exception as e:
        logger.error("Voice stream error: %s", e, exc_info=True)
        yield json.dumps({"type": "error", "error": "Internal server error"}) + "\n"


def stream_chat_response(
    user_message: str,
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

        yield from invoke_streaming(sanitized, session_id)

    except ValidationError as e:
        logger.warning("Validation error: %s", e)
        yield json.dumps({"error": str(e)}) + "\n"
    except Exception as e:
        logger.error("Unhandled error: %s", e, exc_info=True)
        yield json.dumps({"error": "Internal server error"}) + "\n"
