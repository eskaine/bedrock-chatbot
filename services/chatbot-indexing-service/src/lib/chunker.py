import logging
import re

from .constants import CHUNK_OVERLAP, CHUNK_SIZE, MIN_CHUNK_WORDS

logger = logging.getLogger(__name__)


def split_into_sections(text: str) -> list[tuple[str | None, str]]:
    """
    Split document text into (section_header, section_content) tuples.

    Scans line-by-line for header patterns. Content before the first header
    is grouped under section_header=None. Sections with no meaningful content
    are omitted.
    """
    lines = text.split('\n')
    sections: list[tuple[str | None, str]] = []
    current_header: str | None = None
    current_lines: list[str] = []

    for line in lines:
        stripped = line.strip()
        if _is_header(stripped):
            content = '\n'.join(current_lines).strip()
            if content:
                sections.append((current_header, content))
            current_header = stripped
            current_lines = []
        else:
            current_lines.append(line)

    content = '\n'.join(current_lines).strip()
    if content:
        sections.append((current_header, content))

    logger.info("Split into %d sections", len(sections))
    return sections


def chunk_section(
    text: str,
    chunk_size: int = CHUNK_SIZE,
    overlap: int = CHUNK_OVERLAP,
) -> list[str]:
    """
    Chunk section content into ~150-word child chunks with overlap.
    Splits at paragraph boundaries when possible. Chunks below MIN_CHUNK_WORDS
    are discarded.
    """
    paragraphs = re.split(r'\n\n+', text)
    chunks: list[str] = []
    current_chunk: list[str] = []
    current_word_count = 0

    for para in paragraphs:
        para = para.strip()
        if not para:
            continue

        para_words = para.split()
        para_word_count = len(para_words)

        # Paragraph exceeds chunk size — split it directly
        if para_word_count > chunk_size:
            if current_chunk:
                chunks.append(' '.join(current_chunk))
                current_chunk = []
                current_word_count = 0
            for i in range(0, len(para_words), chunk_size - overlap):
                chunks.append(' '.join(para_words[i:i + chunk_size]))
            continue

        # Adding this paragraph would overflow — flush and start a new chunk
        if current_word_count + para_word_count > chunk_size:
            if current_chunk:
                chunks.append(' '.join(current_chunk))
            if overlap > 0 and current_chunk:
                all_words = ' '.join(current_chunk).split()
                overlap_words = all_words[-overlap:] if len(all_words) > overlap else all_words
                current_chunk = overlap_words + para_words
            else:
                current_chunk = para_words
            current_word_count = len(current_chunk)
        else:
            current_chunk.extend(para_words)
            current_word_count += para_word_count

    if current_chunk:
        chunks.append(' '.join(current_chunk))

    return [c for c in chunks if len(c.split()) >= MIN_CHUNK_WORDS]


def _is_header(line: str) -> bool:
    """Return True if line looks like a section header."""
    if not line:
        return False
    # Numbered header: "1. Title" or "1.2 Title"
    if re.match(r'^\d+(\.\d+)*\.?\s+\S', line):
        return True
    # All-caps header (2–6 words): "VACATION POLICY"
    if line.isupper() and 2 <= len(line.split()) <= 6:
        return True
    # Title-case header (2–6 words): "Vacation Policy"
    if re.match(r'^[A-Z][a-z]+(?: [A-Z][a-z]+)*$', line) and 2 <= len(line.split()) <= 6:
        return True
    return False
