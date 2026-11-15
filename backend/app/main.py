"""Animal Pairs optional content & purchase-verification service.

The iPad game does not depend on this service. It never receives child
gameplay data, progress, names or device identifiers.
"""

import hashlib
import hmac
import re
from collections.abc import Iterator
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .apple import PurchaseVerifier, VerificationFailed, VerificationUnavailable, build_verifier
from .config import Settings, get_settings
from .db import Database
from .entitlements import apply_notification, is_revoked_after, upsert_entitlement
from .manifest_validation import publish_problems, validate_manifest
from .models import AssetObject, Manifest
from .schemas import (
    AppleNotificationRequest,
    AssetDownloadRequest,
    AssetDownloadResponse,
    AssetUploadResponse,
    CatalogResponse,
    ManifestReference,
    ManifestStatus,
)
from .storage import AssetStorage, LocalSignedStorage, build_storage

ASSET_ID = re.compile(r"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$")
ALLOWED_CONTENT_TYPES = {"image/png", "image/webp", "image/heic"}
MAX_ASSET_BYTES = 8 * 1024 * 1024


def create_app(
    settings: Settings | None = None,
    verifier: PurchaseVerifier | None = None,
    storage: AssetStorage | None = None,
    database: Database | None = None,
) -> FastAPI:
    settings = settings or get_settings()
    app = FastAPI(
        title="Animal Pairs Content Service",
        version="1.0.0",
        description="Optional versioned artwork catalog, signed downloads and Apple purchase verification.",
    )
    app.state.settings = settings
    app.state.verifier = verifier or build_verifier(settings)
    app.state.storage = storage if storage is not None else build_storage(settings)
    app.state.database = database or Database(settings.database_url)

    def db(request: Request) -> Iterator[Session]:
        yield from request.app.state.database.session()

    def require_admin(authorization: Annotated[str | None, Header()] = None) -> None:
        expected = settings.admin_token_sha256.lower()
        if not expected:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "admin API is not configured")
        token = (authorization or "").removeprefix("Bearer ").strip()
        digest = hashlib.sha256(token.encode()).hexdigest()
        if not token or not hmac.compare_digest(digest, expected):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid admin token")

    SessionDep = Annotated[Session, Depends(db)]
    Admin = Depends(require_admin)

    def storage_or_503() -> AssetStorage:
        if app.state.storage is None:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "asset storage is not configured")
        return app.state.storage

    # MARK: Public

    @app.get("/healthz", tags=["public"])
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/v1/catalog", response_model=CatalogResponse, tags=["public"])
    def catalog(session: SessionDep) -> CatalogResponse:
        published = select(Manifest).where(Manifest.status == "published")
        count = session.scalar(select(func.count()).select_from(published.subquery())) or 0
        latest = session.scalar(published.order_by(Manifest.published_at.desc(), Manifest.id.desc()).limit(1))
        reference = None
        if latest is not None and latest.published_at is not None:
            reference = ManifestReference(manifest_version=latest.version, schema_version=latest.schema_version,
                                          published_at=latest.published_at,
                                          manifest_path=f"/v1/manifests/{latest.version}")
        return CatalogResponse(catalog_version=count, latest=reference)

    @app.get("/v1/manifests/{version}", tags=["public"])
    def manifest(version: str, session: SessionDep) -> dict:
        found = session.scalar(select(Manifest).where(Manifest.version == version, Manifest.status == "published"))
        if found is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "manifest not found")
        return found.payload

    @app.post("/v1/assets/{asset_id}/download", response_model=AssetDownloadResponse, tags=["public"])
    def download(asset_id: str, body: AssetDownloadRequest, session: SessionDep) -> AssetDownloadResponse:
        artwork = _published_artwork(session, asset_id, body.version)
        if artwork is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "asset not published")
        if artwork.get("tier") != "free":
            _require_full_unlock(session, body.signed_transaction)
        stored = session.scalar(select(AssetObject).where(AssetObject.asset_id == asset_id,
                                                          AssetObject.version == body.version))
        if stored is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "asset file missing")
        url, expires = storage_or_503().signed_url(stored.storage_key, settings.download_url_ttl_seconds)
        return AssetDownloadResponse(url=url, expires_at=expires, sha256=stored.sha256)

    @app.get("/v1/files/{token}", tags=["public"], include_in_schema=False)
    def local_file(token: str, expires: int, signature: str) -> Response:
        storage = storage_or_503()
        if not isinstance(storage, LocalSignedStorage):
            raise HTTPException(status.HTTP_404_NOT_FOUND)
        try:
            data = storage.open_signed(token, expires, signature)
        except PermissionError:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "invalid or expired link")
        except FileNotFoundError:
            raise HTTPException(status.HTTP_404_NOT_FOUND)
        return Response(content=data, media_type="application/octet-stream",
                        headers={"Cache-Control": "private, max-age=60"})

    def _require_full_unlock(session: Session, signed_transaction: str | None) -> None:
        if not signed_transaction:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "full-game purchase required")
        try:
            transaction = app.state.verifier.verify_transaction(signed_transaction)
        except VerificationUnavailable:
            # Fail closed: paid content is never served without verification.
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "purchase verification unavailable")
        except VerificationFailed:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "purchase could not be verified")
        if transaction.product_id != settings.full_unlock_product_id or transaction.revoked:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "purchase does not include this content")
        if is_revoked_after(session, transaction):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "purchase was refunded or revoked")
        upsert_entitlement(session, transaction, "active", transaction.signed_at)
        session.commit()

    # MARK: Apple notifications

    @app.post("/v1/apple/notifications", tags=["apple"])
    def apple_notification(body: AppleNotificationRequest, session: SessionDep) -> dict[str, str]:
        try:
            notification = app.state.verifier.verify_notification(body.signed_payload)
        except VerificationUnavailable:
            # 503 → Apple retries later, once verification is configured.
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "verification unavailable")
        except VerificationFailed:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "invalid signed payload")
        outcome = apply_notification(session, notification, settings.full_unlock_product_id)
        return {"outcome": outcome}

    # MARK: Admin

    @app.get("/v1/admin/manifests", response_model=list[ManifestStatus], tags=["admin"], dependencies=[Admin])
    def list_manifests(session: SessionDep) -> list[ManifestStatus]:
        rows = session.scalars(select(Manifest).order_by(Manifest.id.desc())).all()
        return [ManifestStatus(version=m.version, status=m.status, validation_errors=m.validation_errors,
                               published_at=m.published_at) for m in rows]

    @app.post("/v1/admin/manifests", response_model=ManifestStatus, status_code=201, tags=["admin"],
              dependencies=[Admin])
    def upload_manifest(payload: dict, session: SessionDep) -> ManifestStatus:
        version = payload.get("manifestVersion")
        if not isinstance(version, str) or not version:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "manifestVersion is required")
        existing = session.scalar(select(Manifest).where(Manifest.version == version))
        if existing is not None and existing.status == "published":
            raise HTTPException(status.HTTP_409_CONFLICT, "published manifests are immutable; bump manifestVersion")
        errors = validate_manifest(payload)
        if existing is None:
            existing = Manifest(version=version, schema_version=int(payload.get("schemaVersion") or 0),
                                payload=payload, status="draft", validation_errors=errors)
            session.add(existing)
        else:
            existing.payload, existing.status, existing.validation_errors = payload, "draft", errors
        session.commit()
        return ManifestStatus(version=version, status=existing.status, validation_errors=errors)

    def _stored(session: Session):
        def check(asset_id: str, version: int) -> bool:
            return session.scalar(select(AssetObject.id).where(AssetObject.asset_id == asset_id,
                                                               AssetObject.version == version)) is not None
        return check

    @app.post("/v1/admin/manifests/{version}/validate", response_model=ManifestStatus, tags=["admin"],
              dependencies=[Admin])
    def validate(version: str, session: SessionDep) -> ManifestStatus:
        found = _manifest_or_404(session, version)
        if found.status == "published":
            return ManifestStatus(version=version, status=found.status, validation_errors=[],
                                  published_at=found.published_at)
        problems = publish_problems(found.payload, _stored(session),
                                    allow_placeholders=settings.environment != "production")
        found.validation_errors = problems
        found.status = "draft" if problems else "validated"
        session.commit()
        return ManifestStatus(version=version, status=found.status, validation_errors=problems)

    @app.post("/v1/admin/manifests/{version}/publish", response_model=ManifestStatus, tags=["admin"],
              dependencies=[Admin])
    def publish(version: str, session: SessionDep) -> ManifestStatus:
        from .models import utcnow

        found = _manifest_or_404(session, version)
        if found.status == "published":
            return ManifestStatus(version=version, status="published", validation_errors=[],
                                  published_at=found.published_at)
        problems = publish_problems(found.payload, _stored(session),
                                    allow_placeholders=settings.environment != "production")
        if problems:
            found.validation_errors, found.status = problems, "draft"
            session.commit()
            raise HTTPException(status.HTTP_409_CONFLICT, {"validation_errors": problems})
        found.status, found.published_at, found.validation_errors = "published", utcnow(), []
        session.commit()
        return ManifestStatus(version=version, status="published", validation_errors=[],
                              published_at=found.published_at)

    @app.put("/v1/admin/assets/{asset_id}/versions/{version}", response_model=AssetUploadResponse,
             tags=["admin"], dependencies=[Admin])
    async def upload_asset(asset_id: str, version: int, request: Request,
                           content_type: Annotated[str, Header()] = "") -> AssetUploadResponse:
        if not ASSET_ID.match(asset_id) or version < 1:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "invalid asset id or version")
        if content_type not in ALLOWED_CONTENT_TYPES:
            raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, f"allowed: {sorted(ALLOWED_CONTENT_TYPES)}")
        data = await request.body()
        if not data or len(data) > MAX_ASSET_BYTES:
            raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "empty or too large")
        digest = hashlib.sha256(data).hexdigest()
        with app.state.database.sessionmaker() as session:
            existing = session.scalar(select(AssetObject).where(AssetObject.asset_id == asset_id,
                                                                AssetObject.version == version))
            if existing is not None:
                if existing.sha256 != digest:
                    raise HTTPException(status.HTTP_409_CONFLICT, "asset versions are immutable; bump the version")
                return AssetUploadResponse(asset_id=asset_id, version=version, sha256=digest, size_bytes=len(data))
            key = f"artwork/{asset_id}/v{version}/{digest}"
            storage_or_503().put(key, data, content_type)
            session.add(AssetObject(asset_id=asset_id, version=version, storage_key=key, sha256=digest,
                                    size_bytes=len(data), content_type=content_type))
            session.commit()
        return AssetUploadResponse(asset_id=asset_id, version=version, sha256=digest, size_bytes=len(data))

    return app


def _manifest_or_404(session: Session, version: str) -> Manifest:
    found = session.scalar(select(Manifest).where(Manifest.version == version))
    if found is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "manifest not found")
    return found


def _published_artwork(session: Session, asset_id: str, version: int) -> dict | None:
    manifests = session.scalars(select(Manifest).where(Manifest.status == "published")
                                .order_by(Manifest.published_at.desc())).all()
    for manifest in manifests:
        for art in manifest.payload.get("artworks", []):
            if art.get("assetID") == asset_id and art.get("version") == version:
                return art
    return None


def app_factory() -> FastAPI:
    """Entry point for `uvicorn app.main:app_factory --factory`."""
    return create_app()
