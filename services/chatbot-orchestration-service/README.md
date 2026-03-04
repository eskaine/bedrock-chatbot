# chatbot-orchestration-service

AWS Lambda that handles chat requests — retrieves relevant context from Aurora PostgreSQL using multi-retriever RRF, then streams a response from Claude via Bedrock.

---

## Retrieval Strategy

### Overview

Retrieval uses **Reciprocal Rank Fusion (RRF)** across three independent retrievers. Each retriever captures a different relevance signal. Their ranked results are fused into a single score, and the top-ranked parent sections are passed as context to Claude.

This replaces single-signal hybrid search and removes the dependency on Cohere Rerank (not available in `ap-southeast-1`).

### Pipeline

```
User query
    ↓
Embed query (Cohere embed-english-v3, search_query input type)
    ↓
Run 3 retrievers in parallel:
    ├── Dense   — ANN vector search on document_chunks.embedding (HNSW)
    ├── Sparse  — BM25 keyword search on document_chunks.content_tsvector (GIN)
    └── Header  — ANN vector search on document_sections.header_embedding (HNSW)
    ↓
Apply RRF — fuse ranked lists into unified section scores
    ↓
Select top 5 section IDs by RRF score
    ↓
Fetch parent document_sections for those IDs
    ↓
Pass full section text as context to Claude (ConverseStream)
```

### Retrievers

#### Dense — vector similarity on child chunks

Searches `document_chunks.embedding` using HNSW approximate nearest-neighbour. Captures semantic similarity between the query and chunk content.

```sql
SELECT dc.section_id
FROM document_chunks dc
WHERE dc.metadata->>'category' = $2        -- optional category filter
ORDER BY dc.embedding <=> $1::vector
LIMIT 20
```

#### Sparse — BM25 keyword search on child chunks

Searches `document_chunks.content_tsvector` using PostgreSQL full-text search. Captures exact keyword matches that dense retrieval may miss.

```sql
SELECT dc.section_id
FROM document_chunks dc
WHERE dc.content_tsvector @@ plainto_tsquery($1)
  AND dc.metadata->>'category' = $2        -- optional category filter
ORDER BY ts_rank(dc.content_tsvector, plainto_tsquery($1)) DESC
LIMIT 20
```

#### Header — semantic search on section headers

Searches `document_sections.header_embedding` using HNSW. Captures queries that match a section topic even when chunk content doesn't rank highly. Only sections with a detected header are indexed (preamble sections with `section_header IS NULL` are skipped).

```sql
SELECT ds.id AS section_id
FROM document_sections ds
WHERE ds.category = $2                     -- optional category filter
  AND ds.header_embedding IS NOT NULL
ORDER BY ds.header_embedding <=> $1::vector
LIMIT 10
```

### Reciprocal Rank Fusion (RRF)

RRF combines ranked lists without requiring score normalisation across retrievers. Each retriever contributes a rank-based score per section:

```
score(section) = Σ  1 / (k + rank_i)
```

- `k = 60` — standard constant that dampens the influence of very high ranks
- `rank_i` — 0-based rank of the section in retriever `i` (only if it appeared)
- Sections appearing in multiple retrievers accumulate higher scores

The top 5 sections by fused score are selected and their full content fetched from `document_sections`.

### Constants

| Constant | Value | Description |
|---|---|---|
| `DENSE_LIMIT` | 20 | Candidates from dense retriever |
| `SPARSE_LIMIT` | 20 | Candidates from sparse retriever |
| `HEADER_LIMIT` | 10 | Candidates from header retriever |
| `RRF_TOP_N` | 5 | Sections kept after fusion |
| `RRF_K` | 60 | RRF dampening constant |

---

## Session Management

Sessions are server-issued and stored in DynamoDB. The Lambda is the single owner of all session reads and writes — the Fargate gateway has no DynamoDB access.

### Invocation modes

The Lambda handler branches on `event.action`:

| `event.action` | Invocation type | Used by |
|---|---|---|
| `get_or_create_session` | Synchronous (`RequestResponse`) | Fargate `GET /session` |
| _(absent)_ | Streaming (`InvokeWithResponseStream`) | Fargate `POST /chat` |

### Session lifecycle

```
Client loads page
    ↓
Fargate GET /session  (X-Session-Id header — optional)
    ↓
Lambda: get_or_create_session(sessionId)
    ├── No / invalid ID  →  create new session  →  { status: "new",     sessionId, history: [] }
    ├── ID found in DB   →  return history       →  { status: "active",  sessionId, history }
    └── ID not in DB     →  session expired      →  { status: "expired" }
```

On `"expired"`, the frontend disables the input and shows an expiry message in the chat. The session ID remains in `sessionStorage` until the tab is closed or the user explicitly clears it.

On every successful chat turn, `saveHistory` resets the TTL to `now + SESSION_TTL_SECONDS`, giving a **sliding 15-minute expiry window**. An idle session expires 15 minutes after the last message.

### DynamoDB schema

| Attribute | Type | Notes |
|---|---|---|
| `sessionId` | String (HASH) | Server-generated UUID v4 |
| `messages` | List | Bedrock-format conversation history |
| `ttl` | Number | Unix timestamp — DynamoDB TTL attribute (sliding) |
| `createdAt` | String | ISO 8601 — set once on first write |
| `updatedAt` | String | ISO 8601 — updated on every write |
| `messageCount` | Number | Count of stored messages |

---

## File Structure

```
src/
├── handler.js          — Lambda entry point; branches on event.action for session vs chat
└── lib/
    ├── config.js       — Environment variable bindings
    ├── constants.js    — Shared constants (limits, TTL, model IDs, regex)
    ├── llm.js          — Bedrock ConverseStream wrapper + system prompt loader
    ├── logger.js       — Structured logger
    ├── pipeline.js     — Full RAG pipeline: load history → retrieve → stream → save
    ├── retrieval.js    — Orchestrates embed → parallel retrievers → RRF → fetch sections
    ├── retrievers.js   — Three retriever functions + applyRRF
    └── session.js      — DynamoDB session store: createSession, getOrCreateSession, saveHistory
```

---

## Deployment

```bash
./scripts/deploy.sh <environment>
# e.g. ./scripts/deploy.sh dev
```

The deploy script:
1. Fetches config from Secrets Manager (`chatbot/streaming/<env>`)
2. Creates or updates the Bedrock Guardrail
3. Packages and deploys the Lambda with a streaming Function URL

---

## Environment Variables

| Variable | Description |
|---|---|
| `AWS_REGION` | AWS region |
| `MODEL_ID` | Bedrock model ID for Claude |
| `POSTGRES_HOST` | Aurora cluster endpoint |
| `POSTGRES_DB` | Database name |
| `DB_SECRET_ARN` | Secrets Manager ARN for DB credentials |
| `GUARDRAIL_ID` | Bedrock Guardrail ID |
| `GUARDRAIL_VERSION` | Bedrock Guardrail version |
| `SESSIONS_TABLE` | DynamoDB table name for session storage |
