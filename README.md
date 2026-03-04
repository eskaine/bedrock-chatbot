# RAG Chatbot

A retrieval-augmented generation (RAG) chatbot backed by a hybrid retrieval pipeline and AWS Bedrock. Users interact through a chat widget, ask questions scoped to a product category, and receive streamed responses grounded in indexed documentation.

---

## Tech Stack

### Frontend
| | |
|---|---|
| React 19 | UI framework |
| TypeScript | Type safety |
| Vite | Build tool |
| Tailwind CSS v4 | Styling |
| shadcn/ui (Radix UI) | Component library |
| Zod | Runtime schema validation |
| react-markdown + remark-gfm | Markdown rendering in chat |

### Backend
| | |
|---|---|
| FastAPI (Python) | Public-facing API gateway on ECS Fargate |
| AWS Lambda (Node.js) | Streaming chat handler |
| AWS Bedrock | LLM inference (streaming) |
| Cohere embed-english-v3 | 1024-dim text embeddings |
| Aurora PostgreSQL + pgvector | Vector store with HNSW index |
| DynamoDB | Session / conversation history store |
| Amazon S3 | Raw and processed document storage |
| AWS Secrets Manager | Database credential management |
| boto3 / AWS SDK v3 | AWS service clients |

---

## Services

### `rag-chatbot` — Frontend
React SPA served as a static site. Renders a chat dialog widget where users select a product topic and send messages. Generates a UUID session ID in `sessionStorage` and passes it via `X-Session-Id` header on every request. On mount it fetches existing conversation history so the chat persists across page refreshes.

### `chatbot-fargate-service` — API Gateway
FastAPI service running on ECS Fargate. Acts as the public entry point:
- Validates and sanitises user input (length, character allow-list)
- Applies in-memory IP-based rate limiting
- Detects prompt injection patterns
- Proxies validated requests to the streaming Lambda via AWS SDK
- Exposes `POST /chat` (streaming NDJSON) and `GET /history` (session replay)

### `chatbot-orchestration-service` — Streaming Lambda
Node.js Lambda function with response streaming. Orchestrates the full RAG pipeline per request:
1. Loads conversation history from DynamoDB
2. Embeds the user query via Cohere and runs three retrievers in parallel against PostgreSQL
3. Fuses retriever results with Reciprocal Rank Fusion (RRF, k=60), selects the top 5 sections
4. Builds a grounded prompt and streams the Bedrock completion back chunk by chunk
5. Saves the updated conversation turn to DynamoDB (sliding 24h TTL, max 20 messages)

**Hybrid retrieval:**
| Retriever | Method | Candidates |
|---|---|---|
| Dense | Cosine ANN on chunk embeddings (pgvector HNSW) | 20 |
| Sparse | BM25 full-text via `ts_rank` + GIN tsvector index | 20 |
| Header | Cosine ANN on section header embeddings | 10 |

### `chatbot-indexing-service` — Indexing Lambda
Python Lambda triggered by S3 events. Processes uploaded documents into the vector store:
1. Extracts text from PDF/DOCX files
2. Splits text into sections by detecting headers (numbered, ALL-CAPS, Title-Case)
3. Embeds each section header via Cohere and stores in `document_sections`
4. Chunks each section into ~150-word overlapping windows (30-word overlap)
5. Embeds each chunk and writes to `document_chunks` with a computed tsvector

### `chatbot-preprocessing-service` — Document Preparation
Collection of scripts for preparing source documents before indexing:
- PII/sensitive data redaction
- Upload to the raw S3 bucket to trigger the indexing pipeline
- System prompt management

---

## Architecture

```
Browser
  └─ React SPA (sessionStorage session ID)
       │  POST /chat  •  GET /history
       ▼
ECS Fargate  (FastAPI)
  │  validate  •  rate-limit  •  injection-check
  │  invoke streaming Lambda
  ▼
AWS Lambda  (Node.js, streaming)
  ├─ DynamoDB ──── load / save conversation history
  ├─ PostgreSQL ── dense retriever  (pgvector HNSW)
  │                sparse retriever (GIN tsvector)
  │                header retriever (pgvector HNSW)
  │                └─ RRF fusion → top 5 sections
  └─ AWS Bedrock ─ stream grounded completion
       │
       ▼
     NDJSON chunks  →  Fargate  →  Browser
```

---

## Data Model

```
document_sections          document_chunks
─────────────────          ───────────────
id (SHA-256)               id (BIGSERIAL)
content                    section_id (FK)
category                   content (~150 words)
section_header             embedding vector(1024)
header_embedding(1024)     content_tsvector
metadata (JSONB)           metadata (JSONB)
```
