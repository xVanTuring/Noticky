#!/usr/bin/env bash
# scripts/release.sh
#
# Bump version → build → Developer-ID-sign → notarize → staple → DMG →
# Sparkle-sign → publish GitHub release → push updated appcast.
#
# Usage:
#   ./scripts/release.sh <version> [--prerelease <suffix>] [--notes-file <path>] [--dry-run]
#
# Examples:
#   ./scripts/release.sh 1.2.0
#   ./scripts/release.sh 1.2.0 --prerelease beta
#   ./scripts/release.sh 1.2.0 --notes-file CHANGELOG-1.2.0.md
#   ./scripts/release.sh 1.2.0 --dry-run
#
# Bilingual notes: a --notes-file may carry several language sections delimited
# by "<!-- lang:xx -->" lines, e.g.
#     <!-- lang:en -->
#     ## What's New
#     ...
#     <!-- lang:zh -->
#     ## 更新内容
#     ...
# Each section becomes a localized <description xml:lang="xx"> in the appcast
# (Sparkle shows the user's language). On GitHub the markers are invisible HTML
# comments, so the same file doubles as the stacked release body. No markers =
# one unlocalized description (back-compat).
#
# See docs/release.md for one-time machine setup.

set -euo pipefail

# Resolve repo root from the script's own location — script can be run from
# anywhere (e.g. an IDE task runner) without breaking relative paths.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Project constants ───────────────────────────────────────────────
TEAM_ID="T8F5T6HKG8"
NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"
PROVISIONING_PROFILE_NAME="Perch Developer ID"
SCHEME="Perch"
PROJECT="Perch.xcodeproj"
PRODUCT="Perch"
# Repo + appcast feed stay on xVanTuring/Noticky so existing installs keep
# polling the same SUFeedURL — see Info.plist. (Bundle id changed to
# tech.xvanturing.Perch, but the update feed location is independent.)
GH_REPO="xVanTuring/Noticky"
APPCAST="appcast.xml"
INFO_PLIST="Sources/Perch/Resources/Info.plist"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
BUILD_DIR=".build/release"
# Sparkle 2 SPM artifact bundle — populated after
# `xcodebuild -resolvePackageDependencies` runs against the project.
SPARKLE_BIN_DIR="${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin"

# ── Args ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF >&2
Usage: $(basename "$0") <version> [--prerelease <suffix>] [--notes-file <path>] [--dry-run]

  <version>          CFBundleShortVersionString, e.g. 1.2.0
  --prerelease X     Mark as pre-release; tag becomes v<version>-<X>,
                     appcast item gets <sparkle:channel>X</sparkle:channel>.
  --notes-file PATH  File whose contents become the GitHub release body AND the
                     inline appcast notes (default: gh --generate-notes from
                     commit messages). May be bilingual via "<!-- lang:xx -->"
                     section markers (see header comment).
  --dry-run          Bump version + verify Debug build + commit locally,
                     but skip push / archive / release.
EOF
    exit 1
}

VERSION=""
PRERELEASE=""
NOTES_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prerelease)  PRERELEASE="${2:?--prerelease needs a value}"; shift 2 ;;
        --notes-file)  NOTES_FILE="${2:?--notes-file needs a path}"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown flag: $1" >&2; usage ;;
        *)
            if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
            else echo "Unexpected positional: $1" >&2; usage; fi
            ;;
    esac
done

[[ -z "$VERSION" ]] && usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || { echo "ERROR: version must be X.Y.Z (got '$VERSION')" >&2; exit 1; }

if [[ -n "$PRERELEASE" ]]; then
    TAG="v${VERSION}-${PRERELEASE}"
    TITLE="v${VERSION} ${PRERELEASE}"
    DIST_DIR="dist/${TAG}"
    ZIP_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}-${PRERELEASE}.dmg"
    PRERELEASE_FLAG="--prerelease"
else
    TAG="v${VERSION}"
    TITLE="v${VERSION}"
    DIST_DIR="dist/${TAG}"
    ZIP_ASSET="${PRODUCT}-${VERSION}.zip"
    DMG_ASSET="${PRODUCT}-${VERSION}.dmg"
    PRERELEASE_FLAG=""
