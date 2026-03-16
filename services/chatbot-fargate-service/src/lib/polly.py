import logging

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from lib.config import config

logger = logging.getLogger(__name__)

_polly = boto3.client("polly", region_name=config.region)

_MAX_CHARS = 3000


def synthesize(text: str) -> bytes:
    """Synthesize speech using Amazon Polly generative engine (Australian English).

    Raises ClientError / BotoCoreError on failure — callers should handle.
    """
    text = text.strip()[:_MAX_CHARS]
    try:
        response = _polly.synthesize_speech(
            Engine="generative",
            VoiceId="Olivia",
            LanguageCode="en-AU",
            OutputFormat="mp3",
            Text=text,
            TextType="text",
        )
        return response["AudioStream"].read()
    except (BotoCoreError, ClientError) as e:
        logger.error("Polly synthesis failed: %s", e)
        raise
