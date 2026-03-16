# chatbot-orchestration-service

AWS Lambda that handles chat requests — classifies the topic and rewrites the user query, retrieves relevant context from Aurora PostgreSQL using multi-retriever RRF, then streams a response from Claude via Bedrock.

---

## Pipeline

```
User query
    ↓
Classify topic + rewrite query (Bedrock ConverseCommand, non-streaming)
    ├── No topic matched  →  stream clarification message  →  save to history  →  return
    ↓
Embed cleaned query (Cohere embed-english-v3)
    ↓
Run 3 retrievers in parallel (filtered by detected topic):
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
Stream response from Claude (ConverseStream) with retrieved context
    ↓
Save turn to DynamoDB session history
```

---

## Classification

The classifier runs before retrieval on every invocation. It uses a dedicated Bedrock prompt (`CLASSIFIER_PROMPT_ARN`) to:

- Detect which product topic the user is asking about
- Rewrite the query to fix typos, expand abbreviations, and remove filler words (especially useful after AWS Transcribe speech-to-text)
- Return a clarification message if no topic is matched, which is streamed directly to the user and saved to history for context in the next turn

### Topic resolution

Topics are defined in `constants.js` as a map of DB/S3 keys to display names:

```js
const CATEGORIES = {
  aegis:    'AEGIS',
  qualifly: 'QualiFly',
}
```

At cold start, the Lambda queries `SELECT DISTINCT category FROM document_sections` and filters the results against this map. The classifier sees display names (`AEGIS`, `QualiFly`). The returned display name is reverse-mapped back to the DB key for retrieval filtering.

To add a new topic: index documents under a new S3 folder, then add the corresponding entry to `CATEGORIES` and redeploy.

---

## Retrieval Strategy

### Retrievers

#### Dense — vector similarity on child chunks

Searches `document_chunks.embedding` using HNSW approximate nearest-neighbour. Captures semantic similarity between the query and chunk content.

```sql
SELECT dc.section_id
FROM document_chunks dc
WHERE dc.metadata->>'category' = $2        -- topic filter
ORDER BY dc.embedding <=> $1::vector
LIMIT 20
```

#### Sparse — BM25 keyword search on child chunks

Searches `document_chunks.content_tsvector` using PostgreSQL full-text search. Captures exact keyword matches that dense retrieval may miss.

```sql
SELECT dc.section_id
FROM document_chunks dc
WHERE dc.content_tsvector @@ plainto_tsquery($1)
  AND dc.metadata->>'category' = $2        -- topic filter
ORDER BY ts_rank(dc.content_tsvector, plainto_tsquery($1)) DESC
LIMIT 20
```

#### Header — semantic search on section headers

Searches `document_sections.header_embedding` using HNSW. Captures queries that match a section topic even when chunk content doesn't rank highly. Only sections with a detected header are indexed.

```sql
SELECT ds.id AS section_id
FROM document_sections ds
WHERE ds.category = $2                     -- topic filter
  AND ds.header_embedding IS NOT NULL
ORDER BY ds.header_embedding <=> $1::vector
LIMIT 10
```

### Reciprocal Rank Fusion (RRF)

RRF combines ranked lists without requiring score normalisation across retrievers:

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

On every successful chat turn, `saveHistory` resets the TTL to `now + SESSION_TTL_SECONDS`, giving a **sliding 15-minute expiry window**.

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
    ├── constants.js    — Shared constants (limits, TTL, model IDs, regex, CATEGORIES map)
    ├── llm.js          — Bedrock wrapper: classifyAndClean (non-streaming) + streamCompletion
    ├── logger.js       — Structured logger
    ├── pipeline.js     — Full pipeline: classify → retrieve → stream → save history
    ├── retrieval.js    — Orchestrates embed → parallel retrievers → RRF → fetch sections
    ├── retrievers.js   — Three retriever functions + applyRRF
    ├── session.js      — DynamoDB session store: createSession, getOrCreateSession, saveHistory
    └── prompts/
        ├── prompt.txt             — System prompt for Claude (answer generation)
        └── classifier-prompt.txt  — System prompt for topic classification and query rewriting
```

---

## Deployment

```bash
# Deploy classifier prompt to Bedrock Prompt Management (set PROMPT_TYPE="classifier" in script)
./scripts/update-prompt.sh <environment>

# Deploy system prompt to Bedrock Prompt Management (set PROMPT_TYPE="system" in script)
./scripts/update-prompt.sh <environment>

# Deploy Lambda
./scripts/deploy.sh <environment>
```

The deploy script fetches all config from Secrets Manager (`chatbot/orchestration/<env>`) and sets them as Lambda environment variables.

---

## Environment Variables

| Variable | Description |
|---|---|
| `AWS_REGION` | AWS region |
| `MODEL_ID` | Bedrock model ID for Claude |
| `POSTGRES_HOST` | Aurora cluster or RDS Proxy endpoint |
| `POSTGRES_DB` | Database name |
| `DB_SECRET_ARN` | Secrets Manager ARN for DB credentials |
| `GUARDRAIL_ID` | Bedrock Guardrail ID |
| `GUARDRAIL_VERSION` | Bedrock Guardrail version |
| `PROMPT_ARN` | Bedrock Prompt Management ARN for system prompt |
| `PROMPT_VERSION` | Published version of the system prompt |
| `CLASSIFIER_PROMPT_ARN` | Bedrock Prompt Management ARN for classifier prompt |
| `CLASSIFIER_PROMPT_VERSION` | Published version of the classifier prompt |
| `SESSIONS_TABLE` | DynamoDB table name for session storage |
