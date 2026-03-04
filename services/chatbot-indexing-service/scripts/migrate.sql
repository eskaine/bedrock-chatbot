-- migrate.sql
-- Sets up the parent-child schema for document indexing with pgvector.
--
-- WARNING: drops and recreates document_chunks and document_sections.
-- All existing indexed data will be lost. Re-upload all documents to S3
-- after running this migration to re-index against the new schema.
--
-- Run order:
--   1. Run this script against Aurora PostgreSQL
--   2. Deploy chatbot-indexing-service
--   3. Re-upload all documents to S3 to trigger re-indexing
--   4. Deploy chatbot-orchestration-service

CREATE EXTENSION IF NOT EXISTS vector;

-- Drop in reverse dependency order (chunks references sections)
DROP TABLE IF EXISTS document_chunks;
DROP TABLE IF EXISTS document_sections;

-- ---------------------------------------------------------------------------
-- Parent: full sections for complete context retrieval
-- ---------------------------------------------------------------------------
CREATE TABLE document_sections (
    id               TEXT PRIMARY KEY,      -- SHA-256 hash of source + section_header
    content          TEXT        NOT NULL,  -- full section text
    category         TEXT        NOT NULL,  -- top-level S3 folder (e.g. "aegis")
    section_header   TEXT,                  -- detected header line, NULL for preamble
    header_embedding vector(1024),          -- Cohere embed of section_header for semantic search
    metadata         JSONB                  -- source path and any extra fields
);

CREATE INDEX IF NOT EXISTS idx_sections_category
    ON document_sections (category);

-- HNSW index for semantic section header search
CREATE INDEX IF NOT EXISTS idx_sections_header_embedding_hnsw
    ON document_sections USING hnsw (header_embedding vector_cosine_ops);

-- ---------------------------------------------------------------------------
-- Child: small chunks for precise similarity search
-- ---------------------------------------------------------------------------
CREATE TABLE document_chunks (
    id               BIGSERIAL PRIMARY KEY,
    section_id       TEXT NOT NULL REFERENCES document_sections(id) ON DELETE CASCADE,
    content          TEXT        NOT NULL,   -- ~150-word chunk
    embedding        vector(1024),           -- Cohere embed-english-v3
    content_tsvector TSVECTOR,               -- for hybrid keyword search
    metadata         JSONB                   -- source, category, chunk_index, word_count
);

-- HNSW index for fast approximate nearest-neighbour search
CREATE INDEX IF NOT EXISTS idx_chunks_embedding_hnsw
    ON document_chunks USING hnsw (embedding vector_cosine_ops);

-- GIN index for full-text keyword search
CREATE INDEX IF NOT EXISTS idx_chunks_tsvector
    ON document_chunks USING gin (content_tsvector);

-- Index for category filtering before vector search
CREATE INDEX IF NOT EXISTS idx_chunks_category
    ON document_chunks ((metadata->>'category'));
