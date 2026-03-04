"""
handler.py — chatbot-indexing-service

Lambda entry point. Handles the S3 trigger, manages the DB connection,
and delegates all indexing logic to lib/pipeline.py.

S3 key structure:
  category/filename.pdf
  → category = parts[0]
  → source    = full S3 key (stored in metadata for traceability)
"""

import json
import logging
import os
import re
import sys

# Bundled dependencies — must precede all local imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'modules', 'psycopg2'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'modules', 'pypdf'))

import boto3
import psycopg2

from shared.exceptions import ServiceError, ValidationError
from lib.config import config
from lib.constants import DB_CONNECT_TIMEOUT, DEFAULT_CATEGORY, MAX_FILE_SIZE_BYTES
from lib.pipeline import index_document

logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger(__name__)

logger.info("Region: %s, Env: %s, DB: %s", config.region, config.environment, config.db_host)

s3 = boto3.client('s3')

# Validated at cold start — must match the bucket configured in deploy.sh
_EXPECTED_BUCKET = os.environ.get('S3_BUCKET')

# Only allow simple alphanumeric category names derived from S3 key prefixes
_CATEGORY_RE = re.compile(r'^[a-zA-Z0-9_-]{1,64}$')

DB_CONFIG = {
    'host': config.db_host,
    'database': config.db_name,
    'user': config.db_user,
    'password': config.db_password,
    'port': config.db_port,
    'sslmode': 'require',
    'connect_timeout': DB_CONNECT_TIMEOUT,
}

logger.info("Lambda initialization complete")


def lambda_handler(event: dict, context) -> dict:
    """Process a document uploaded to S3 through the indexing pipeline."""
    try:
        record = event['Records'][0]['s3']
        bucket: str = record['bucket']['name']
        key: str = record['object']['key']
        size: int = record['object'].get('size', 0)
        logger.info("Processing: s3://%s/%s (%d bytes)", bucket, key, size)

        if _EXPECTED_BUCKET and bucket != _EXPECTED_BUCKET:
            raise ValidationError(
                "Unexpected source bucket",
                context={"bucket": bucket, "expected": _EXPECTED_BUCKET},
            )

        if size > MAX_FILE_SIZE_BYTES:
            raise ValidationError(
                "File too large to index",
                context={"size_bytes": size, "limit_bytes": MAX_FILE_SIZE_BYTES},
            )

        parts = key.split('/')
        raw_category = parts[0] if len(parts) > 1 else DEFAULT_CATEGORY
        if _CATEGORY_RE.match(raw_category):
            category = raw_category
        else:
            logger.warning("Invalid category %r in key %r — falling back to default", raw_category, key)
            category = DEFAULT_CATEGORY
        logger.info("Category: %s, Source: %s", category, key)

        obj = s3.get_object(Bucket=bucket, Key=key)

        conn = psycopg2.connect(**DB_CONFIG)
        try:
            section_count, chunk_count = index_document(key, obj['Body'], conn, category)
            conn.commit()
        finally:
            conn.close()

        logger.info("Indexed %d sections, %d chunks from %s", section_count, chunk_count, key)
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': f'Indexed {section_count} sections, {chunk_count} chunks',
                'source': key,
            }),
        }

    except ValidationError as e:
        logger.warning("Skipping file: %s", e)
        return {'statusCode': 200, 'body': 'Skipped'}
    except ServiceError as e:
        logger.error("Service error: %s", e, exc_info=True)
        raise
    except Exception as e:
        logger.error("Unhandled error: %s", e, exc_info=True)
        raise
