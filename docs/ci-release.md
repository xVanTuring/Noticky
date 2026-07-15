# Cloud release (GitHub Actions)

Push a tag → GitHub builds, signs (Developer ID), notarizes (App Store Connect
API key), staples, makes a DMG, Sparkle-signs the `.zip`, creates the GitHub
release, and pushes the updated `appcast.xml` to `main`. Same chain as
`scripts/release.sh`, just on a `macos-15` runner.

- Workflow: [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- Packaging script: [`scripts/ci/package_and_publish.sh`](../scripts/ci/package_and_publish.sh)
- Appcast writer: [`scripts/ci/insert_appcast_item.py`](../scripts/ci/insert_appcast_item.py)

## Per-release flow

1. **Bump version** in `project.yml` (`CFBundleShortVersionString` +
   `CFBundleVersion`), run `xcodegen`, commit `release: bump to X.Y.Z (build N)`.
2. **Write notes** to `release-notes/vX.Y.Z.md` (bilingual via `<!-- lang:en -->`
   / `<!-- lang:zh -->` markers — see `scripts/release.sh` header). Commit.
3. **Tag + push**:
   ```sh
   git tag -a vX.Y.Z -m vX.Y.Z
   git push origin main
   git push origin vX.Y.Z          # ← this triggers the workflow
   ```
   Prerelease? Tag `vX.Y.Z-beta`; the item gets `<sparkle:channel>beta</…>` and
   the GitHub release is marked pre-release.

The tag must sit on `main`'s HEAD so the workflow's `appcast: vX.Y.Z` commit
fast-forwards `main`. (Claude does steps 1–3 for you; GitHub does the rest.)

If `release-notes/vX.Y.Z.md` is absent, the workflow falls back to commit
subjects since the previous tag.

## One-time setup — 8 repository secrets

Add these once with `gh` (run from the repo root, or add `-R xVanTuring/Perch`).
`gh secret set NAME` reads the value from stdin when piped, or use `--body`.

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_APP_CERT_P12` | Developer ID Application cert + key, base64 |
| `DEVELOPER_ID_APP_CERT_PASSWORD` | password you set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any random string (temp keychain on the runner) |
| `PROVISIONING_PROFILE` | "Perch Profile" `.provisionprofile`, base64 |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA **private** key (exported, never regenerated) |
| `APPLE_ID` | Apple account email used for notarization |
| `APPLE_APP_PASSWORD` | app-specific password (appleid.apple.com) |
| `APPLE_TEAM_ID` | `T8F5T6HKG8` |

### 1–2. Developer ID Application certificate

Keychain Access → **login** keychain → **My Certificates** → the row
`Developer ID Application: … (T8F5T6HKG8)` (expand it — it must include the
private key) → right-click → **Export** → save `DeveloperID.p12`, set a password.

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_APP_CERT_P12
gh secret set DEVELOPER_ID_APP_CERT_PASSWORD --body '<the .p12 password>'
rm DeveloperID.p12
```

### 3. Keychain password (throwaway)

```sh
gh secret set KEYCHAIN_PASSWORD --body "$(openssl rand -base64 24)"
```

### 4. Developer ID provisioning profile

Find the file named **Perch Profile** among your installed profiles:

```sh
for f in ~/Library/MobileDevice/Provisioning\ Profiles/*.provisionprofile \
         ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
    [ -f "$f" ] || continue
    printf '%s\n    => %s\n' "$f" \
        "$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - -)"
done
```

Then base64 the one whose name is `Perch Profile`:

```sh
base64 -i "<path>/Perch Profile.provisionprofile" | gh secret set PROVISIONING_PROFILE
```

(No local profile yet? Create one at
<https://developer.apple.com/account/resources/profiles/add> → Software →
Developer ID → App ID `tech.xvanturing.Perch` → cert `T8F5T6HKG8` → name it
`Perch Profile` → download.)

### 5. Sparkle EdDSA private key

⚠️ **Export the existing key — never regenerate.** A new key breaks auto-update
for everyone already installed (the public half is baked into shipped builds).

```sh
# Make sure Sparkle's tools exist (resolve once if you haven't built recently):
xcodebuild -project Perch.xcodeproj -scheme Perch \
    -derivedDataPath .build/release -resolvePackageDependencies

# Export the private key from your login keychain:
.build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_ed_private_key

gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_ed_private_key
rm -f sparkle_ed_private_key           # don't leave the private key on disk
```

### 6–8. Apple ID notarization credentials

Notarization uses your Apple ID + an **app-specific password** (the same trio
`scripts/release.sh` uses for its local `noticky-notary` notarytool profile — no
Admin role or API-key permission needed).

Create an app-specific password at <https://appleid.apple.com> → Sign-In and
Security → App-Specific Passwords → generate one (label it e.g. "Perch CI").

```sh
gh secret set APPLE_ID           --body 'you@example.com'
gh secret set APPLE_APP_PASSWORD --body 'xxxx-xxxx-xxxx-xxxx'   # the app-specific password
gh secret set APPLE_TEAM_ID      --body 'T8F5T6HKG8'
```

### Verify

```sh
gh secret list      # should show all 8
```

## Notes / gotchas

- **Branch protection on `main`.** The final step pushes an `appcast: vX.Y.Z`
  commit to `main` via the built-in `GITHUB_TOKEN`. If `main` is protected
  against Actions pushes, either allow the `github-actions[bot]`, or drop the
  push step and commit the appcast yourself.
- **Runner Xcode / SDK.** `macos-15` ships an Xcode with the macOS 15 SDK
  (Perch's deployment target). Pin a specific Xcode with
  `sudo xcode-select -s /Applications/Xcode_16.x.app` if a runner default drifts.
- **First run.** CI code-signing usually needs one round of tweaking. On failure
  the notary logs upload as the `release-logs` artifact; the step logs show
  `codesign` / `notarytool` errors. The signing/notarization/Sparkle logic all
  lives in `scripts/ci/package_and_publish.sh` — edit it, push a new tag (or
  delete + re-push the same one) to retry.
- **Keep `scripts/release.sh`.** The local script still works end-to-end as a
  fallback if Actions is down. The appcast-item format is duplicated between it
  and `scripts/ci/insert_appcast_item.py` — keep them in sync.
