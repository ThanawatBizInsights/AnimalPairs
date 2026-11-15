"""Private asset storage with short-lived signed downloads.

* `LocalSignedStorage` (development): files on disk, served only through an
  HMAC-signed, expiring URL handled by this service.
* `S3Storage` (production): a private bucket; downloads are S3 presigned GET
  URLs. Credentials come from the standard AWS environment/role, never code.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol

from .config import Settings


class StorageUnavailable(Exception):
    pass


class AssetStorage(Protocol):
    def put(self, key: str, data: bytes, content_type: str) -> None: ...
    def signed_url(self, key: str, ttl_seconds: int) -> tuple[str, datetime]: ...


class LocalSignedStorage:
    def __init__(self, root: Path, signing_key: str, base_url: str) -> None:
        if not signing_key:
            raise StorageUnavailable("AP_LOCAL_SIGNING_KEY is required for local storage")
        self.root = root
        self._key = signing_key.encode()
        self._base_url = base_url.rstrip("/")

    def _path(self, key: str) -> Path:
        path = (self.root / key).resolve()
        if self.root.resolve() not in path.parents:
            raise ValueError("invalid storage key")
        return path

    def put(self, key: str, data: bytes, content_type: str) -> None:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(path)

    def _signature(self, key: str, expires: int) -> str:
        digest = hmac.new(self._key, f"{key}\n{expires}".encode(), hashlib.sha256).digest()
        return base64.urlsafe_b64encode(digest).decode().rstrip("=")

    def signed_url(self, key: str, ttl_seconds: int) -> tuple[str, datetime]:
        expires = int(time.time()) + ttl_seconds
        token = base64.urlsafe_b64encode(key.encode()).decode().rstrip("=")
        url = f"{self._base_url}/v1/files/{token}?expires={expires}&signature={self._signature(key, expires)}"
        return url, datetime.fromtimestamp(expires, tz=timezone.utc)

    def open_signed(self, token: str, expires: int, signature: str) -> bytes:
        """Returns file bytes if the signature is valid and unexpired."""
        padded = token + "=" * (-len(token) % 4)
        try:
            key = base64.urlsafe_b64decode(padded.encode()).decode()
        except (ValueError, UnicodeDecodeError) as error:
            raise PermissionError("bad token") from error
        if expires < int(time.time()):
            raise PermissionError("expired")
        if not hmac.compare_digest(self._signature(key, expires), signature):
            raise PermissionError("bad signature")
        path = self._path(key)
        if not path.exists():
            raise FileNotFoundError(key)
        return path.read_bytes()


class S3Storage:
    def __init__(self, bucket: str, region: str) -> None:
        if not bucket:
            raise StorageUnavailable("AP_S3_BUCKET is required for s3 storage")
        import boto3

        self._bucket = bucket
        self._client = boto3.client("s3", region_name=region or None)

    def put(self, key: str, data: bytes, content_type: str) -> None:
        self._client.put_object(Bucket=self._bucket, Key=key, Body=data, ContentType=content_type)

    def signed_url(self, key: str, ttl_seconds: int) -> tuple[str, datetime]:
        url = self._client.generate_presigned_url(
            "get_object", Params={"Bucket": self._bucket, "Key": key}, ExpiresIn=ttl_seconds
        )
        return url, datetime.fromtimestamp(time.time() + ttl_seconds, tz=timezone.utc)


def build_storage(settings: Settings) -> AssetStorage | None:
    try:
        if settings.storage_backend == "s3":
            return S3Storage(settings.s3_bucket, settings.s3_region)
        return LocalSignedStorage(settings.local_storage_dir, settings.local_signing_key, settings.public_base_url)
    except StorageUnavailable:
        return None
