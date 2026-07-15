#!/usr/bin/env bash
# scripts/ci/package_and_publish.sh
#
# CI counterpart of scripts/release.sh's back half. Runs on a GitHub Actions
# macOS runner AFTER the workflow has:
#   - imported the Developer ID Application cert into a keychain,
#   - installed the "Perch Profile" Developer ID provisioning profile,
#   - written the App Store Connect API key (.p8) + Sparkle EdDSA private key
#     to files,
#   - run xcodegen + resolved SPM (so Sparkle's sign_update exists).
#
# It then: archive (Developer ID, manual) → export → notarize (ASC API key) →
# staple → DMG → notarize → staple → Sparkle-sign the .zip → insert appcast
# item → create the GitHub release (.zip + .dmg) → push the updated appcast to
# main. NO version bump (the release commit already carries it) and NO tag
# creation (the tag push is what triggered the workflow).
#
# Required env:
#   TAG              e.g. v2.2.0            (the tag being released)
#   VERSION          e.g. 2.2.0            (CFBundleShortVersionString, no "v")
#   PRERELEASE       "" | beta             (channel suffix; empty = stable)
#   ASC_KEY_PATH     /path/AuthKey.p8      (App Store Connect API key)
#   ASC_KEY_ID       10-char Key ID
#   ASC_ISSUER_ID    Issuer UUID
#   SPARKLE_KEY_PATH /path/sparkle_key     (EdDSA private key, generate_keys -x)
#   GH_TOKEN         (gh auth; the workflow passes GITHUB_TOKEN)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ── Constants (mirror scripts/release.sh) ───────────────────────────
TEAM_ID="T8F5T6HKG8"
SCHEME="Perch"
PROJECT="Perch.xcodeproj"
PRODUCT="Perch"
GH_REPO="xVanTuring/Perch"
APPCAST="appcast.xml"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
BUILD_DIR=".build/release"
PROVISIONING_PROFILE_NAME="Perch Profile"
SPARKLE_BIN_DIR="${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin"

: "${TAG:?TAG required}"
: "${VERSION:?VERSION required}"
PRERELEASE="${PRERELEASE:-}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH required}"
: "${ASC_KEY_ID:?ASC_KEY_ID required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID required}"
: "${SPARKLE_KEY_PATH:?SPARKLE_KEY_PATH required}"

if [[ -n "$PRERELEASE" ]]; then
    TITLE="v${VERSION} ${PRERELEASE}"
    ZIP_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.dmg"
    PRERELEASE_FLAG="--prerelease"
else
    TITLE="v${VERSION}"
    ZIP_ASSET="${PRODUCT}-${VERSION}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}.dmg"
    PRERELEASE_FLAG=""
fi

DIST_DIR="dist/${TAG}"
ZIP="${DIST_DIR}/${ZIP_ASSET}"
DMG="${DIST_DIR}/${DMG_ASSET}"
APP="${DIST_DIR}/${PRODUCT}.app"
ARCHIVE="${BUILD_DIR}/${PRODUCT}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"

echo "==> Packaging ${TAG} (version ${VERSION}${PRERELEASE:+ / channel $PRERELEASE})"
rm -rf "${DIST_DIR}" "${ARCHIVE}" "${EXPORT_DIR}"
mkdir -p "${DIST_DIR}"

notary() {
    # notarytool with the ASC API key.
    xcrun notarytool "$@" \
        --key "$ASC_KEY_PATH" \
        --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID"
}

# ── Archive (Developer ID, manual signing — no cloud provisioning) ──
echo "==> Archiving Release (Developer ID, manual signing)"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_NAME" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    -quiet

[[ -d "$ARCHIVE" ]] || { echo "ERROR: archive not produced at $ARCHIVE" >&2; exit 1; }

# ── Export with Developer ID (re-affirm signing via ExportOptions) ──
echo "==> Exporting Developer ID app (${EXPORT_OPTIONS})"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | tail -20

BUILT_APP="${EXPORT_DIR}/${PRODUCT}.app"
[[ -d "$BUILT_APP" ]] || { echo "ERROR: exported .app missing at $BUILT_APP" >&2; exit 1; }
ditto "$BUILT_APP" "$APP"

echo "==> Verifying codesign"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "TeamIdentifier|Authority|Format" || true

# Build number for the appcast: read from the BUILT app so it always matches
# what shipped (rather than re-parsing project.yml).
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
echo "==> Build number ${BUILD_NUMBER}"

# ── Zip + notarize app ──────────────────────────────────────────────
echo "==> Zipping for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting .zip to Apple notarization (--wait)"
notary submit "$ZIP" --wait 2>&1 | tee "${DIST_DIR}/notary-app.log"

echo "==> Stapling ticket onto .app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP" 2>&1 || true

