import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    region: str
    model_id: str
    s3_raw_bucket: str
    s3_docs_bucket: str
    prompt_arn: str
    prompt_version: str


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable '{name}' is not set")
    return value


def load_config() -> Config:
    return Config(
        region=_require("AWS_REGION"),
        model_id=_require("MODEL_ID"),
        s3_raw_bucket=_require("S3_RAW_BUCKET"),
        s3_docs_bucket=_require("S3_DOCS_BUCKET"),
        prompt_arn=_require("PROMPT_ARN"),
        prompt_version=_require("PROMPT_VERSION"),
    )


# Loaded once at cold start — cached for the lifetime of the Lambda instance
config = load_config()
