from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.apple import VerificationFailed, VerifiedNotification, VerifiedTransaction
from app.config import Settings
from app.db import Base, Database
from app.main import create_app
from app.storage import LocalSignedStorage

ROOT = Path(__file__).resolve().parents[2]
ADMIN_TOKEN = "test-admin-token"
PRODUCT = "com.example.animalpairs.fullgame"


class FakeVerifier:
    """Stands in for Apple's SignedDataVerifier. Tokens are JSON strings that
    the test controls; anything prefixed `bad:` fails verification."""

    def verify_transaction(self, signed_transaction: str) -> VerifiedTransaction:
        if signed_transaction.startswith("bad:"):
            raise VerificationFailed("bad signature")
        data = json.loads(signed_transaction)
        return transaction(**data)

    def verify_notification(self, signed_payload: str) -> VerifiedNotification:
        if signed_payload.startswith("bad:"):
            raise VerificationFailed("bad signature")
        data = json.loads(signed_payload)
        tx = data.pop("transaction", None)
        return VerifiedNotification(
            notification_uuid=data["uuid"], notification_type=data["type"], subtype=data.get("subtype"),
            signed_at=ts(data["signed"]), transaction=transaction(**tx) if tx else None)


def ts(seconds: int) -> datetime:
    return datetime.fromtimestamp(seconds, tz=timezone.utc)


def transaction(original: str = "1000", product: str = PRODUCT, signed: int = 1_000, revoked: bool = False,
                **_: object) -> VerifiedTransaction:
    return VerifiedTransaction(transaction_id=original, original_transaction_id=original, product_id=product,
                               bundle_id="com.example.AnimalPairs", environment="Sandbox", signed_at=ts(signed),
                               revoked=revoked)


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        environment="test",
        # Set AP_TEST_DATABASE_URL to run the suite against PostgreSQL.
        database_url=os.environ.get("AP_TEST_DATABASE_URL", f"sqlite:///{tmp_path / 'test.db'}"),
        admin_token_sha256=hashlib.sha256(ADMIN_TOKEN.encode()).hexdigest(),
        local_storage_dir=tmp_path / "assets",
        local_signing_key="test-signing-key",
        full_unlock_product_id=PRODUCT,
    )


@pytest.fixture
def make_client(settings: Settings):
    database = Database(settings.database_url)
    Base.metadata.drop_all(database.engine)  # fresh schema once per test
    Base.metadata.create_all(database.engine)

    def factory(verifier=None) -> TestClient:
        storage = LocalSignedStorage(settings.local_storage_dir, settings.local_signing_key, "http://testserver")
        return TestClient(create_app(settings, verifier=verifier or FakeVerifier(), storage=storage,
                                     database=database))
    return factory


@pytest.fixture
def client(make_client) -> TestClient:
    return make_client()


@pytest.fixture
def admin() -> dict[str, str]:
    return {"Authorization": f"Bearer {ADMIN_TOKEN}"}


@pytest.fixture
def bundled_manifest() -> dict:
    return json.loads((ROOT / "AnimalPairs/Resources/ArtworkManifest.json").read_text())