fi
ZIP="${DIST_DIR}/${ZIP_ASSET}"
DMG="${DIST_DIR}/${DMG_ASSET}"
APP="${DIST_DIR}/${PRODUCT}.app"
ARCHIVE="${BUILD_DIR}/${PRODUCT}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"

echo "==> Version $VERSION  •  Tag $TAG  •  Asset $ZIP_ASSET + $DMG_ASSET"

# ── Pre-flight ──────────────────────────────────────────────────────
echo "==> Pre-flight checks"

[[ -f project.yml ]]      || { echo "ERROR: run from repo root (no project.yml here)" >&2; exit 1; }
[[ -f "$APPCAST" ]]       || { echo "ERROR: $APPCAST missing — Sparkle needs it. Restore from git." >&2; exit 1; }
grep -q "BEGIN-ITEMS"  "$APPCAST" || { echo "ERROR: $APPCAST has no BEGIN-ITEMS marker; refuse to mangle it." >&2; exit 1; }

command -v xcodegen >/dev/null \
    || { echo "ERROR: xcodegen not on PATH (brew install xcodegen)" >&2; exit 1; }
command -v gh >/dev/null \
    || { echo "ERROR: gh CLI not on PATH (brew install gh)" >&2; exit 1; }

gh auth status >/dev/null 2>&1 \
    || { echo "ERROR: gh not authenticated. Run 'gh auth login'." >&2; exit 1; }

security find-identity -v -p codesigning \
    | grep -q "Developer ID Application.*${TEAM_ID}" \
    || { echo "ERROR: no 'Developer ID Application' cert for team ${TEAM_ID} in keychain." >&2
         echo "       Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
         exit 1; }

# Manual signing requires the named profile to be installed locally;
# ExportOptions.plist looks it up by name.
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROFILE_FOUND=0
if [[ -d "$PROFILE_DIR" ]]; then
    for f in "$PROFILE_DIR"/*.provisionprofile "$PROFILE_DIR"/*.mobileprovision; do
        [[ -f "$f" ]] || continue
        name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || true)
        [[ "$name" == "$PROVISIONING_PROFILE_NAME" ]] && PROFILE_FOUND=1 && break
    done
fi
if [[ "$PROFILE_FOUND" -eq 0 ]]; then
    echo "ERROR: Developer ID provisioning profile '$PROVISIONING_PROFILE_NAME' not installed." >&2
    echo "       Create it at https://developer.apple.com/account/resources/profiles/add" >&2
    echo "       (Distribution → Developer ID → App ID tech.xvanturing.Perch)" >&2
    exit 1
fi

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "ERROR: notarytool profile '${NOTARY_PROFILE}' is missing or invalid." >&2
         echo "       Set up once with: xcrun notarytool store-credentials ${NOTARY_PROFILE} ..." >&2
         exit 1; }

# `SUPublicEDKey` in Info.plist must be non-empty. An empty key means
# Sparkle silently accepts any signature → the auto-update channel is
# unauthenticated. Refuse to release in that state.
ED_PUBKEY=$(plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST" 2>/dev/null || echo "")
if [[ -z "$ED_PUBKEY" ]]; then
    cat >&2 <<EOF
ERROR: SUPublicEDKey in $INFO_PLIST is empty.

Generate the Sparkle EdDSA key once on this machine:
  1. Run a Debug build (resolves the Sparkle SPM artifact):
       xcodegen
       xcodebuild -project ${PROJECT} -scheme ${SCHEME} -configuration Debug build
  2. Generate the key (prints the public half, stashes private in your keychain):
       ${SPARKLE_BIN_DIR}/generate_keys
  3. Paste the printed public key into project.yml under SUPublicEDKey, then:
       xcodegen
  4. Commit and re-run release.sh.

See docs/release.md for backup and recovery details.
EOF
    exit 1
fi

[[ -z "$(git status --porcelain)" ]] \
    || { echo "ERROR: working tree dirty. Commit or stash first." >&2
         git status --short >&2; exit 1; }

if git rev-parse --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    echo "ERROR: tag ${TAG} already exists locally." >&2; exit 1
fi
if git ls-remote --tags origin "${TAG}" | grep -q "refs/tags/${TAG}$"; then
    echo "ERROR: tag ${TAG} already exists on origin." >&2; exit 1
fi

if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || { echo "ERROR: --notes-file not found: $NOTES_FILE" >&2; exit 1; }
fi

# Make sure .xcodeproj exists (gitignored, so a fresh clone won't have it).
# At this point project.yml is unchanged, so Info.plist will round-trip
# without producing a diff.
if [[ ! -d "$PROJECT" ]]; then
    echo "==> Generating xcodeproj (first run)"
    xcodegen >/dev/null
fi

# Resolve SPM so the Sparkle artifact + sign_update / generate_keys exist
# before we test the private key. This is cheaper than a full Debug build
# and lets the preflight catch a missing key BEFORE we bump anything.
echo "==> Resolving SPM packages (so Sparkle tools are available)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -derivedDataPath "$BUILD_DIR" \
    -resolvePackageDependencies \
    >/dev/null

if [[ ! -x "${SPARKLE_BIN_DIR}/sign_update" ]]; then
    echo "ERROR: Sparkle sign_update not at ${SPARKLE_BIN_DIR}/sign_update." >&2
    echo "       SPM resolve probably failed — try a manual 'xcodebuild ... build' first." >&2
    exit 1
fi
"${SPARKLE_BIN_DIR}/generate_keys" -p >/dev/null 2>&1 \
    || { echo "ERROR: Sparkle EdDSA private key not found in login keychain." >&2
         echo "       The public key in project.yml is set, but the corresponding private key is missing." >&2
         echo "       Either restore the backup (generate_keys -f <key.pem>) or — if this is" >&2
         echo "       the very first release — regenerate via 'generate_keys' and update project.yml." >&2
         exit 1; }

# ── Bump version in project.yml ─────────────────────────────────────
current_short=$(grep -E 'CFBundleShortVersionString:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
current_build=$(grep -E 'CFBundleVersion:' project.yml | head -1 | sed -E 's/.*"([0-9]+)".*/\1/')
next_build=$((current_build + 1))

