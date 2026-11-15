from __future__ import annotations

import copy
import json
from pathlib import Path

from fastapi.testclient import TestClient

from app.apple import UnavailableVerifier, build_verifier
from app.config import Settings
from app.manifest_validation import validate_manifest

from .conftest import PRODUCT

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64


def upload_all_assets(client: TestClient, admin: dict, manifest: dict) -> None:
    for art in manifest["artworks"]:
        r = client.put(f"/v1/admin/assets/{art['assetID']}/versions/{art['version']}",
                       content=PNG + art["assetID"].encode(), headers={**admin, "Content-Type": "image/png"})
        assert r.status_code == 200, r.text


def publish(client: TestClient, admin: dict, manifest: dict) -> None:
    assert client.post("/v1/admin/manifests", json=manifest, headers=admin).status_code == 201
    upload_all_assets(client, admin, manifest)
    r = client.post(f"/v1/admin/manifests/{manifest['manifestVersion']}/publish", headers=admin)
    assert r.status_code == 200, r.text


# MARK: Manifest validation

def test_bundled_manifest_is_valid(bundled_manifest):
    assert validate_manifest(bundled_manifest) == []


def test_validation_catches_duplicates_and_bad_defaults(bundled_manifest):
    broken = copy.deepcopy(bundled_manifest)
    broken["artworks"].append(copy.deepcopy(broken["artworks"][0]))
    broken["artworks"][1]["tier"] = "gold"
    default = next(a for a in broken["artworks"] if a["assetID"] == "luna.signature")
    default["tier"] = "premium"
    errors = validate_manifest(broken)
    assert any("duplicate asset" in e for e in errors)
    assert any("tier must be" in e for e in errors)
    assert any("luna: default pose must be free" in e for e in errors)
    assert validate_manifest({"schemaVersion": 2}) != []


# MARK: Admin

