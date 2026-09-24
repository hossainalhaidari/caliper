#!/bin/bash
#
# Produces a signed, notarised, stapled build/Caliper-<version>.dmg.
#
# Separate from bundle.sh because they answer different questions. bundle.sh
# makes an app *you* can run. This makes one *someone else* can run, which on
# macOS means a Developer ID signature and a notarisation ticket. Releases are
# made by .github/workflows/release.yml, not by hand; this is what it runs, and
# running it yourself is how to try the pipeline.
#
# The Developer ID is $SIGN_IDENTITY, or the first one in the keychain. There is
# no ad-hoc fallback here: an ad-hoc disk image is not something to hand anyone.
#
# Notarisation takes one of two sets of credentials, neither of which this
# script ever sees the secret half of. A stored profile, for a Mac of your own:
#
#   xcrun notarytool store-credentials CaliperNotary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#   export NOTARY_PROFILE=CaliperNotary
#
# or an App Store Connect API key, which is what the release workflow uses:
#
#   export NOTARY_KEY=/path/to/AuthKey_XXXXXXXXXX.p8 NOTARY_KEY_ID=XXXXXXXXXX NOTARY_ISSUER=<uuid>
#
# CALIPER_VERSION and CALIPER_BUILD are passed through to bundle.sh. Without
# them the image holds a development build, which never updates itself.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Caliper"
STAGE="$ROOT/build/package"

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Developer ID Application:/ { print $2; exit }' || true)"
fi
if [ -z "$IDENTITY" ]; then
    echo "  ! no Developer ID Application certificate. Set SIGN_IDENTITY or install one." >&2
    exit 1
fi

if [ -z "${CALIPER_VERSION:-}" ]; then
    echo "warning: CALIPER_VERSION is unset; packaging a development build that will not update itself." >&2
fi

echo "==> building"
CALIPER_SIGN_IDENTITY="$IDENTITY" "$ROOT/Tools/bundle.sh" release
APP="$ROOT/build/$APP_NAME.app"
# From the built bundle rather than Resources/Info.plist, which a release
# overrides.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
STAGED_APP="$STAGE/$APP_NAME.app"

# bundle.sh signed it with this identity, the hardened runtime and a timestamp,
# piece by piece. Checked rather than trusted: notarisation takes minutes to
# say the same thing.
echo "==> verifying the signature of $VERSION"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

echo "==> building disk image"
rm -f "$DMG"
ln -sf /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ -n "${NOTARY_KEY:-}" ]; then
    NOTARY_AUTH=(
        --key "$NOTARY_KEY"
        --key-id "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID with NOTARY_KEY}"
        --issuer "${NOTARY_ISSUER:?Set NOTARY_ISSUER with NOTARY_KEY}"
    )
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
    echo "==> neither NOTARY_PROFILE nor NOTARY_KEY is set -- skipping notarisation"
    echo "    $DMG is signed, but Gatekeeper will refuse it on other Macs."
    exit 0
fi

echo "==> notarising (this waits for Apple)"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait

# Stapling puts the ticket inside the image, so the first launch does not need
# the network to find out the app was notarised.
echo "==> stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
# The question a user's Mac asks on first open, asked here rather than finding
# out from them.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "==> done: $DMG"