echo "==> Version bump  ${current_short} (build ${current_build}) → ${VERSION} (build ${next_build})"

# BSD sed (macOS) requires a backup-suffix with -i; we use ".bak" and rm it.
sed -i.bak -E "s/(CFBundleShortVersionString: )\"[^\"]+\"/\\1\"${VERSION}\"/" project.yml
sed -i.bak -E "s/(CFBundleVersion: )\"[^\"]+\"/\\1\"${next_build}\"/" project.yml
rm -f project.yml.bak

xcodegen >/dev/null

echo "==> Verifying Debug build before commit"
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        build \
        2>&1 | grep -E "(error:|BUILD )" | tail -20; then
    echo "ERROR: Debug build failed. Reverting version bump." >&2
    git checkout -- project.yml "$INFO_PLIST"
    xcodegen >/dev/null
    exit 1
fi

echo "==> Committing version bump"
git add project.yml "$INFO_PLIST"
git commit -m "release: bump to ${VERSION} (build ${next_build})"

# Belt-and-suspenders: if a pre-commit hook touched anything else, halt
# before we push the wrong tree.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree dirty after version-bump commit. Resolve before push." >&2
    git status --short >&2
    exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "==> [dry-run] stopping before push/build/release."
    echo "    To undo:  git reset --hard HEAD~1"
    exit 0
fi

# ── Push main ───────────────────────────────────────────────────────
echo "==> Pushing main"
git push origin main

# ── Clean output dirs ───────────────────────────────────────────────
echo "==> Cleaning ${DIST_DIR} and ${BUILD_DIR}/Build"
rm -rf "${DIST_DIR}" "${ARCHIVE}" "${EXPORT_DIR}"
mkdir -p "${DIST_DIR}"

# ── Archive (Apple Development auto-signing) ────────────────────────
echo "==> Archiving Release config (this can take a minute)"
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    -quiet \
    archive

[[ -d "$ARCHIVE" ]] || { echo "ERROR: archive not produced at $ARCHIVE" >&2; exit 1; }

# ── Export with Developer ID re-sign ────────────────────────────────
echo "==> Exporting + re-signing as Developer ID (uses ${EXPORT_OPTIONS})"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    | tail -20

