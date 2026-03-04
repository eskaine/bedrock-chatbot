import logging
from typing import Any

from .chunker import chunk_section, split_into_sections
from .constants import EMBED_INPUT_TYPE
from .embedder import embed_text
from .extractor import extract_text
from .schema import Chunk, Section, make_section_id
from .store import store_chunk, store_section

logger = logging.getLogger(__name__)


def index_document(key: str, body: Any, conn: Any, category: str) -> tuple[int, int]:
    """
    Run the full indexing pipeline for a single document.

    Extracts text, splits into sections, embeds headers and child chunks,
    and writes everything to the database. The caller is responsible for
    committing or rolling back the connection.

    Returns:
        (section_count, chunk_count)

    Raises:
        ValidationError: if the file type is unsupported.
        ServiceError: if extraction, embedding, or storage fails.
    """
    text = extract_text(key, body)
    logger.info("Extracted %d characters, %d words", len(text), len(text.split()))

    sections = split_into_sections(text)
    logger.info("Found %d sections", len(sections))

    total_chunks = 0
    for section_header, section_content in sections:
        section = Section(
            id=make_section_id(key, section_header),
            content=section_content,
            category=category,
            section_header=section_header,
            header_embedding=embed_text(section_header, input_type=EMBED_INPUT_TYPE) if section_header else None,
            metadata={'source': key},
        )
        store_section(conn, section)

        chunks = chunk_section(section_content)
        for i, chunk_text in enumerate(chunks):
            chunk = Chunk(
                section_id=section.id,
                content=chunk_text,
                embedding=embed_text(chunk_text, input_type=EMBED_INPUT_TYPE),
                metadata={
                    'source': key,
                    'category': category,
                    'chunk_index': i,
                    'total_chunks': len(chunks),
                    'word_count': len(chunk_text.split()),
                },
            )
            store_chunk(conn, chunk)
            total_chunks += 1

    return len(sections), total_chunks
