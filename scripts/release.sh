#!/usr/bin/env bash
#
# scripts/release.sh
#
# Build, sign, notarize, staple and package Noticky for distribution.
# Outputs to dist/v<VERSION>/{Noticky.app, Noticky-<VERSION>.zip, Noticky-<VERSION>.dmg}
#
# === ONE-TIME SETUP (per machine) ===
#
# 1. Confirm Developer ID Application cert in keychain:
#      security find-identity -v -p codesigning | grep "Developer ID Application"
#    Should list one for team T8F5T6HKG8 (Shenzhen Zhiqishidai Technology).
#    If missing: Xcode → Settings → Accounts → your Apple ID →
#    Manage Certificates → +  → Developer ID Application.
#
# 2. Generate an app-specific password at https://appleid.apple.com
#    → Sign-In and Security → App-Specific Passwords → Generate.
#    Label it e.g. "Noticky notarytool".
#
# 3. Store notary credentials in keychain (one-time, no plaintext password
#    survives in shell history or scripts):
#      xcrun notarytool store-credentials "noticky-notary" \
#        --apple-id "<your-apple-id>@example.com" \
#        --team-id  "T8F5T6HKG8" \
#        --password "<app-specific-password>"
#
# === PER-RELEASE ===
#
#   ./scripts/release.sh
#
# Network: notarization needs Apple's servers; allow ~5-15 min total.
# Re-runs are safe; output dir is wiped at start.

set -euo pipefail

# Resolve repo root from script location, regardless of cwd.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Pull version from project.yml (CFBundleShortVersionString lives there).
# Robustness note: if the YAML key moves, this regex breaks loudly — better
# than silently shipping the wrong version string.
VERSION=$(awk -F'"' '/CFBundleShortVersionString:/ {print $2; exit}' project.yml)
if [ -z "${VERSION}" ]; then
  echo "ERROR: cannot extract CFBundleShortVersionString from project.yml" >&2
  exit 1
fi

NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"
DIST_DIR="dist/v${VERSION}"
APP="${DIST_DIR}/Noticky.app"
ZIP="${DIST_DIR}/Noticky-${VERSION}.zip"
DMG="${DIST_DIR}/Noticky-${VERSION}.dmg"

# Build dir kept separate from the Debug DerivedData so we don't churn
# Xcode's incremental build state.
BUILD_DIR=".build/release"
ARCHIVE="${BUILD_DIR}/Noticky.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="$(dirname "$0")/ExportOptions.plist"

# ---------- Preflight ----------

echo "==> Preflight: notary credentials"
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  cat >&2 <<EOF
ERROR: notarytool keychain profile "${NOTARY_PROFILE}" not found.

Set up once with:
  xcrun notarytool store-credentials "${NOTARY_PROFILE}" \\
    --apple-id "<your-apple-id>" \\
    --team-id  "T8F5T6HKG8" \\
    --password "<app-specific-password>"

(Generate the app-specific password at https://appleid.apple.com →
Sign-In and Security → App-Specific Passwords.)
EOF
  exit 1
fi

echo "==> Preflight: Developer ID cert"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application:.*T8F5T6HKG8"; then
  echo "ERROR: 'Developer ID Application' cert for team T8F5T6HKG8 not found in keychain." >&2
  echo "       See header of this script for setup steps." >&2
  exit 1
fi

