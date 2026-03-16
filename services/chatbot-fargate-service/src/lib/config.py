import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    region: str
    streaming_lambda_arn: str
    cors_allowed_origins: list[str]
    sessions_table: str | None
    jwt_secret: str
    jwt_cookie_domain: str | None
    jwt_cookie_secure: bool


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable '{name}' is not set")
    return value


def load_config() -> Config:
    return Config(
        region=_require("AWS_REGION"),
        streaming_lambda_arn=_require("STREAMING_LAMBDA_ARN"),
        cors_allowed_origins=[
            origin.strip()
            for origin in os.environ.get("CORS_ALLOWED_ORIGINS", "").split(",")
            if origin.strip()
        ],
        sessions_table=os.environ.get("SESSIONS_TABLE"),
        jwt_secret=_require("JWT_SECRET"),
        jwt_cookie_domain=os.environ.get("JWT_COOKIE_DOMAIN"),
        jwt_cookie_secure=os.environ.get("JWT_COOKIE_SECURE", "true").lower() == "true",
    )


# Loaded once at startup — cached for the lifetime of the container
config = load_config()
