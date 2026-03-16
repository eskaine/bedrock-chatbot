import json
import logging
from typing import Any

from shared.exceptions import StorageError
from .constants import CHUNKS_TABLE, SECTIONS_TABLE, TSVECTOR_LANGUAGE
from .schema import Chunk, Section

logger = logging.getLogger(__name__)


def delete_document(conn: Any, source: str) -> int:
    """Delete all sections (and their chunks via CASCADE) for a given S3 key.

    Returns the number of sections deleted.
    """
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                f"DELETE FROM {SECTIONS_TABLE} WHERE metadata->>'source' = %s",
                (source,),
            )
            deleted = cursor.rowcount
        if deleted:
            logger.info("Deleted %d existing sections for source=%s", deleted, source)
        return deleted
    except Exception as e:
        raise StorageError(
            "Failed to delete existing document",
            context={"source": source},
        ) from e


def store_section(conn: Any, section: Section) -> None:
    """Insert a parent section into document_sections. No-op if already exists."""
    try:
        vector_str = (
            '[' + ','.join(str(v) for v in section.header_embedding) + ']'
            if section.header_embedding else None
        )
        with conn.cursor() as cursor:
            cursor.execute(
                f"""
                INSERT INTO {SECTIONS_TABLE} (id, content, category, section_header, header_embedding, metadata)
                VALUES (%s, %s, %s, %s, %s::vector, %s)
                ON CONFLICT (id) DO NOTHING
                """,
                (section.id, section.content, section.category,
                 section.section_header, vector_str, json.dumps(section.metadata)),
            )
        logger.debug("Stored section %s (category=%s)", section.id, section.category)
    except Exception as e:
        raise StorageError(
            "Failed to store section",
            context={"section_id": section.id, "category": section.category},
        ) from e


def store_chunk(conn: Any, chunk: Chunk) -> None:
    """Insert a child chunk into document_chunks with embedding and tsvector."""
    try:
        vector_str = '[' + ','.join(str(v) for v in chunk.embedding) + ']'
        with conn.cursor() as cursor:
            cursor.execute(
                f"""
                INSERT INTO {CHUNKS_TABLE} (section_id, content, embedding, content_tsvector, metadata)
                VALUES (%s, %s, %s::vector, to_tsvector(%s::regconfig, %s), %s)
                """,
                (chunk.section_id, chunk.content, vector_str,
                 TSVECTOR_LANGUAGE, chunk.content, json.dumps(chunk.metadata)),
            )
    except Exception as e:
        raise StorageError(
            "Failed to store chunk",
            context={"section_id": chunk.section_id},
        ) from e
