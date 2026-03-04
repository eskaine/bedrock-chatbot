"""
formatter.py — Bedrock document formatting (LLM swap point).

To swap the LLM: replace the bedrock.converse call in _call_bedrock()
with any other model invocation. The interface is: str -> str.
"""

import logging

import boto3
from botocore.exceptions import ClientError

from lib.config import config
from lib.constants import MAX_TOKENS, TEMPERATURE
from shared.exceptions import ExternalServiceError
from shared.retry import aws_retry

logger = logging.getLogger(__name__)

_bedrock       = boto3.client('bedrock-runtime', region_name=config.region)
_bedrock_agent = boto3.client('bedrock-agent',   region_name=config.region)


def _fetch_system_prompt() -> str:
    """Fetch the preprocessing system prompt from Bedrock Prompt Management.
    Called once at cold start — result cached in module-level variable.
    """
    logger.info(
        "Fetching system prompt from Prompt Management",
        extra={'arn': config.prompt_arn, 'version': config.prompt_version},
    )
    response = _bedrock_agent.get_prompt(
        promptIdentifier=config.prompt_arn,
        promptVersion=config.prompt_version,
    )
    text = response['variants'][0]['templateConfiguration']['text']['text']
    if not text:
        raise ExternalServiceError("Prompt variant returned empty text")
    logger.info("System prompt fetched successfully")
    return text


# Fetched once at cold start — cached for the Lambda instance lifetime
system_prompt: str = _fetch_system_prompt()


@aws_retry(max_attempts=3, base_delay=1.0)
def _call_bedrock(raw_content: str) -> str:
    response = _bedrock.converse(
        modelId=config.model_id,
        system=[{'text': system_prompt}],
        messages=[{
            'role': 'user',
            'content': [{'text': raw_content}],
        }],
        inferenceConfig={
            'maxTokens': MAX_TOKENS,
            'temperature': TEMPERATURE,
        },
    )
    return response['output']['message']['content'][0]['text']


def format_document(raw_content: str) -> str:
    logger.info("Formatting document with Bedrock", extra={'model': config.model_id})
    try:
        formatted = _call_bedrock(raw_content)
    except ClientError as e:
        raise ExternalServiceError(
            "Bedrock formatting failed",
            context={'code': e.response['Error']['Code'], 'model': config.model_id},
        ) from e
    logger.info("Formatting complete", extra={'length': len(formatted)})
    return formatted
