"""
Data models for the document indexing pipeline.

These dataclasses mirror the PostgreSQL schema exactly. Any change to the DB
schema should be reflected here and in scripts/migrate.sql.

PostgreSQL schema (see scripts/migrate.sql for full DDL with indexes):

    document_sections   — parent, stores full section text for context retrieval
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ id               TEXT PRIMARY KEY  SHA-256(source + section_header)[:32]│
    │ content          TEXT NOT NULL     full section text                    │
    │ category         TEXT NOT NULL     top-level S3 folder (e.g. "aegis")   │
    │ section_header   TEXT              detected header line, NULL=preamble  │
    │ header_embedding vector(1024)      Cohere embed of section_header       │
    │ metadata         JSONB             {'source': s3_key}                   │
    └─────────────────────────────────────────────────────────────────────────┘

    document_chunks     — child, stores small chunks for similarity search
    ┌─────────────────────────────────────────────────────────────────────────┐
    │ id               BIGSERIAL PK                                           │
    │ section_id       TEXT NOT NULL     FK → document_sections.id            │
    │ content          TEXT NOT NULL     ~150-word chunk                      │
    │ embedding        vector(1024)      Cohere embed-english-v3              │
    │ content_tsvector TSVECTOR          to_tsvector('english', content)      │
    │ metadata         JSONB             source, category, chunk_index,       │
    │                                   total_chunks, word_count              │
    └─────────────────────────────────────────────────────────────────────────┘
"""

import hashlib
from dataclasses import dataclass, field


def make_section_id(source: str, section_header: str | None) -> str:
    """Generate a stable, deterministic section ID from source path + header."""
    raw = f"{source}::{section_header or ''}"
    return hashlib.sha256(raw.encode()).hexdigest()[:32]


@dataclass
class Section:
    """Parent document section — maps to a row in document_sections."""
    id: str
    content: str
    category: str
    section_header: str | None
    header_embedding: list[float] | None
    metadata: dict = field(default_factory=dict)


@dataclass
class Chunk:
    """Child chunk — maps to a row in document_chunks."""
    section_id: str
    content: str
    embedding: list[float]
    metadata: dict = field(default_factory=dict)
    # content_tsvector is computed by PostgreSQL on insert: to_tsvector('english', content)
