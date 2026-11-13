#!/bin/zsh
# Builds dist/ReelPrep.dmg: the app signed with the Developer ID certificate in the keychain (hardened runtime,
# secure timestamp), the dmg signed too, then notarized by Apple and stapled so it opens on any Mac without the
# "Open Anyway" step. NOTARY_PROFILE names the stored notarytool login (default: the name in
# scripts/notary_profile.local, git-ignored, else "ReelPrep").
# SIGN_IDENTITY overrides the certificate; without one the dmg is ad-hoc signed and not notarized.
set -euo pipefail
cd "${0:A:h}/.."
scripts/make_app.sh
APP=dist/ReelPrep.app
DMG=dist/ReelPrep.dmg
ID=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -n1)}
LOCAL_PROFILE=$( [[ -f scripts/notary_profile.local ]] && head -n1 scripts/notary_profile.local || echo ReelPrep )
PROFILE=${NOTARY_PROFILE:-$LOCAL_PROFILE}

xattr -cr "$APP"
if [[ -n "$ID" ]]; then
    OPTS=(--force --timestamp --options runtime --sign "$ID")
    codesign "${OPTS[@]}" "$APP/Contents/Helpers/reelprep"
    codesign "${OPTS[@]}" "$APP"
    codesign --verify --deep --strict --verbose=1 "$APP"
fi

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/ReelPrep.app"
ln -s /Applications "$STAGE/Applications"
[[ -e "$DMG" ]] && /usr/bin/trash "$DMG"
hdiutil create -quiet -volname ReelPrep -srcfolder "$STAGE" -ov -format UDZO "$DMG"
/usr/bin/trash "$STAGE"

if [[ -z "$ID" ]]; then
    codesign --force --sign - "$DMG"
    echo "Built $DMG (ad-hoc: no Developer ID certificate)"
    exit 0
fi
codesign --force --timestamp --sign "$ID" "$DMG"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Notarizing (a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    echo "Built $DMG (signed, notarized, stapled)"
else
    echo "Built $DMG (signed with $ID, not notarized: no notary profile \"$PROFILE\")"
fi
