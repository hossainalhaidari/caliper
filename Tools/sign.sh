#!/bin/bash
#
# Signs Caliper.app from the inside out: Sparkle's helpers, then Sparkle, then
# the app.
#
#   Tools/sign.sh <Caliper.app> <identity> [codesign options...]
#
# Not `codesign --deep`, which signs everything nested with the outer bundle's
# options. Apple's advice, and Sparkle's, is to sign each piece of nested code on
# its own, innermost first. Notarisation requires the hardened runtime and a
# secure timestamp of every one of them, not only of the app, which is why the
# options are passed through to each call.

set -euo pipefail

APP="$1"
IDENTITY="$2"
shift 2
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

for NESTED in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --sign "$IDENTITY" "$@" "$NESTED"
done

codesign --force --sign "$IDENTITY" "$@" "$APP"
