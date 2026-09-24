#!/bin/bash
#
# Assembles Caliper.app from the SwiftPM executable.
#
# There is no .xcodeproj on purpose: the package builds and tests from the
# command line, which keeps CI and the local loop identical. This script adds
# the bundle wrapper that SwiftPM does not produce -- Resources/Info.plist, the
# icon, Sparkle, and a signature. Tools/package.sh turns the result into a
# notarised disk image.
#
# A release is built with CALIPER_VERSION and CALIPER_BUILD set, which the
# release workflow takes from the tag and from the commit count on main. Without
# them this is a development build: it keeps the placeholder version in
# Resources/Info.plist and has no update feed.

set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Caliper.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product Caliper
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

# The icon is drawn by code, not stored as an asset, so it shares the gauge
# geometry with the renderer it depicts and cannot drift from it.
swift build -c "$CONFIGURATION" --product caliper-bench >/dev/null
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
"$BIN/caliper-bench" icon "$ICONSET" >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Caliper" "$APP/Contents/MacOS/Caliper"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Sparkle decides what is newer by CFBundleVersion, so a release's build number
# has to go up every time; the commit count on main does, since main is only
# ever added to. A development build loses its feed instead: the published
# release always has a higher build number than the placeholder, so it would
# offer to replace itself with it.
PLIST="$APP/Contents/Info.plist"
if [ -n "${CALIPER_VERSION:-}" ]; then
    : "${CALIPER_BUILD:?CALIPER_BUILD must be set with CALIPER_VERSION}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CALIPER_VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CALIPER_BUILD" "$PLIST"
else
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$PLIST"
fi

# Sparkle. SwiftPM links it but, knowing nothing of bundles, leaves it beside
# the binary, where only a binary run from .build finds it. The bundle's copy
# goes where macOS apps keep theirs, and the executable is told to look there.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$BIN/Sparkle.framework" "$SPARKLE"
# Its XPC services exist for sandboxed apps, which Caliper cannot be (it reads
# the SMC and IOReport); headers and modules are for compiling against it. None
# of it runs, and every piece shipped is one more to sign and notarise.
for UNUSED in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "${SPARKLE:?}/$UNUSED" "${SPARKLE:?}/Versions/B/$UNUSED"
done
# It warns that this breaks the linker's signature, which is true and fixed by
# the signing below.
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Caliper" 2>/dev/null

# Every language, copied whole. Straight into Contents/Resources rather than
# into a SwiftPM resource bundle, because SwiftUI resolves a LocalizedStringKey
# against Bundle.main and nothing else, and String(localized:) in the libraries
# does the same. Adding a language means adding a directory; nothing here needs
# to know its name.
for LPROJ in "$ROOT"/Resources/*.lproj; do
    [ -d "$LPROJ" ] || continue
    cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# The licences travel inside the app. Sparkle's MIT terms want its notice in
# every copy, and so do the licences of what Sparkle bundles, which its LICENSE
# carries after its own. The file comes from the same SwiftPM artifact as the
# framework, so it always matches the Sparkle that ships.
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/Caliper.txt"
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Licenses/Sparkle.txt"

# Signing identity, in order of preference:
#
#   1. $CALIPER_SIGN_IDENTITY, when set -- the escape hatch for a machine with
#      several certificates, or for signing as somebody else.
#   2. the first Developer ID Application certificate in the keychain.
#   3. ad hoc.
#
# Ad hoc produces an app that runs perfectly on the Mac that built it and is
# rejected by Gatekeeper on every other one. That is a legitimate thing to
# build -- it is what a local run is -- but it is not a distributable app, and
# the script says which one you just made rather than leaving you to find out
# from someone else's "Apple could not verify" dialog.
IDENTITY="${CALIPER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"Developer ID Application:/ { print $2; exit }' || true)"
fi

if [ -n "$IDENTITY" ]; then
    # --options runtime is the hardened runtime, which notarisation requires.
    # --timestamp asks Apple's timestamp server, which it also requires: an
    # unstamped signature stops verifying the day the certificate expires,
    # which for a distributed app means every copy in the world dies at once.
    "$ROOT/Tools/sign.sh" "$APP" "$IDENTITY" --options runtime --timestamp 2>/dev/null
    echo "built  $APP"
    echo "signed $(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ { print $2; exit }')"
    echo "       make package turns it into a notarised disk image"
else
    "$ROOT/Tools/sign.sh" "$APP" - --timestamp=none >/dev/null 2>&1
    echo "built  $APP"
    echo "signed ad hoc -- runs here, refused by Gatekeeper on any other Mac"
    echo "       (no Developer ID Application certificate found; see the docs' Install and run page)"
fi
