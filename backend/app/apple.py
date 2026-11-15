"""Apple purchase verification using Apple's official App Store Server Library.

All signature, certificate-chain, bundle-ID and environment checks are done by
`appstoreserverlibrary.signed_data_verifier.SignedDataVerifier`. This module
adds product scoping and maps results to small dataclasses so the rest of the
service (and the tests) never depend on the library's types.

If root certificates are not configured the verifier is *unavailable* and
callers must fail closed (deny paid content, reject notifications with 503 so
Apple retries later).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Protocol

from .config import Settings


class VerificationUnavailable(Exception):
    """Verification is not configured; deny access."""


class VerificationFailed(Exception):
    """The signed data is invalid, for another app, or out of scope."""


@dataclass(frozen=True)
class VerifiedTransaction:
    transaction_id: str
    original_transaction_id: str
    product_id: str
    bundle_id: str
    environment: str
    signed_at: datetime
    revoked: bool


@dataclass(frozen=True)
class VerifiedNotification:
    notification_uuid: str
    notification_type: str
    subtype: str | None
    signed_at: datetime
    transaction: VerifiedTransaction | None


class PurchaseVerifier(Protocol):
    def verify_transaction(self, signed_transaction: str) -> VerifiedTransaction: ...
    def verify_notification(self, signed_payload: str) -> VerifiedNotification: ...


def _ms(value: int | None) -> datetime:
    if value is None:
        raise VerificationFailed("missing signedDate")
    return datetime.fromtimestamp(value / 1000, tz=timezone.utc)


class AppleVerifier:
    """Real verifier. Construct via `build_verifier`."""

    def __init__(self, settings: Settings) -> None:
        from appstoreserverlibrary.models.Environment import Environment
        from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier

        certificates = [path.read_bytes() for path in settings.apple_root_cert_paths]
        environment = Environment(settings.apple_environment)
        if environment == Environment.PRODUCTION and settings.apple_app_apple_id is None:
            raise VerificationUnavailable("AP_APPLE_APP_APPLE_ID is required in Production")
        self._settings = settings
        self._verifier = SignedDataVerifier(
            certificates,
            settings.apple_enable_online_checks,
            environment,
            settings.apple_bundle_id,
            settings.apple_app_apple_id,
        )

    def verify_transaction(self, signed_transaction: str) -> VerifiedTransaction:
        from appstoreserverlibrary.signed_data_verifier import VerificationException

        try:
            payload = self._verifier.verify_and_decode_signed_transaction(signed_transaction)
        except VerificationException as error:
            raise VerificationFailed(str(error)) from error
        return self._map_transaction(payload)

    def verify_notification(self, signed_payload: str) -> VerifiedNotification:
        from appstoreserverlibrary.signed_data_verifier import VerificationException

        try:
            payload = self._verifier.verify_and_decode_notification(signed_payload)
            transaction = None
            if payload.data and payload.data.signedTransactionInfo:
                transaction = self._map_transaction(
                    self._verifier.verify_and_decode_signed_transaction(payload.data.signedTransactionInfo)
                )
        except VerificationException as error:
            raise VerificationFailed(str(error)) from error
        if not payload.notificationUUID:
            raise VerificationFailed("missing notificationUUID")
        return VerifiedNotification(
            notification_uuid=payload.notificationUUID,
            notification_type=payload.rawNotificationType or "UNKNOWN",
            subtype=payload.rawSubtype,
            signed_at=_ms(payload.signedDate),
            transaction=transaction,
        )

    def _map_transaction(self, payload) -> VerifiedTransaction:  # noqa: ANN001 - library type
        if payload.bundleId != self._settings.apple_bundle_id:
            raise VerificationFailed("transaction is for another app")
        return VerifiedTransaction(
            transaction_id=str(payload.transactionId),
            original_transaction_id=str(payload.originalTransactionId),
            product_id=payload.productId or "",
            bundle_id=payload.bundleId or "",
            environment=payload.rawEnvironment or "",
            signed_at=_ms(payload.signedDate),
            revoked=payload.revocationDate is not None,
        )


class UnavailableVerifier:
    """Used when Apple verification is not configured. Always fails closed."""

    def __init__(self, reason: str) -> None:
        self.reason = reason

    def verify_transaction(self, signed_transaction: str) -> VerifiedTransaction:
        raise VerificationUnavailable(self.reason)

    def verify_notification(self, signed_payload: str) -> VerifiedNotification:
        raise VerificationUnavailable(self.reason)


def build_verifier(settings: Settings) -> PurchaseVerifier:
    if not settings.apple_root_cert_paths:
        return UnavailableVerifier("AP_APPLE_ROOT_CERT_PATHS is not configured")
    missing = [str(p) for p in settings.apple_root_cert_paths if not p.exists()]
    if missing:
        return UnavailableVerifier(f"Apple root certificates not found: {missing}")
    try:
        return AppleVerifier(settings)
    except VerificationUnavailable as error:
        return UnavailableVerifier(str(error))
