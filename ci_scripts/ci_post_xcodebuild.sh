#!/bin/sh
# Xcode Cloud: runs after xcodebuild. For the archive action, prints the
# CFBundleIdentifier and CFBundleVersion of the main app inside the
# .xcarchive and fails the action if the identifier is not the one the App
# Store Connect app (6838152398) requires.
set -eu

EXPECTED_BUNDLE_ID="com.littlesnowyowl.animalpairs"
PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0

ARCHIVE="${CI_ARCHIVE_PATH:-}"
PLIST="$ARCHIVE/Products/Applications/AnimalPairs.app/Info.plist"
if [ -z "$ARCHIVE" ] || [ ! -f "$PLIST" ]; then
    echo "error: main app Info.plist not found in the archive ($PLIST)"
    exit 1
fi

ACTUAL=$("$PLISTBUDDY" -c "Print :CFBundleIdentifier" "$PLIST")
VERSION=$("$PLISTBUDDY" -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$("$PLISTBUDDY" -c "Print :CFBundleVersion" "$PLIST")
echo "Archived AnimalPairs.app: CFBundleIdentifier = $ACTUAL, version $VERSION ($BUILD)"
if [ "$ACTUAL" != "$EXPECTED_BUNDLE_ID" ]; then
    echo "error: expected $EXPECTED_BUNDLE_ID. Failing before distribution."
    exit 1
fi
