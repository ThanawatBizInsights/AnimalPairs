# Animal Pairs — optional backend

An **optional** content and purchase-verification service. The iPad game ships
with all artwork bundled and works fully offline; nothing in the app build
depends on this directory, and the app does not call it today.

What it is for, later:

* a versioned artwork **catalog** and **manifests** (same schema as
  `AnimalPairs/Resources/ArtworkManifest.json`, validated with the same rules
  as the Swift `ArtworkManifest.validate()`);
* an **admin** flow to upload immutable asset files, validate a manifest and
  publish it;
* **private asset storage** with short-lived **signed downloads**;
* **Apple purchase verification** for premium downloads and **App Store
  Server Notifications V2** (refunds, revocations), using Apple's official
  [`app-store-server-library`](https://github.com/apple/app-store-server-library-python).

What it deliberately does **not** do: receive child gameplay, progress, names,
birthdays, emails, photos, locations, device or advertising identifiers. The
only purchase data stored is Apple's `originalTransactionId`, product ID,
status and the time of the newest event.

## Endpoints

Interactive docs at `/docs` when running; a static copy is in
[`docs/openapi.json`](docs/openapi.json).

| Method & path | Auth | Purpose |
| --- | --- | --- |
| `GET /healthz` | – | Liveness |
| `GET /v1/catalog` | – | Count of published manifests and the latest reference |
| `GET /v1/manifests/{version}` | – | A published manifest |
| `POST /v1/assets/{assetID}/download` | – / StoreKit JWS | Signed, expiring URL. Premium artwork requires `signedTransaction` (the StoreKit 2 `Transaction.jwsRepresentation`) |
| `GET /v1/files/{token}` | HMAC link | Local-storage downloads (development) |
| `POST /v1/apple/notifications` | Apple JWS | App Store Server Notifications V2 |
| `GET/POST /v1/admin/manifests` | Admin bearer | List / upload a draft manifest |
| `POST /v1/admin/manifests/{v}/validate` | Admin bearer | Structural + publish checks |
| `POST /v1/admin/manifests/{v}/publish` | Admin bearer | Publish (immutable afterwards) |
| `PUT /v1/admin/assets/{assetID}/versions/{v}` | Admin bearer | Upload an immutable file (`image/png`, `image/webp`, `image/heic`, ≤ 8 MB) |

Wire formats match the Swift client types in
`Packages/AnimalPairsKit/Sources/AnimalPairsCore/Content/ContentRepository.swift`
(snake_case responses, whole-second ISO-8601 dates).

## Security behaviour

* **Fail closed.** Without Apple root certificates the verifier is
  unavailable: premium downloads return `503`, notifications return `503` so
  Apple retries later. Invalid signatures return `403` / `400`.
* **Scope checks.** Apple's library verifies the certificate chain, bundle ID
  and environment; the service additionally requires the configured
  full-unlock product ID and rejects revoked transactions.
* **Notifications** are de-duplicated by `notificationUUID` (Apple retries),
  and ordered by Apple's `signedDate` per `originalTransactionId`, so an older
  event delivered late never overwrites a newer state. A unique constraint
  closes the race between concurrent retries. Database errors surface as
  `5xx`, which makes Apple retry.
* **Admin token**: only its SHA-256 is configured; comparison is constant-time.
  If no hash is configured the admin API is disabled (`503`).
* **Storage** is private. S3 downloads are presigned GETs; local downloads are
  HMAC-signed and expire (`AP_DOWNLOAD_URL_TTL_SECONDS`).
* Put the service behind TLS and a rate-limiting proxy in any real deployment.

## Local setup

```bash
cd backend
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env            # then fill in values; never commit .env
docker compose up -d db         # or any PostgreSQL 14+
alembic upgrade head
uvicorn app.main:app_factory --factory --reload
```

Generate an admin token and its hash:

```bash
python -c "import hashlib,secrets;t=secrets.token_urlsafe(32);print('token:',t);print('AP_ADMIN_TOKEN_SHA256=',hashlib.sha256(t.encode()).hexdigest())"
```

Publishing content:

```bash
TOKEN=...   # the admin token (not the hash)
curl -X POST localhost:8000/v1/admin/manifests -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' --data @../AnimalPairs/Resources/ArtworkManifest.json
curl -X PUT localhost:8000/v1/admin/assets/momo.signature/versions/1 -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: image/png' --data-binary @../AnimalPairs/Assets.xcassets/Artwork/art_momo_signature.imageset/art_momo_signature.png
# …repeat for every artwork, then:
curl -X POST localhost:8000/v1/admin/manifests/2026.11.0/publish -H "Authorization: Bearer $TOKEN"
```

In `production`, manifests containing `"status": "placeholder"` artwork are
refused at publish time.

## Apple configuration (requires your Apple Developer account)

1. Create the non-consumable in App Store Connect with the same product ID as
   `AP_FULL_UNLOCK_PRODUCT_ID` and the app's `AP_FULL_UNLOCK_PRODUCT_ID`
   build setting.
2. Download Apple's root certificates (e.g. `AppleRootCA-G3.cer`) from
   <https://www.apple.com/certificateauthority/> and set
   `AP_APPLE_ROOT_CERT_PATHS='["/secure/path/AppleRootCA-G3.cer"]'`.
3. Set `AP_APPLE_BUNDLE_ID`, `AP_APPLE_ENVIRONMENT` (`Sandbox` or
   `Production`) and, for Production, `AP_APPLE_APP_APPLE_ID` (the numeric
   Apple ID of the app).
4. In App Store Connect → App Information → App Store Server Notifications,
   choose **Version 2** and point the Sandbox/Production URLs at
   `https://<your-host>/v1/apple/notifications`.
5. Use "Request a Test Notification" in App Store Connect to confirm delivery
   (the service records it with outcome `ignored`).

## Tests

```bash
python -m pytest -q                                   # SQLite
AP_TEST_DATABASE_URL=postgresql+psycopg://user:pass@host/db_test python -m pytest -q   # PostgreSQL
```

The tests use a fake verifier because genuine Apple-signed JWS cannot be
produced offline; they cover fail-closed behaviour, scope checks,
de-duplication, out-of-order delivery, immutability, signed links and
manifest validation. A test also confirms the real verifier wrapper refuses to
start without certificates (and without an app Apple ID in Production).

## Not done here

* No deployment, infrastructure, DNS, TLS or secrets provisioning.
* Not exercised against real App Store-signed transactions/notifications.
* The iPad app has the client-side protocol (`RemoteContentClient`) and DTOs
  but no network client is wired in; the launch game stays offline.
