const ERROR_MESSAGE = 'Invalid request. Please rephrase your question.'

const MAX_TOKENS  = 4096
const TEMPERATURE = 0.7

// Bedrock streaming — abort if no chunk arrives within this window
const STREAM_TIMEOUT_MS = 30000  // 30 s — well under the 120 s Lambda timeout

// Database
const DB_PORT                = 5432
const DB_CONNECT_TIMEOUT_MS  = 10000  // 10 s — prevents Lambda hanging on VPC misconfiguration

// Table names — mirrors constants in the indexing service
const CHUNKS_TABLE   = 'document_chunks'
const SECTIONS_TABLE = 'document_sections'

// Retrieval
const DENSE_LIMIT  = 20   // candidates from dense (vector) retriever
const SPARSE_LIMIT = 20   // candidates from sparse (BM25) retriever
const HEADER_LIMIT = 10   // candidates from section header retriever
const RRF_TOP_N    = 5    // sections kept after RRF fusion
const RRF_K        = 60   // RRF constant — dampens rank differences
const EMBED_MODEL_ID = 'cohere.embed-english-v3'

// Input validation
const MAX_MESSAGE_LENGTH = 1200
const MIN_MESSAGE_LENGTH = 1

// Category map — keys are DB/S3 values (lowercase), values are display names.
// Add a new entry here when a new S3 folder/category is added.
const CATEGORIES = {
  aegis:  'AEGIS',
  qualifly: 'QualiFly',
}

// Only allow simple alphanumeric category strings derived from S3 key prefixes.
// Mirrors the same regex used in the indexing service.
const CATEGORY_RE = /^[a-zA-Z0-9_-]{1,64}$/

// Only accept well-formed UUID v4 session IDs
const SESSION_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

// Session
const SESSION_TTL_SECONDS  = 900    // 15 minutes
const MAX_HISTORY_MESSAGES = 20     // 10 exchanges (user + assistant pairs)
const MAX_CLASSIFIER_HISTORY = 6   // last 3 exchanges passed to classifier for context

const RATE_LIMIT_MAX_REQUESTS   = 10
const RATE_LIMIT_WINDOW_SECONDS = 60

module.exports = {
  ERROR_MESSAGE,
  MAX_TOKENS,
  TEMPERATURE,
  STREAM_TIMEOUT_MS,
  DB_PORT,
  DB_CONNECT_TIMEOUT_MS,
  CHUNKS_TABLE,
  SECTIONS_TABLE,
  DENSE_LIMIT,
  SPARSE_LIMIT,
  HEADER_LIMIT,
  RRF_TOP_N,
  RRF_K,
  EMBED_MODEL_ID,
  MAX_MESSAGE_LENGTH,
  MIN_MESSAGE_LENGTH,
  CATEGORIES,
  CATEGORY_RE,
  SESSION_ID_RE,
  SESSION_TTL_SECONDS,
  MAX_HISTORY_MESSAGES,
  MAX_CLASSIFIER_HISTORY,
  RATE_LIMIT_MAX_REQUESTS,
  RATE_LIMIT_WINDOW_SECONDS,
}
