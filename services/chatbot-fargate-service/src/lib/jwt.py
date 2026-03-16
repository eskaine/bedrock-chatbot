import logging
from datetime import datetime, timezone, timedelta

import jwt

from lib.config import config

logger = logging.getLogger(__name__)

_ALGORITHM = "HS256"
_EXPIRY_MINUTES = 15


def sign_jwt(session_id: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": session_id,
        "iat": now,
        "exp": now + timedelta(minutes=_EXPIRY_MINUTES),
    }
    return jwt.encode(payload, config.jwt_secret, algorithm=_ALGORITHM)


def verify_jwt(token: str) -> str | None:
    """Verify the token and return the sessionId, or None if invalid."""
    try:
        payload = jwt.decode(token, config.jwt_secret, algorithms=[_ALGORITHM])
        return payload.get("sub")
    except jwt.PyJWTError as e:
        logger.debug("JWT verification failed: %s", e)
        return None
