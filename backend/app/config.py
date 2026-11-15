"""Environment-driven configuration. Secrets never live in the repository."""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="AP_", env_file=".env", extra="ignore")

    environment: Literal["development", "test", "production"] = "development"
    database_url: str = "postgresql+psycopg://animalpairs:animalpairs@localhost:5432/animalpairs"

    # Admin API: SHA-256 hex digest of the admin bearer token. Store only the hash.
    admin_token_sha256: str = ""

    # Apple purchase verification. Root certificates are the DER files from
    # https://www.apple.com/certificateauthority/ (e.g. AppleRootCA-G3.cer).
    apple_bundle_id: str = "com.example.AnimalPairs"
    apple_app_apple_id: int | None = None  # required for Production
    apple_environment: Literal["Sandbox", "Production", "Xcode", "LocalTesting"] = "Sandbox"
    apple_root_cert_paths: list[Path] = Field(default_factory=list)
    apple_enable_online_checks: bool = True
    full_unlock_product_id: str = "com.example.animalpairs.fullgame"

    # Private asset storage.
    storage_backend: Literal["local", "s3"] = "local"
    local_storage_dir: Path = Path(".data/assets")
    # HMAC key for locally signed download URLs (development only).
    local_signing_key: str = ""
    public_base_url: str = "http://localhost:8000"
    s3_bucket: str = ""
    s3_region: str = ""
    download_url_ttl_seconds: int = 300


@lru_cache
def get_settings() -> Settings:
    return Settings()
