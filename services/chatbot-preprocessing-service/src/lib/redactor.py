"""
redactor.py — applies custom regex PII patterns to formatted text.

Applied after Bedrock formatting, before PDF generation.
Patterns are defined in sensitive_patterns.py.
"""

import logging

from lib.sensitive_patterns import CUSTOM_PATTERNS

logger = logging.getLogger(__name__)


def redact(text: str) -> str:
    for pattern in CUSTOM_PATTERNS:
        redacted = pattern.pattern.sub(pattern.replacement, text)
        if redacted != text:
            logger.info("Redacted PII pattern", extra={'pattern_name': pattern.name})
            text = redacted
    return text
