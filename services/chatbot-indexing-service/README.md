# chatbot-indexing-service

AWS Lambda that processes documents uploaded to S3, splits them into sections, embeds child chunks and section headers via Bedrock Cohere, and stores the results in Aurora PostgreSQL (pgvector).

---

## Indexing Strategy

### Overview

Documents are indexed using a **parent-child (hierarchical) chunking** approach. This separates retrieval precision from context quality:

- **Child chunks** (~150 words) are embedded and used for vector similarity and keyword search
- **Section headers** are embedded separately for semantic header search
- **Parent sections** (full section text) are stored and retrieved as context for the LLM

This avoids the core problem with flat chunking, where a single chunk must simultaneously be small enough for precise retrieval and large enough to contain useful context.

### Pipeline

```
S3 upload
    ↓
Extract text (PDF or TXT)
    ↓
Split document into sections by header
    ↓
For each section:
    ├── Embed section header (Cohere embed-english-v3)
    ├── Store section + header embedding as parent (document_sections)
    ├── Chunk section into ~150-word children
    ├── Embed each child chunk (Cohere embed-english-v3)
    └── Store child chunks with embeddings + tsvectors (document_chunks)
```

### Document Structure

```
category/filename.pdf
├── [preamble]              ← section_header: null, no header embedding
├── ## Section One          ← section_header: "Section One" (embedded)
│   ├── chunk 1             ← child chunk (embedded)
│   └── chunk 2             ← child chunk (embedded)
└── ## Section Two          ← section_header: "Section Two" (embedded)
    └── chunk 1             ← child chunk (embedded)
```

### S3 Key Structure

```
{category}/{filename}.pdf
```

- `category` — top-level S3 folder (e.g. `aegis`, `hr`). Used as the primary retrieval filter.
- `filename` — stored in `metadata.source` on both tables for traceability. Not used as a retrieval dimension since content can be relevant across multiple files within a category.

### Header Detection

A line is treated as a section header if it matches any of:

| Pattern | Example |
|---|---|
| Numbered (`1.` or `1.2`) | `1. Vacation Policy`, `2.1 Eligibility` |
| All-caps (2–6 words) | `VACATION POLICY` |
| Title-case (2–6 words) | `Vacation Policy` |

### Child Chunk Parameters

| Parameter | Value |
|---|---|
| Target chunk size | 150 words |
| Overlap | 30 words (20%) |
| Minimum chunk size | 20 words |

Chunks are split at paragraph boundaries where possible. Paragraphs exceeding the target size are split directly with overlap.

### Section ID

Each section gets a deterministic ID generated as:

```
SHA-256("{s3_key}::{section_header}") → first 32 hex chars
```

Re-uploading the same document is idempotent — `ON CONFLICT (id) DO NOTHING` on `document_sections` prevents duplicates.

---

## Database Schema

See [`scripts/migrate.sql`](scripts/migrate.sql) for the full schema.

### `document_sections` (parent)

| Column | Type | Description |
|---|---|---|
| `id` | TEXT | SHA-256 hash of source + header |
| `content` | TEXT | Full section text |
| `category` | TEXT | Top-level S3 folder |
| `section_header` | TEXT | Detected header line (null for preamble) |
| `header_embedding` | vector(1024) | Cohere embedding of section header |
| `metadata` | JSONB | `source` S3 key and any extra fields |

### `document_chunks` (child)

| Column | Type | Description |
|---|---|---|
| `id` | BIGSERIAL | Auto-incrementing primary key |
| `section_id` | TEXT | FK → `document_sections.id` |
| `content` | TEXT | ~150-word chunk text |
| `embedding` | vector(1024) | Cohere embedding of chunk content |
| `content_tsvector` | TSVECTOR | For BM25 keyword search |
| `metadata` | JSONB | `source`, `category`, `chunk_index`, `word_count` |

### Indexes

| Index | Table | Type | Purpose |
|---|---|---|---|
| `idx_sections_header_embedding_hnsw` | `document_sections` | HNSW (`vector_cosine_ops`) | Semantic section header search |
| `idx_sections_category` | `document_sections` | B-tree | Category filtering |
| `idx_chunks_embedding_hnsw` | `document_chunks` | HNSW (`vector_cosine_ops`) | Fast ANN vector search on chunks |
| `idx_chunks_tsvector` | `document_chunks` | GIN | BM25 keyword search |
| `idx_chunks_category` | `document_chunks` | B-tree | Category filtering before vector search |

---

## Supported File Types

| Extension | Handler |
|---|---|
| `.pdf` | `pypdf` text extraction |
| `.txt` | UTF-8 decode |

---

## Environment Variables

| Variable | Description |
|---|---|
| `AWS_REGION` | AWS region |
| `ENVIRONMENT` | Deployment environment (`dev`, `prod`) |
| `POSTGRES_HOST` | Aurora cluster endpoint |
| `POSTGRES_DB` | Database name |
| `DB_SECRET_ARN` | Secrets Manager ARN for DB credentials |
