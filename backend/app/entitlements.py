"""Entitlement bookkeeping driven by verified Apple data.

Rules:
* Notifications are de-duplicated by `notificationUUID` (Apple retries).
* A notification is acknowledged only once it is stored (or already was).
  Any other database failure raises `NotificationStoreUnavailable`, so the
  endpoint answers with a retryable error and Apple redelivers it.
* Events are ordered by Apple's `signedDate`; an older event never overwrites
  a newer state (out-of-order delivery).
* Only the configured full-unlock product is considered.
"""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from .apple import VerifiedNotification, VerifiedTransaction
from .models import AppleNotification, Entitlement

REVOKING = {"REFUND", "REVOKE"}


class NotificationStoreUnavailable(Exception):
    """The notification could not be stored; Apple should send it again."""
GRANTING = {"ONE_TIME_CHARGE", "REFUND_REVERSED"}


def as_utc(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def upsert_entitlement(session: Session, transaction: VerifiedTransaction, status: str, signed_at: datetime) -> str:
    entitlement = session.scalar(
        select(Entitlement).where(Entitlement.original_transaction_id == transaction.original_transaction_id)
    )
    if entitlement is None:
        session.add(Entitlement(
            original_transaction_id=transaction.original_transaction_id,
            product_id=transaction.product_id,
            status=status,
            environment=transaction.environment,
            last_event_signed_at=signed_at,
        ))
        return "applied"
    if as_utc(signed_at) <= as_utc(entitlement.last_event_signed_at):
        return "stale"
    entitlement.status = status
    entitlement.last_event_signed_at = signed_at
    return "applied"


def notification_is_stored(session: Session, notification_uuid: str) -> bool:
    return session.scalar(select(AppleNotification.id).where(
        AppleNotification.notification_uuid == notification_uuid)) is not None


def apply_notification(session: Session, notification: VerifiedNotification, product_id: str) -> str:
    """Applies a verified notification exactly once. Returns the outcome.

    Raises `NotificationStoreUnavailable` when it could not be stored."""
    if notification_is_stored(session, notification.notification_uuid):
        return "duplicate"

    outcome = "ignored"
    transaction = notification.transaction
    if transaction is not None and transaction.product_id != product_id:
        outcome = "other_product"
    elif transaction is not None:
        if notification.notification_type in REVOKING or transaction.revoked:
            outcome = upsert_entitlement(session, transaction, "revoked", notification.signed_at)
        elif notification.notification_type in GRANTING:
            outcome = upsert_entitlement(session, transaction, "active", notification.signed_at)

    session.add(AppleNotification(
        notification_uuid=notification.notification_uuid,
        notification_type=notification.notification_type,
        subtype=notification.subtype,
        original_transaction_id=transaction.original_transaction_id if transaction else None,
        signed_at=notification.signed_at,
        outcome=outcome,
    ))
    try:
        session.commit()
    except IntegrityError as error:
        session.rollback()
        # A duplicate only if a concurrent delivery really stored this UUID
        # first; any other constraint failure must be retried.
        try:
            stored = notification_is_stored(session, notification.notification_uuid)
        except SQLAlchemyError as lookup_error:
            session.rollback()
            raise NotificationStoreUnavailable("could not check for a stored duplicate") from lookup_error
        if stored:
            return "duplicate"
        raise NotificationStoreUnavailable("notification was not stored") from error
    except SQLAlchemyError as error:
        session.rollback()
        raise NotificationStoreUnavailable("database error while storing the notification") from error
    return outcome


def is_revoked_after(session: Session, transaction: VerifiedTransaction) -> bool:
    """True if the server learned of a revocation newer than this transaction."""
    entitlement = session.scalar(
        select(Entitlement).where(Entitlement.original_transaction_id == transaction.original_transaction_id)
    )
    return (
        entitlement is not None
        and entitlement.status == "revoked"
        and as_utc(entitlement.last_event_signed_at) >= as_utc(transaction.signed_at)
    )
