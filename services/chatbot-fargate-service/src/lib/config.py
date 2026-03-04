import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    region: str
    streaming_lambda_arn: str
    cors_allowed_origins: list[str]
    sessions_table: str | None


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
    )


# Loaded once at startup — cached for the lifetime of the container
config = load_config()
