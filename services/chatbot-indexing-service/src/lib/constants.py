# Database
DB_PORT = 5432

# Table names
SECTIONS_TABLE = 'document_sections'
CHUNKS_TABLE = 'document_chunks'

# Full-text search language used for tsvector indexing
TSVECTOR_LANGUAGE = 'english'

# Default category applied when the S3 key has no top-level folder prefix
DEFAULT_CATEGORY = 'general'

# Maximum file size accepted for indexing (bytes) — protects against Lambda OOM
MAX_FILE_SIZE_BYTES = 50 * 1024 * 1024  # 50 MB

# PostgreSQL connection timeout in seconds
DB_CONNECT_TIMEOUT = 5

# Bedrock model IDs
EMBED_MODEL_ID = 'cohere.embed-english-v3'

# Bedrock embedding input type for indexing documents
EMBED_INPUT_TYPE = 'search_document'

# Chunking config (Cohere Embed has 2048 char limit per text)
CHUNK_SIZE = 150        # Target words per child chunk
CHUNK_OVERLAP = 30      # 20% overlap for context continuity
MIN_CHUNK_WORDS = 20    # Filter out very small chunks
