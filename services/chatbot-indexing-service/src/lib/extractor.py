import logging
from collections.abc import Callable
from io import BytesIO
from pathlib import Path

from pypdf import PdfReader

from shared.exceptions import ServiceError, ValidationError

logger = logging.getLogger(__name__)

# Registry mapping file extension → extractor function.
# To support a new file type, add an entry here — no other changes needed.
_EXTRACTORS: dict[str, Callable] = {}


def register(ext: str) -> Callable:
    """Decorator to register an extractor for a given file extension."""
    def decorator(func: Callable) -> Callable:
        _EXTRACTORS[ext.lower()] = func
        return func
    return decorator


def extract_text(key: str, body) -> str:
    """Dispatch to the registered extractor based on the S3 object key extension."""
    ext = Path(key).suffix.lower()
    handler = _EXTRACTORS.get(ext)
    if not handler:
        raise ValidationError("Unsupported file type", context={"key": key, "ext": ext})
    return handler(body)


@register('.pdf')
def _extract_pdf(file_stream) -> str:
    try:
        pdf_bytes = BytesIO(file_stream.read())
        reader = PdfReader(pdf_bytes)
        text = ''.join(page.extract_text() + '\n' for page in reader.pages)
        logger.info("Extracted %d characters from PDF (%d pages)", len(text), len(reader.pages))
        return text
    except (ServiceError, ValidationError):
        raise
    except Exception as e:
        raise ServiceError("PDF extraction failed", context={"error": str(e)}) from e


@register('.txt')
def _extract_txt(file_stream) -> str:
    try:
        text = file_stream.read().decode('utf-8')
        logger.info("Extracted %d characters from text file", len(text))
        return text
    except Exception as e:
        raise ServiceError("Text file read failed", context={"error": str(e)}) from e
