#!/bin/sh
# Xcode Cloud: runs before xcodebuild. For the archive action, prints the
# main app's effective Release settings from the real scheme and stops the
# build before anything is archived or uploaded unless:
#   PRODUCT_BUNDLE_IDENTIFIER = com.littlesnowyowl.animalpairs
#   AP_FULL_UNLOCK_PRODUCT_ID = com.littlesnowyowl.animalpairs.fullgame
#   Config/Products.storekit holds exactly one product: that ID, NonConsumable
set -u

EXPECTED_BUNDLE_ID="com.littlesnowyowl.animalpairs"
EXPECTED_PRODUCT_ID="com.littlesnowyowl.animalpairs.fullgame"
APP_TARGET="AnimalPairs"

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT="$ROOT/AnimalPairs.xcodeproj"
STOREKIT="$ROOT/Config/Products.storekit"
SCHEME="${CI_XCODE_SCHEME:-AnimalPairs}"

SETTINGS=$(xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -destination "generic/platform=iOS" 2>/dev/null) || {
    echo "error: xcodebuild -showBuildSettings failed for scheme $SCHEME (Release)"
    exit 1
}
setting() {
    printf '%s\n' "$SETTINGS" | awk -v target="$APP_TARGET" -v key="$1" '
        /^Build settings for action .* and target / { t = $NF; sub(/:$/, "", t); next }
        t == target && $1 == key { print $3; exit }'
}

FAILED=0
check() { # label, actual, expected
    if [ "$2" = "$3" ]; then
        echo "ok: $1 = $2"
    else
        echo "error: $1 is '${2:-<missing>}' (expected $3)"
        FAILED=1
    fi
}

echo "Scheme $SCHEME, Release, target $APP_TARGET:"
check PRODUCT_BUNDLE_IDENTIFIER "$(setting PRODUCT_BUNDLE_IDENTIFIER)" "$EXPECTED_BUNDLE_ID"
check AP_FULL_UNLOCK_PRODUCT_ID "$(setting AP_FULL_UNLOCK_PRODUCT_ID)" "$EXPECTED_PRODUCT_ID"

# The local StoreKit configuration must describe the same single non-consumable.
extract() { plutil -extract "$1" raw -o - "$STOREKIT" 2>/dev/null || true; }
check "Products.storekit products[0].productID" "$(extract products.0.productID)" "$EXPECTED_PRODUCT_ID"
check "Products.storekit products[0].type" "$(extract products.0.type)" "NonConsumable"
absent() { # label, actual
    if [ -z "$2" ]; then
        echo "ok: no $1"
    else
        echo "error: Products.storekit must contain only the Full Game Unlock, but has $1 ($2)"
        FAILED=1
    fi
}
absent "second product" "$(extract products.1.productID)"
absent "subscription group" "$(extract subscriptionGroups.0.id)"
absent "non-renewing subscription" "$(extract nonRenewingSubscriptions.0.productID)"

if [ "$FAILED" -ne 0 ]; then
    echo "error: pre-archive check failed. Not archiving."
    exit 1
fi
