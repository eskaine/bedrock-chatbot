import json
import os
import boto3
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    region: str
    environment: str
    db_host: str
    db_name: str
    db_user: str
    db_password: str
    db_port: int


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable '{name}' is not set")
    return value


def _load_db_secret(secret_arn: str, region: str) -> dict[str, str]:
    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_arn)
    return json.loads(response["SecretString"])


def load_config() -> Config:
    region = _require("AWS_REGION")
    db_secret_arn = _require("DB_SECRET_ARN")

    secret = _load_db_secret(db_secret_arn, region)

    return Config(
        region=region,
        environment=_require("ENVIRONMENT"),
        db_host=_require("POSTGRES_HOST"),
        db_name=_require("POSTGRES_DB"),
        db_user=secret["username"],
        db_password=secret["password"],
        db_port=int(secret.get("port", 5432)),
    )


# Loaded once at cold start — cached for the lifetime of the Lambda instance
config = load_config()
