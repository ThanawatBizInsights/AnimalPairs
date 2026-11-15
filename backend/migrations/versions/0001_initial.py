"""Initial schema: manifests, asset objects, entitlements, Apple notifications.

Revision ID: 0001_initial
Revises:
Create Date: 2026-11-15
"""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None

JSONType = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")


def upgrade() -> None:
    op.create_table(
        "manifests",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("version", sa.String(64), nullable=False),
        sa.Column("schema_version", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("payload", JSONType, nullable=False),
        sa.Column("validation_errors", JSONType, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_manifests_version", "manifests", ["version"], unique=True)

    op.create_table(
        "asset_objects",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("asset_id", sa.String(128), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("storage_key", sa.String(512), nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("content_type", sa.String(64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("asset_id", "version", name="uq_asset_version"),
    )
    op.create_index("ix_asset_objects_asset_id", "asset_objects", ["asset_id"])

    op.create_table(
        "entitlements",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("original_transaction_id", sa.String(64), nullable=False),
        sa.Column("product_id", sa.String(128), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("environment", sa.String(32), nullable=False),
        sa.Column("last_event_signed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_entitlements_original_transaction_id", "entitlements", ["original_transaction_id"], unique=True)

    op.create_table(
        "apple_notifications",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("notification_uuid", sa.String(64), nullable=False),
        sa.Column("notification_type", sa.String(64), nullable=False),
        sa.Column("subtype", sa.String(64), nullable=True),
        sa.Column("original_transaction_id", sa.String(64), nullable=True),
        sa.Column("signed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("outcome", sa.String(32), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_apple_notifications_notification_uuid", "apple_notifications", ["notification_uuid"], unique=True)


def downgrade() -> None:
    op.drop_table("apple_notifications")
    op.drop_table("entitlements")
    op.drop_table("asset_objects")
    op.drop_table("manifests")