echo "==> Preflight: Developer ID provisioning profile"
# Manual signing 要求本机已经安装名叫 "Noticky Developer ID" 的 Developer ID
# provisioning profile(去 portal 手动建,流程见 CLAUDE.md "First release")。
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROFILE_FOUND=0
for f in "$PROFILE_DIR"/*.provisionprofile; do
  [ -f "$f" ] || continue
  name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)
  if [ "$name" = "Noticky Developer ID" ]; then
    PROFILE_FOUND=1
    break
  fi
done
if [ "$PROFILE_FOUND" -eq 0 ]; then
  cat >&2 <<EOF
ERROR: Developer ID provisioning profile "Noticky Developer ID" not installed.

iCloud + Push Notifications entitlements 要求 Developer ID profile,即使用
本地 cert 直接签也绕不过去。一次性创建步骤(Account Holder/Admin 才有权限,
member 角色让 admin 帮你建一次,然后给你 .provisionprofile 文件双击安装):

  1. 打开 https://developer.apple.com/account/resources/profiles/add
  2. Distribution → "Developer ID" → Continue
  3. App ID = tech.xvanturing.Noticky → Continue
  4. Certificates: 选 "Developer ID Application" 那张(team T8F5T6HKG8) → Continue
  5. Provisioning Profile Name = "Noticky Developer ID"(必须**完全一致**,
     ExportOptions.plist 按这个名字 lookup) → Generate
  6. Download → 双击 .provisionprofile 文件让 Xcode 装进
     ~/Library/Developer/Xcode/UserData/Provisioning Profiles/

完成后重跑这个 script。
EOF
  exit 1
fi

# ---------- Clean ----------

echo "==> Cleaning previous build"
rm -rf "${DIST_DIR}" "${BUILD_DIR}"
mkdir -p "${DIST_DIR}"

# ---------- Build ----------

echo "==> Regenerating Xcode project"
xcodegen >/dev/null

echo "==> Archiving Release config (this can take a minute)"
# Apple-canonical Direct Distribution flow: archive → exportArchive。
# archive 阶段用 Apple Development 自动签名(最低门槛能编译)。
# -allowProvisioningUpdates: Xcode 自动 fetch/创建 provisioning profile,
#   首次跑可能要交互登录一次。
xcodebuild -project Noticky.xcodeproj \
  -scheme Noticky \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  -archivePath "${ARCHIVE}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -quiet \
  archive

if [ ! -d "${ARCHIVE}" ]; then
  echo "ERROR: archive not produced at ${ARCHIVE}" >&2
  exit 1
fi

echo "==> Exporting + re-signing as Developer ID (uses ExportOptions.plist)"
# 这一步:
#   1. 从 archive 取出 .app
#   2. 按 ExportOptions.plist 的 method=developer-id 用 Developer ID Application
#      cert 重签整个 .app(含 framework 内嵌签名)
#   3. fetch/挂 Developer ID provisioning profile 满足 iCloud + APNs entitlements
rm -rf "${EXPORT_DIR}"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

BUILT_APP="${EXPORT_DIR}/Noticky.app"
if [ ! -d "${BUILT_APP}" ]; then
  echo "ERROR: exported Noticky.app not found at ${BUILT_APP}" >&2
  exit 1
fi

echo "==> Copying built app to dist/"
ditto "${BUILT_APP}" "${APP}"

# ---------- Sign verification ----------

echo "==> Verifying codesign"
# --deep checks framework signatures, --strict catches resource hash mismatches.
codesign --verify --deep --strict --verbose=2 "${APP}"

# spctl exit code may be non-zero before notarization — that's expected.
# We just want to see the current Gatekeeper verdict for the operator.
echo "==> Pre-notarization Gatekeeper assessment (expected to fail until notarized):"
spctl --assess --verbose=4 --type execute "${APP}" 2>&1 || true

# ---------- Zip + notarize app ----------

echo "==> Zipping for notarization"
# `ditto -c -k --keepParent` is Apple's required form for notarytool zip submission;
# regular `zip` mangles symlinks/extended attrs and breaks signatures.
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "==> Submitting .zip to Apple notarization (--wait blocks until verdict)"
NOTARY_LOG="${DIST_DIR}/notary-app.log"
if ! xcrun notarytool submit "${ZIP}" \
       --keychain-profile "${NOTARY_PROFILE}" \
       --wait 2>&1 | tee "${NOTARY_LOG}"; then
  echo "ERROR: notarization failed. See ${NOTARY_LOG}" >&2
  echo "       Pull detailed log with:" >&2
  echo "         xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}" >&2
  exit 1
fi

echo "==> Stapling notarization ticket onto .app"
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

# Re-zip the stapled app — the original zip pre-dates the ticket.
echo "==> Re-zipping stapled app"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

# ---------- DMG ----------

echo "==> Creating DMG"
DMG_STAGE="${DIST_DIR}/.dmg-stage"
rm -rf "${DMG_STAGE}"
mkdir -p "${DMG_STAGE}"
ditto "${APP}" "${DMG_STAGE}/Noticky.app"
# Drag-to-Applications convention: symlink visible in the mounted volume.
ln -s /Applications "${DMG_STAGE}/Applications"

# UDZO = compressed read-only DMG, smaller + handles re-mounts cleanly.
hdiutil create \
  -volname "Noticky ${VERSION}" \
  -srcfolder "${DMG_STAGE}" \
  -ov -format UDZO \
  "${DMG}" >/dev/null
rm -rf "${DMG_STAGE}"

# DMGs are also Gatekeeper-checked — separately notarize + staple so users
# don't see "Apple cannot check it for malicious software" on first mount.
echo "==> Submitting .dmg to Apple notarization"
NOTARY_LOG_DMG="${DIST_DIR}/notary-dmg.log"
if ! xcrun notarytool submit "${DMG}" \
       --keychain-profile "${NOTARY_PROFILE}" \
       --wait 2>&1 | tee "${NOTARY_LOG_DMG}"; then
  echo "ERROR: DMG notarization failed. See ${NOTARY_LOG_DMG}" >&2
  exit 1
fi

echo "==> Stapling DMG"
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"

# ---------- Summary ----------

echo ""
echo "================================================================"
echo "Release v${VERSION} ready:"
echo "  .app : ${APP}"
echo "  .zip : ${ZIP} ($(du -h "${ZIP}" | cut -f1))"
echo "  .dmg : ${DMG} ($(du -h "${DMG}" | cut -f1))"
echo "================================================================"
echo ""
echo "Smoke test before publishing:"
echo "  1. Mount: open ${DMG}"
echo "  2. Drag Noticky.app to /Applications"
echo "  3. Right-click → Open the first time (clears quarantine prompt)"
echo "  4. Verify menubar item, ⌘⇧N capture, Settings → iCloud Sync"
echo ""
echo "Publish:"
echo "  - Upload ${DMG} to your distribution channel (GitHub Releases, website)"
echo "  - Tag this commit: git tag v${VERSION} && git push --tags"