BUILT_APP="${EXPORT_DIR}/${PRODUCT}.app"
[[ -d "$BUILT_APP" ]] || { echo "ERROR: exported .app missing at $BUILT_APP" >&2; exit 1; }

echo "==> Copying built app to ${DIST_DIR}/"
ditto "$BUILT_APP" "$APP"

echo "==> Verifying codesign"
# --deep checks framework signatures (Sparkle.framework + KeyboardShortcuts);
# --strict catches resource hash mismatches.
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "TeamIdentifier|Authority|Format" || true

# Pre-notarization Gatekeeper assessment is informational; exit code may be
# non-zero until the ticket is stapled.
echo "==> Pre-notarization Gatekeeper assessment (expected to fail until notarized):"
spctl --assess --verbose=4 --type execute "$APP" 2>&1 || true

# ── Zip + notarize app ──────────────────────────────────────────────
echo "==> Zipping for notarization"
# `ditto -c -k --sequesterRsrc --keepParent` is the Apple-required form
# for notary submission AND for distribution downloads. Without
# --sequesterRsrc, BSD unzip (Finder Archive Utility) leaves AppleDouble
# `._File` siblings inside the bundle, breaking the code-signature seal
# → Gatekeeper "Apple could not verify…" for manual zip downloads.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting .zip to Apple notarization (--wait blocks until verdict)"
NOTARY_LOG_ZIP="${DIST_DIR}/notary-app.log"
if ! xcrun notarytool submit "$ZIP" \
       --keychain-profile "$NOTARY_PROFILE" \
       --wait 2>&1 | tee "$NOTARY_LOG_ZIP"; then
    echo "ERROR: notarization failed. See $NOTARY_LOG_ZIP" >&2
    echo "       Pull detailed log with:" >&2
    echo "         xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi

echo "==> Stapling notarization ticket onto .app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Gatekeeper assessment after stapling:"
spctl -a -t exec -vv "$APP" 2>&1 || true

# Re-zip — the pre-notary zip does NOT carry the staple ticket, and
# Sparkle needs the stapled bundle inside the asset users download.
echo "==> Re-zipping stapled app"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── DMG (parallel asset for manual download) ────────────────────────
echo "==> Creating DMG"
DMG_STAGE="${DIST_DIR}/.dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "${DMG_STAGE}/${PRODUCT}.app"
ln -s /Applications "${DMG_STAGE}/Applications"

hdiutil create \
    -volname "${PRODUCT} ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

echo "==> Submitting .dmg to Apple notarization"
NOTARY_LOG_DMG="${DIST_DIR}/notary-dmg.log"
if ! xcrun notarytool submit "$DMG" \
       --keychain-profile "$NOTARY_PROFILE" \
       --wait 2>&1 | tee "$NOTARY_LOG_DMG"; then
    echo "ERROR: DMG notarization failed. See $NOTARY_LOG_DMG" >&2
    exit 1
