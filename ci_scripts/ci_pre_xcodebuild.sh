#!/bin/sh
# Xcode Cloud: runs before xcodebuild. For the archive action, prints the
# main app's effective Release bundle identifier (from the real scheme) and
# stops the build before anything is archived or uploaded if it is wrong.
set -eu

EXPECTED_BUNDLE_ID="com.littlesnowyowl.animalpairs"
APP_TARGET="AnimalPairs"

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0

PROJECT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}/AnimalPairs.xcodeproj"
SCHEME="${CI_XCODE_SCHEME:-AnimalPairs}"

SETTINGS=$(xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -destination "generic/platform=iOS" 2>/dev/null) || {
    echo "error: xcodebuild -showBuildSettings failed for scheme $SCHEME (Release)"
    exit 1
}
ACTUAL=$(printf '%s\n' "$SETTINGS" | awk -v target="$APP_TARGET" '
    /^Build settings for action .* and target / { t = $NF; sub(/:$/, "", t); next }
    t == target && $1 == "PRODUCT_BUNDLE_IDENTIFIER" { print $3; exit }')

echo "Scheme $SCHEME, Release, target $APP_TARGET: PRODUCT_BUNDLE_IDENTIFIER = ${ACTUAL:-<not found>}"
if [ "$ACTUAL" != "$EXPECTED_BUNDLE_ID" ]; then
    echo "error: expected $EXPECTED_BUNDLE_ID (App Store Connect app 6838152398). Not archiving."
    exit 1
fi
