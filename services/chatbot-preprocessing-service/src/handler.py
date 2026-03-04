"""
handler.py — chatbot-preprocessing-service

Processes raw files uploaded to the raw S3 bucket:
  1. Validates the event (bucket, file size, file type, category)
  2. Downloads the raw file from S3
  3. Runs the preprocessing pipeline (extract → format → redact → PDF)
  4. Uploads the PDF to the docs bucket, triggering the indexing Lambda
"""

import json
import logging
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'modules'))

import boto3

from lib.config import config
from lib.constants import MAX_FILE_SIZE_BYTES, DEFAULT_CATEGORY, CATEGORY_RE
from lib.pipeline import process_document
from shared.exceptions import ValidationError, ServiceError

logging.getLogger().setLevel(logging.INFO)
logger = logging.getLogger('handler')

logger.info("Lambda initializing", extra={'region': config.region, 'model': config.model_id})
logger.debug("Bucket config", extra={'raw': config.s3_raw_bucket, 'docs': config.s3_docs_bucket})

s3 = boto3.client('s3')

logger.info("Lambda initialization complete")


def lambda_handler(event, context):
    try:
        record = event['Records'][0]
        bucket = record['s3']['bucket']['name']
        key    = record['s3']['object']['key']
        size   = record['s3']['object'].get('size', 0)

        logger.info("Processing S3 event", extra={'bucket': bucket, 'key': key, 'size': size})

        # --- Validate bucket ---------------------------------------------------
        if bucket != config.s3_raw_bucket:
            raise ValidationError(
                "Event from unexpected bucket",
                context={'bucket': bucket, 'expected': config.s3_raw_bucket},
            )

        # --- Validate file size -----------------------------------------------
        if size > MAX_FILE_SIZE_BYTES:
            raise ValidationError(
                "File exceeds maximum allowed size",
                context={'size': size, 'limit': MAX_FILE_SIZE_BYTES, 'key': key},
            )

        # --- Derive and validate category from folder prefix ------------------
        raw_category = key.split('/')[0] if '/' in key else DEFAULT_CATEGORY
        if CATEGORY_RE.match(raw_category):
            category = raw_category
        else:
            logger.warning("Invalid category in key, using default", extra={'raw': raw_category})
            category = DEFAULT_CATEGORY

        filename = os.path.splitext(os.path.basename(key))[0]
        logger.info("Request parsed", extra={'category': category, 'filename': filename})

        # --- Download and process --------------------------------------------
        obj = s3.get_object(Bucket=bucket, Key=key)
        raw_bytes = obj['Body'].read()

        pdf_bytes = process_document(raw_bytes, key, filename)

        # --- Upload PDF — triggers indexing Lambda automatically -------------
        output_key = f"{category}/{filename}.pdf"
        s3.put_object(
            Bucket=config.s3_docs_bucket,
            Key=output_key,
            Body=pdf_bytes,
            ContentType='application/pdf',
        )

        logger.info("Uploaded PDF", extra={'bucket': config.s3_docs_bucket, 'key': output_key})

        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Preprocessed and uploaded successfully',
                'source':  f"s3://{bucket}/{key}",
                'output':  f"s3://{config.s3_docs_bucket}/{output_key}",
                'category': category,
            }),
        }

    except ValidationError as e:
        logger.warning("Validation error — skipping file", extra={'error': str(e)})
        return {'statusCode': 200, 'body': f"Skipped: {e.message}"}

    except ServiceError as e:
        logger.error("Service error", extra={'error': str(e), 'context': e.context})
        raise

    except Exception as e:
        logger.error("Unhandled error", extra={'error': str(e)}, exc_info=True)
        raise