fi

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ── Sparkle: sign the .zip + update appcast.xml ─────────────────────
# sign_update reads the EdDSA private key from the login keychain. Its
# stdout format is `sparkle:edSignature="..." length="..."` (quote-delimited).
echo "==> Signing .zip with Sparkle EdDSA key"
SIGN_LINE="$("${SPARKLE_BIN_DIR}/sign_update" "$ZIP")"
ED_SIG="$(echo "$SIGN_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
ASSET_LEN="$(echo "$SIGN_LINE" | sed -E 's/.*length="([^"]+)".*/\1/')"
if [[ -z "$ED_SIG" || -z "$ASSET_LEN" || "$ED_SIG" == "$SIGN_LINE" ]]; then
    echo "ERROR: failed to parse sign_update output: $SIGN_LINE" >&2
    exit 1
fi
echo "    edSignature ${ED_SIG:0:24}…  length ${ASSET_LEN}"

DOWNLOAD_URL="https://github.com/${GH_REPO}/releases/download/${TAG}/${ZIP_ASSET}"
RELEASE_NOTES_LINK="https://github.com/${GH_REPO}/releases/tag/${TAG}"

# Gather release-notes markdown for the INLINE appcast <description>. Sparkle
# renders <description> HTML straight into its update window — clean notes, no
# embedded webpage. We deliberately do NOT use <sparkle:releaseNotesLink>:
# that makes Sparkle load the GitHub release *page* inside a tiny web view
# (full GitHub chrome, nav bar and all), which is what we're fixing here.
#
# Source = same as the GitHub release body: --notes-file if given, else commit
# subjects since the previous tag (the new tag isn't created yet at this point,
# so `git describe` returns the prior release). Drop the bump/appcast chores.
PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
NOTES_MD_FILE="$(mktemp)"
if [[ -n "$NOTES_FILE" ]]; then
    cat "$NOTES_FILE" > "$NOTES_MD_FILE"
elif [[ -n "$PREV_TAG" ]]; then
    git log "${PREV_TAG}..HEAD" --no-merges --pretty='- %s' \
        | grep -vE '^- (release|appcast):' > "$NOTES_MD_FILE" || true
else
    git log --no-merges --pretty='- %s' > "$NOTES_MD_FILE" || true
fi
[[ -s "$NOTES_MD_FILE" ]] || printf -- '- %s\n' "$TITLE" > "$NOTES_MD_FILE"

echo "==> Updating ${APPCAST}"
python3 - "$APPCAST" "$TAG" "$VERSION" "$next_build" "$ED_SIG" "$ASSET_LEN" "$DOWNLOAD_URL" "$RELEASE_NOTES_LINK" "$PRERELEASE" "$NOTES_MD_FILE" <<'PYEOF'
import sys, html, re
from datetime import datetime, timezone

appcast, tag, short_ver, build, ed_sig, length, dl_url, notes_link, prerelease, notes_md_file = sys.argv[1:]

pub_date = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
channel_line = f"      <sparkle:channel>{prerelease}</sparkle:channel>\n" if prerelease else ""

# ── Minimal Markdown → HTML for the release-notes pane ──────────────
# Just enough for our notes (commit-subject bullet lists, the occasional
# heading / **bold** / `code`). Source text is HTML-escaped first so a commit
# like "fix: handle <empty>" shows literally instead of vanishing as a tag.
def md_to_html(md):
    def inline(s):
        s = html.escape(s, quote=False)
        s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)   # bold first…
        s = re.sub(r'\*([^*\n]+?)\*', r'<em>\1</em>', s)          # …then *italic*
        s = re.sub(r'`(.+?)`', r'<code>\1</code>', s)
        s = re.sub(r'(https?://[^\s<]+)', r'<a href="\1">\1</a>', s)  # bare URLs → links
        return s
    out, in_list = [], False
    def close_list():
        nonlocal in_list
        if in_list:
            out.append('</ul>'); in_list = False
    for raw in md.splitlines():
        line = raw.rstrip()
        heading = re.match(r'^(#{1,6})\s+(.*)$', line)
        bullet = re.match(r'^[-*]\s+(.*)$', line)
        if bullet:
            if not in_list:
                out.append('<ul>'); in_list = True
            out.append(f'<li>{inline(bullet.group(1))}</li>')
        elif re.match(r'^([-*_])\1{2,}\s*$', line):   # --- *** ___ → rule
            close_list(); out.append('<hr>')
        elif heading:
            close_list()
            lvl = min(len(heading.group(1)) + 1, 6)  # bump so top-level "#" isn't huge
            out.append(f'<h{lvl}>{inline(heading.group(2))}</h{lvl}>')
        elif line:
            close_list(); out.append(f'<p>{inline(line)}</p>')
        else:
            close_list()
    close_list()
    return '\n'.join(out)

# ── Localized notes: split on "<!-- lang:xx -->" markers ────────────
# A bilingual notes file looks like:
#     <!-- lang:en -->
#     ## What's New
#     ...
#     <!-- lang:zh -->
#     ## 更新内容
#     ...
# Each section becomes its own <description xml:lang="xx"> and Sparkle shows
# the one matching the user's language. No markers → a single unlocalized
# <description> (back-compat, and what the commit-subject fallback produces).
# On GitHub the markers are invisible HTML comments, so the same file doubles
# as the (stacked) GitHub release body.
def split_langs(md):
    parts = re.split(r'(?im)^[ \t]*<!--[ \t]*lang:([a-z]{2})[ \t]*-->[ \t]*$', md)
    if len(parts) == 1:
        return [(None, md)]            # no markers
    it = iter(parts[1:])               # parts[0] = preamble before first marker
    return [(lang.lower(), chunk) for lang, chunk in zip(it, it) if chunk.strip()]

# "View full release on GitHub" footer, localized to the section's language.
FOOTER = {'en': 'View full release on GitHub →', 'zh': '在 GitHub 查看完整更新 →'}

def build_description(lang, chunk):
    notes_html = md_to_html(chunk)
    foot = FOOTER.get(lang or 'en', FOOTER['en'])
    notes_html += f'\n<p><a href="{html.escape(notes_link)}">{foot}</a></p>'
    notes_html = notes_html.replace(']]>', ']]&gt;')   # CDATA can't hold "]]>"
    lang_attr = f' xml:lang="{lang}"' if lang else ''
    return (f"      <description{lang_attr}><![CDATA[\n"
            f"{notes_html}\n"
            "      ]]></description>\n")

with open(notes_md_file, 'r', encoding='utf-8') as f:
    description = "".join(build_description(l, c) for l, c in split_langs(f.read()))

item = (
    "    <item>\n"
    f"      <title>{tag}</title>\n"
    f"      <pubDate>{pub_date}</pubDate>\n"
    f"      <sparkle:version>{build}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{short_ver}</sparkle:shortVersionString>\n"
    "      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n"
    f"{channel_line}"
    f"{description}"
    f"      <enclosure url=\"{dl_url}\" length=\"{length}\" "
    f"type=\"application/octet-stream\" sparkle:edSignature=\"{ed_sig}\" />\n"
    "    </item>\n"
)

with open(appcast, 'r', encoding='utf-8') as f:
    src = f.read()

marker = "<!-- BEGIN-ITEMS (release.sh inserts new entries here, newest first) -->\n"
if marker not in src:
    sys.exit(f"ERROR: marker line not found in {appcast}; refuse to mangle it.")

new_src = src.replace(marker, marker + item, 1)
with open(appcast, 'w', encoding='utf-8') as f:
    f.write(new_src)
PYEOF

rm -f "$NOTES_MD_FILE"

# Sanity: read the just-written signature back and compare. If anything
# raced or mangled the file we want to know before we push a bad feed.
APPCAST_SIG="$(grep -m1 "sparkle:edSignature=" "$APPCAST" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
[[ "$APPCAST_SIG" == "$ED_SIG" ]] \
    || { echo "ERROR: appcast.xml top sig does not match the signature we just generated." >&2; exit 1; }

# ── Tag + GitHub release ────────────────────────────────────────────
echo "==> Tagging ${TAG}"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

echo "==> Creating GitHub release"
if [[ -n "$NOTES_FILE" ]]; then
    gh release create "$TAG" $PRERELEASE_FLAG \
        --title "$TITLE" \
        --notes-file "$NOTES_FILE" \
        "$ZIP" "$DMG"
else
    # Auto-generate from commit messages since the previous tag.
    gh release create "$TAG" $PRERELEASE_FLAG \
        --title "$TITLE" \
        --generate-notes \
        "$ZIP" "$DMG"
fi

# ── Publish the updated appcast ─────────────────────────────────────
# Assets are now reachable at $DOWNLOAD_URL, so it's safe to push the
# new feed entry. Existing installs poll raw.githubusercontent.com and
# will see the new item on their next Sparkle check.
echo "==> Publishing ${APPCAST} update"
git add "$APPCAST"
git commit -m "appcast: ${TAG}"
git push origin main

echo
echo "================================================================"
echo "Release ${TAG} done"
echo "  .app : ${APP}"
echo "  .zip : ${ZIP} ($(du -h "$ZIP" | cut -f1))"
echo "  .dmg : ${DMG} ($(du -h "$DMG" | cut -f1))"
echo "  URL  : https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "================================================================"
echo
echo "Smoke test before announcing:"
echo "  1. open ${DMG}"
echo "  2. Drag ${PRODUCT}.app to /Applications"
echo "  3. Right-click → Open the first time (clears quarantine prompt)"
echo "  4. Verify menubar item, ⌘⇧N capture, Settings → Updates → Check Now"
