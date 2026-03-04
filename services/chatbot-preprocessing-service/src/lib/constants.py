MAX_TOKENS  = 4096
TEMPERATURE = 0.3  # Lower temperature for consistent, deterministic formatting

MAX_FILE_SIZE_BYTES = 50 * 1024 * 1024  # 50 MB
DEFAULT_CATEGORY    = 'general'
SUPPORTED_EXTENSIONS = frozenset({'.txt', '.md', '.json', '.pdf'})

# Regex for a safe category name — matches indexing service validation
import re
CATEGORY_RE = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')