def test_admin_requires_token(client):
    assert client.get("/v1/admin/manifests").status_code == 401
    assert client.get("/v1/admin/manifests", headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_admin_disabled_without_configured_hash(settings, make_client):
    settings.admin_token_sha256 = ""
    assert make_client().get("/v1/admin/manifests").status_code == 503


def test_publish_requires_uploaded_files_and_is_immutable(client, admin, bundled_manifest):
    assert client.post("/v1/admin/manifests", json=bundled_manifest, headers=admin).status_code == 201
    r = client.post(f"/v1/admin/manifests/{bundled_manifest['manifestVersion']}/publish", headers=admin)
    assert r.status_code == 409
    assert "has not been uploaded" in r.text
    assert client.get("/v1/catalog").json() == {"catalog_version": 0, "latest": None}

    upload_all_assets(client, admin, bundled_manifest)
    r = client.post(f"/v1/admin/manifests/{bundled_manifest['manifestVersion']}/publish", headers=admin)
    assert r.status_code == 200
    catalog = client.get("/v1/catalog").json()
    assert catalog["catalog_version"] == 1
    assert catalog["latest"]["manifest_version"] == bundled_manifest["manifestVersion"]
    assert catalog["latest"]["published_at"].endswith("Z") and "." not in catalog["latest"]["published_at"]
    assert client.get(catalog["latest"]["manifest_path"]).json() == bundled_manifest
    # Published manifests cannot be overwritten.
    assert client.post("/v1/admin/manifests", json=bundled_manifest, headers=admin).status_code == 409


def test_asset_versions_are_immutable(client, admin):
    url = "/v1/admin/assets/momo.signature/versions/1"
    headers = {**admin, "Content-Type": "image/png"}
    assert client.put(url, content=PNG, headers=headers).status_code == 200
    assert client.put(url, content=PNG, headers=headers).status_code == 200  # idempotent retry
    assert client.put(url, content=PNG + b"x", headers=headers).status_code == 409
    assert client.put(url, content=PNG, headers={**admin, "Content-Type": "text/html"}).status_code == 415


def test_production_rejects_placeholders(settings, make_client, admin, bundled_manifest):
    settings.environment = "production"
    client = make_client()
    assert client.post("/v1/admin/manifests", json=bundled_manifest, headers=admin).status_code == 201
    upload_all_assets(client, admin, bundled_manifest)
    r = client.post(f"/v1/admin/manifests/{bundled_manifest['manifestVersion']}/publish", headers=admin)
    assert r.status_code == 409
    assert "placeholder" in r.text


# MARK: Downloads

def test_free_asset_download_and_signed_link(client, admin, bundled_manifest):
    publish(client, admin, bundled_manifest)
    r = client.post("/v1/assets/momo.signature/download", json={"version": 1})
    assert r.status_code == 200
    body = r.json()
    assert body["sha256"] and "." not in body["expires_at"]
    path = body["url"].replace("http://testserver", "")
    assert client.get(path).content.startswith(PNG)
    assert client.get(path.replace("signature=", "signature=x")).status_code == 403


def test_premium_download_fails_closed(client, admin, bundled_manifest, make_client):
    publish(client, admin, bundled_manifest)
    assert client.post("/v1/assets/momo.play/download", json={"version": 1}).status_code == 403
    bad = client.post("/v1/assets/momo.play/download", json={"version": 1, "signedTransaction": "bad:jws"})
    assert bad.status_code == 403
    wrong_product = json.dumps({"original": "1", "product": "com.example.other"})
    assert client.post("/v1/assets/momo.play/download",
                       json={"version": 1, "signedTransaction": wrong_product}).status_code == 403
    revoked = json.dumps({"original": "2", "revoked": True})
    assert client.post("/v1/assets/momo.play/download",
                       json={"version": 1, "signedTransaction": revoked}).status_code == 403

    unconfigured = make_client(verifier=UnavailableVerifier("not configured"))
    r = unconfigured.post("/v1/assets/momo.play/download",
                          json={"version": 1, "signedTransaction": json.dumps({"original": "3"})})
    assert r.status_code == 503, "paid content is never served without verification"


def test_premium_download_with_verified_purchase(client, admin, bundled_manifest):
    publish(client, admin, bundled_manifest)
    ok = client.post("/v1/assets/momo.play/download",
                     json={"version": 1, "signedTransaction": json.dumps({"original": "42", "signed": 100})})
    assert ok.status_code == 200


def test_unknown_or_unpublished_asset_is_404(client):
    assert client.post("/v1/assets/momo.signature/download", json={"version": 1}).status_code == 404


# MARK: Apple notifications

def notify(client: TestClient, uuid: str, kind: str, signed: int, original: str = "77", product: str = PRODUCT):
    payload = json.dumps({"uuid": uuid, "type": kind, "signed": signed,
                          "transaction": {"original": original, "product": product, "signed": signed}})
    return client.post("/v1/apple/notifications", json={"signedPayload": payload})


def test_notifications_are_deduplicated(client):
    assert notify(client, "n1", "ONE_TIME_CHARGE", 100).json() == {"outcome": "applied"}
    assert notify(client, "n1", "ONE_TIME_CHARGE", 100).json() == {"outcome": "duplicate"}


def test_out_of_order_notifications_keep_newest_state(client, admin, bundled_manifest):
    publish(client, admin, bundled_manifest)
    # The refund (newer) arrives before the purchase (older).
    assert notify(client, "refund", "REFUND", 200).json() == {"outcome": "applied"}
    assert notify(client, "charge", "ONE_TIME_CHARGE", 100).json() == {"outcome": "stale"}
    # A device transaction signed before the refund is denied.
    old_jws = json.dumps({"original": "77", "signed": 150})
    assert client.post("/v1/assets/momo.play/download",
                       json={"version": 1, "signedTransaction": old_jws}).status_code == 403
    # A refund reversal signed later restores access.
    assert notify(client, "reversed", "REFUND_REVERSED", 300).json() == {"outcome": "applied"}
    assert client.post("/v1/assets/momo.play/download",
                       json={"version": 1, "signedTransaction": old_jws}).status_code == 200


def test_notification_for_other_product_is_recorded_not_applied(client):
    assert notify(client, "x", "ONE_TIME_CHARGE", 100, product="com.example.other").json() == {"outcome": "other_product"}


def test_notification_verification_failures(client, make_client):
    assert client.post("/v1/apple/notifications", json={"signedPayload": "bad:x"}).status_code == 400
    unconfigured = make_client(verifier=UnavailableVerifier("no certs"))
    # 503 makes Apple retry once verification is configured.
    assert unconfigured.post("/v1/apple/notifications", json={"signedPayload": "{}"}).status_code == 503


def test_real_verifier_fails_closed_without_certificates(tmp_path: Path):
    assert isinstance(build_verifier(Settings(apple_root_cert_paths=[])), UnavailableVerifier)
    missing = Settings(apple_root_cert_paths=[tmp_path / "AppleRootCA-G3.cer"])
    assert isinstance(build_verifier(missing), UnavailableVerifier)


def test_real_verifier_requires_app_apple_id_in_production(tmp_path: Path):
    cert = tmp_path / "root.cer"
    cert.write_bytes(b"not-a-real-cert")
    settings = Settings(apple_root_cert_paths=[cert], apple_environment="Production", apple_app_apple_id=None)
    assert isinstance(build_verifier(settings), UnavailableVerifier)
