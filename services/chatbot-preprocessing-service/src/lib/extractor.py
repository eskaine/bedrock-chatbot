"""
extractor.py — file-type dispatch via a registry pattern.

Each extractor receives the raw bytes of the S3 object and returns plain text.
Register new formats with @register('<extension>').
"""

import json
import logging
import os
from io import BytesIO
from typing import Callable

from pypdf import PdfReader

from shared.exceptions import ValidationError

logger = logging.getLogger(__name__)

_REGISTRY: dict[str, Callable[[bytes], str]] = {}


def register(ext: str) -> Callable:
    def decorator(fn: Callable[[bytes], str]) -> Callable[[bytes], str]:
        _REGISTRY[ext.lower()] = fn
        return fn
    return decorator


def extract_text(raw_bytes: bytes, key: str) -> str:
    ext = os.path.splitext(key)[1].lower()
    extractor = _REGISTRY.get(ext)
    if extractor is None:
        raise ValidationError(f"Unsupported file extension '{ext}'", context={'key': key})
    logger.info("Extracting text", extra={'extension': ext, 'key': key})
    return extractor(raw_bytes)


@register('.txt')
@register('.md')
def _extract_text(raw_bytes: bytes) -> str:
    return raw_bytes.decode('utf-8')


@register('.json')
def _extract_json(raw_bytes: bytes) -> str:
    data = json.loads(raw_bytes.decode('utf-8'))
    return json.dumps(data, indent=2)


@register('.pdf')
def _extract_pdf(raw_bytes: bytes) -> str:
    reader = PdfReader(BytesIO(raw_bytes))
    pages = [page.extract_text() for page in reader.pages if page.extract_text()]
    if not pages:
        raise ValidationError("PDF contains no extractable text")
    return '\n'.join(pages)
