#!/bin/sh
# Xcode Cloud: runs after xcodebuild. For the archive action, reads the main
# app's Info.plist inside the .xcarchive and fails the action, with a clear
# message, unless both values are exactly what App Store Connect expects:
#   CFBundleIdentifier    = com.littlesnowyowl.animalpairs          (app 6838152398)
#   APFullUnlockProductID = com.littlesnowyowl.animalpairs.fullgame (Full Game Unlock)
#   APSupportURL          = https://littlesnowyowl.com/games/animal-pairs/support/
#   APPrivacyPolicyURL    = https://littlesnowyowl.com/games/animal-pairs/privacy/
#   APTermsOfUseURL       = Apple's standard EULA (opened from Parents)
# and that the opening video is bundled in the app.
set -u

EXPECTED_BUNDLE_ID="com.littlesnowyowl.animalpairs"
EXPECTED_PRODUCT_ID="com.littlesnowyowl.animalpairs.fullgame"
EXPECTED_SUPPORT_URL="https://littlesnowyowl.com/games/animal-pairs/support/"
EXPECTED_PRIVACY_URL="https://littlesnowyowl.com/games/animal-pairs/privacy/"
EXPECTED_TERMS_URL="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0

ARCHIVE="${CI_ARCHIVE_PATH:-}"
PLIST="$ARCHIVE/Products/Applications/AnimalPairs.app/Info.plist"
if [ -z "$ARCHIVE" ] || [ ! -f "$PLIST" ]; then
    echo "error: main app Info.plist not found in the archive ($PLIST)"
    exit 1
fi

# Prints the value, or nothing when the key is missing.
read_key() { "$PLISTBUDDY" -c "Print :$1" "$PLIST" 2>/dev/null || true; }

FAILED=0
check() { # key, expected
    actual=$(read_key "$1")
    if [ -z "$actual" ]; then
        echo "error: $1 is missing from AnimalPairs.app/Info.plist (expected $2)"
        FAILED=1
    elif [ "$actual" != "$2" ]; then
        echo "error: $1 is $actual in AnimalPairs.app/Info.plist (expected $2)"
        FAILED=1
    else
        echo "ok: $1 = $actual"
    fi
}

echo "Archived AnimalPairs.app: version $(read_key CFBundleShortVersionString) ($(read_key CFBundleVersion))"
check CFBundleIdentifier "$EXPECTED_BUNDLE_ID"
check APFullUnlockProductID "$EXPECTED_PRODUCT_ID"
check APSupportURL "$EXPECTED_SUPPORT_URL"
check APPrivacyPolicyURL "$EXPECTED_PRIVACY_URL"
check APTermsOfUseURL "$EXPECTED_TERMS_URL"
# The bundled opening video (never streamed).
VIDEO="$ARCHIVE/Products/Applications/AnimalPairs.app/opening_video.mp4"
if [ -f "$VIDEO" ] && [ "$(wc -c < "$VIDEO")" -gt 1000000 ]; then
    echo "ok: opening_video.mp4 bundled ($(wc -c < "$VIDEO" | tr -d ' ') bytes)"
else
    echo "error: opening_video.mp4 is missing from AnimalPairs.app (or too small)"
    FAILED=1
fi

# The privacy manifest ships in the app and declares no tracking.
MANIFEST="$ARCHIVE/Products/Applications/AnimalPairs.app/PrivacyInfo.xcprivacy"
TRACKING=$("$PLISTBUDDY" -c "Print :NSPrivacyTracking" "$MANIFEST" 2>/dev/null || true)
if [ "$(printf %s "$TRACKING" | tr "[:upper:]" "[:lower:]")" = "false" ]; then
    echo "ok: PrivacyInfo.xcprivacy bundled (NSPrivacyTracking = false)"
else
    echo "error: PrivacyInfo.xcprivacy missing from AnimalPairs.app or NSPrivacyTracking is not false"
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "error: archive check failed. Failing before distribution."
    exit 1
fi