# Re-zip: the pre-notary zip lacks the staple; Sparkle needs the stapled bundle.
echo "==> Re-zipping stapled app"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── DMG ─────────────────────────────────────────────────────────────
echo "==> Creating DMG"
DMG_STAGE="${DIST_DIR}/.dmg-stage"
rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
ditto "$APP" "${DMG_STAGE}/${PRODUCT}.app"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create -volname "${PRODUCT} ${VERSION}" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

echo "==> Notarizing + stapling DMG"
notary submit "$DMG" --wait 2>&1 | tee "${DIST_DIR}/notary-dmg.log"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ── Sparkle: sign the .zip, insert appcast item ─────────────────────
echo "==> Signing .zip with Sparkle EdDSA key"
[[ -x "${SPARKLE_BIN_DIR}/sign_update" ]] \
    || { echo "ERROR: sign_update not at ${SPARKLE_BIN_DIR} (SPM not resolved?)" >&2; exit 1; }
SIGN_LINE="$("${SPARKLE_BIN_DIR}/sign_update" --ed-key-file "$SPARKLE_KEY_PATH" "$ZIP")"
ED_SIG="$(echo "$SIGN_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
ASSET_LEN="$(echo "$SIGN_LINE" | sed -E 's/.*length="([^"]+)".*/\1/')"
if [[ -z "$ED_SIG" || -z "$ASSET_LEN" || "$ED_SIG" == "$SIGN_LINE" ]]; then
    echo "ERROR: failed to parse sign_update output: $SIGN_LINE" >&2; exit 1
fi
echo "    edSignature ${ED_SIG:0:24}…  length ${ASSET_LEN}"

DOWNLOAD_URL="https://github.com/${GH_REPO}/releases/download/${TAG}/${ZIP_ASSET}"
RELEASE_NOTES_LINK="https://github.com/${GH_REPO}/releases/tag/${TAG}"

# Notes source: release-notes/<tag>.md if present, else commit subjects since
# the previous tag (dropping release/appcast chores). Same file feeds the
# GitHub release body and the inline appcast <description>.
NOTES_REPO_FILE="release-notes/${TAG}.md"
NOTES_MD_FILE="$(mktemp)"
if [[ -f "$NOTES_REPO_FILE" ]]; then
    cat "$NOTES_REPO_FILE" > "$NOTES_MD_FILE"
else
    PREV_TAG="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || true)"
    if [[ -n "$PREV_TAG" ]]; then
        git log "${PREV_TAG}..${TAG}" --no-merges --pretty='- %s' \
            | grep -vE '^- (release|appcast):' > "$NOTES_MD_FILE" || true
    else
        git log "${TAG}" --no-merges --pretty='- %s' > "$NOTES_MD_FILE" || true
    fi
fi
[[ -s "$NOTES_MD_FILE" ]] || printf -- '- %s\n' "$TITLE" > "$NOTES_MD_FILE"

echo "==> Updating ${APPCAST}"
python3 scripts/ci/insert_appcast_item.py \
    "$APPCAST" "$TAG" "$VERSION" "$BUILD_NUMBER" "$ED_SIG" "$ASSET_LEN" \
    "$DOWNLOAD_URL" "$RELEASE_NOTES_LINK" "$PRERELEASE" "$NOTES_MD_FILE"

# Sanity: the just-written top signature must match what we generated.
APPCAST_SIG="$(grep -m1 "sparkle:edSignature=" "$APPCAST" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
[[ "$APPCAST_SIG" == "$ED_SIG" ]] \
    || { echo "ERROR: appcast top sig != generated sig; refuse to publish." >&2; exit 1; }

# ── GitHub release ──────────────────────────────────────────────────
echo "==> Creating GitHub release ${TAG}"
if [[ -f "$NOTES_REPO_FILE" ]]; then
    gh release create "$TAG" $PRERELEASE_FLAG --title "$TITLE" \
        --notes-file "$NOTES_REPO_FILE" "$ZIP" "$DMG"
else
    gh release create "$TAG" $PRERELEASE_FLAG --title "$TITLE" \
        --generate-notes "$ZIP" "$DMG"
fi

# ── Publish the updated appcast to main ─────────────────────────────
# The tag was created on main's HEAD, so this appcast commit fast-forwards
# main by one. (If main advanced since the tag, this push is rejected — re-run
# after rebasing appcast.xml, or push it manually.)
echo "==> Committing updated ${APPCAST} to main"
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$APPCAST"
git commit -m "appcast: ${TAG}"
git push origin "HEAD:main"

echo
echo "================================================================"
echo "Release ${TAG} published"
echo "  .zip : ${ZIP}"
echo "  .dmg : ${DMG}"
echo "  URL  : https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "================================================================"

rm -f "$NOTES_MD_FILE"
