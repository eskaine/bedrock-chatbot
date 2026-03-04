import json
import logging

import boto3
from botocore.exceptions import ClientError

from shared.exceptions import ExternalServiceError
from shared.retry import aws_retry
from .config import config
from .constants import EMBED_MODEL_ID

logger = logging.getLogger(__name__)

# Initialised once at cold start — shared across all invocations
_client = boto3.client('bedrock-runtime', region_name=config.region)


@aws_retry(max_attempts=3, base_delay=1.0)
def _invoke_embed(text: str, input_type: str) -> list[float]:
    response = _client.invoke_model(
        modelId=EMBED_MODEL_ID,
        body=json.dumps({'texts': [text], 'input_type': input_type}),
    )
    result = json.loads(response['body'].read())
    return result['embeddings'][0]


def embed_text(text: str, input_type: str = 'search_document') -> list[float]:
    """
    Embed text using Bedrock Cohere. Retries on throttling via @aws_retry.

    Args:
        text: The text to embed.
        input_type: 'search_document' for indexing, 'search_query' for retrieval.
    """
    try:
        return _invoke_embed(text, input_type)
    except ClientError as e:
        raise ExternalServiceError(
            "Bedrock embedding failed",
            context={"code": e.response['Error']['Code'], "model": EMBED_MODEL_ID},
        ) from e
    except Exception as e:
        raise ExternalServiceError("Bedrock embedding failed", context={"error": str(e)}) from e
