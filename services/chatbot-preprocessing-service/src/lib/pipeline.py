"""
pipeline.py — orchestrates the full preprocessing pipeline:
  extract → format → redact → generate PDF
"""

import logging

from lib.extractor import extract_text
from lib.formatter import format_document
from lib.redactor import redact
from lib.pdf_generator import generate_pdf

logger = logging.getLogger(__name__)


def process_document(raw_bytes: bytes, key: str, filename: str) -> bytes:
    """
    Run the full preprocessing pipeline on a raw file.

    :param raw_bytes: Raw content downloaded from S3
    :param key:       S3 object key (used for extension detection and logging)
    :param filename:  Human-readable title for the PDF (spaces, no extension)
    :returns:         PDF bytes ready for upload
    """
    logger.info("Pipeline starting", extra={'key': key, 'filename': filename})

    raw_text = extract_text(raw_bytes, key)
    logger.info("Extraction complete", extra={'chars': len(raw_text)})

    formatted_text = format_document(raw_text)

    redacted_text = redact(formatted_text)

    title = filename.replace('_', ' ').title()
    pdf_bytes = generate_pdf(redacted_text, title=title)

    logger.info("Pipeline complete", extra={'key': key, 'pdf_bytes': len(pdf_bytes)})
    return pdf_bytes
