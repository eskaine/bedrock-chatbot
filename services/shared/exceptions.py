class ServiceError(Exception):
    """Base for all service-level errors."""

    def __init__(self, message: str, context: dict | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.context = context or {}

    def __str__(self) -> str:
        if self.context:
            ctx = ', '.join(f'{k}={v}' for k, v in self.context.items())
            return f"{self.message} [{ctx}]"
        return self.message


class ExternalServiceError(ServiceError):
    """Failed call to an external API (Bedrock, SecretsManager, etc.)."""


class ThrottlingError(ExternalServiceError):
    """External service is rate-limiting requests."""


class StorageError(ServiceError):
    """Database or persistence layer failure."""


class ValidationError(ServiceError):
    """Input failed validation."""


class ConfigurationError(ServiceError):
    """Missing or invalid service configuration."""

