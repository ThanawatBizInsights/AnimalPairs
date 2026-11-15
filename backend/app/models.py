"""Database tables. No child, gameplay or personal data is stored."""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import JSON, BigInteger, DateTime, Integer, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base

JSONType = JSON().with_variant(JSONB(), "postgresql")


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Manifest(Base):
    """A versioned artwork manifest: draft → validated → published."""

    __tablename__ = "manifests"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    version: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    schema_version: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(16), default="draft")
    payload: Mapped[dict] = mapped_column(JSONType)
    validation_errors: Mapped[list] = mapped_column(JSONType, default=list)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class AssetObject(Base):
    """One immutable stored illustration file (private storage)."""

    __tablename__ = "asset_objects"
    __table_args__ = (UniqueConstraint("asset_id", "version", name="uq_asset_version"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    asset_id: Mapped[str] = mapped_column(String(128), index=True)
    version: Mapped[int] = mapped_column(Integer)
    storage_key: Mapped[str] = mapped_column(String(512))
    sha256: Mapped[str] = mapped_column(String(64))
    size_bytes: Mapped[int] = mapped_column(BigInteger)
    content_type: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Entitlement(Base):
    """Purchase state keyed by Apple's original transaction ID only."""

    __tablename__ = "entitlements"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    original_transaction_id: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    product_id: Mapped[str] = mapped_column(String(128))
    status: Mapped[str] = mapped_column(String(16))  # active | revoked
    environment: Mapped[str] = mapped_column(String(32))
    # Apple's signedDate of the newest event applied; older events are ignored.
    last_event_signed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class AppleNotification(Base):
    """Processed App Store Server Notifications V2, for de-duplication."""

    __tablename__ = "apple_notifications"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    notification_uuid: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    notification_type: Mapped[str] = mapped_column(String(64))
    subtype: Mapped[str | None] = mapped_column(String(64), nullable=True)
    original_transaction_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    signed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    outcome: Mapped[str] = mapped_column(String(32))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
