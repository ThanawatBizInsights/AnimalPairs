from __future__ import annotations

from datetime import datetime, timezone

from pydantic import BaseModel, ConfigDict, Field, field_serializer
from pydantic.alias_generators import to_camel


def iso_seconds(value: datetime) -> str:
    """Whole-second UTC ISO-8601 (what Swift's `.iso8601` strategy parses)."""
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class CamelModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)


class ManifestReference(BaseModel):
    manifest_version: str
    schema_version: int
    published_at: datetime
    manifest_path: str

    @field_serializer("published_at")
    def _published(self, value: datetime) -> str:
        return iso_seconds(value)


class CatalogResponse(BaseModel):
    catalog_version: int
    latest: ManifestReference | None


class AssetDownloadRequest(CamelModel):
    """Matches `AssetDownloadRequest` in AnimalPairsCore (camelCase on the wire)."""

    version: int = Field(ge=1)
    signed_transaction: str | None = None


class AssetDownloadResponse(BaseModel):
    url: str
    expires_at: datetime
    sha256: str

    @field_serializer("expires_at")
    def _expires(self, value: datetime) -> str:
        return iso_seconds(value)


class AppleNotificationRequest(CamelModel):
    signed_payload: str


class ManifestStatus(BaseModel):
    version: str
    status: str
    validation_errors: list[str]
    published_at: datetime | None = None


class AssetUploadResponse(BaseModel):
    asset_id: str
    version: int
    sha256: str
    size_bytes: int
