import re
import logging

import boto3
from botocore.exceptions import ClientError

from lib.config import config

logger = logging.getLogger(__name__)

SESSION_ID_RE = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
)

_dynamodb = boto3.resource("dynamodb", region_name=config.region)


def load_history(session_id: str) -> list[dict]:
    if not config.sessions_table or not SESSION_ID_RE.match(session_id or ""):
        return []
    try:
        table = _dynamodb.Table(config.sessions_table)
        result = table.get_item(Key={"sessionId": session_id})
        messages = result.get("Item", {}).get("messages", [])
        return [
            {"role": m["role"], "content": m["content"][0]["text"]}
            for m in messages
            if m.get("content") and m["content"][0].get("text")
        ]
    except ClientError as e:
        logger.error("Failed to load history: %s", e)
        return []
