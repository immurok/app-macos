# Release packaging (signed + notarized .pkg)

Pushing a tag to **github.com/immurok/app-macos** runs
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which builds
a universal app, signs everything with Developer ID, wraps it in a `.pkg`,
notarizes it, and attaches it to a GitHub Release.

```
git tag v1.2.3
git push origin v1.2.3
```

The resulting `immurok-1.2.3.pkg` installs:

| Path | What |
|------|------|
| `/Applications/immurok.app` | Menu bar app |
| `/usr/local/bin/imk` | CLI |
| `/usr/local/lib/pam/pam_immurok.so` | PAM module |

and the `postinstall` wires `pam_immurok` into `/etc/pam.d/sudo_local` and
`/etc/pam.d/authorization`. A signed uninstall pkg is embedded in the app for
the in-app "uninstall" action.

**macOS 13 Ventura**: `sudo_local` only exists on macOS 14+ (Ventura's
`/etc/pam.d/sudo` has no `include sudo_local`), so on 13.x the `postinstall`
additionally writes the line into `/etc/pam.d/sudo` itself. That file is reset
by every macOS update; the app monitors it (`SetupManager.needsLegacySudoRepair`)
and offers the embedded `immurok_repair.pkg`, whose `repair-postinstall` handles
the same version branch. `sudo_local` is still written on 13.x so sudo auth
survives a later 13 → 14 upgrade without repair.

`workflow_dispatch` (Actions → Release → Run workflow) does the same build for a
manual version but **does not** publish a Release — use it as a dry run.

## One-time setup

### 1. Certificates — you need BOTH

| Identity | Signs | Where to get it |
|----------|-------|-----------------|
| **Developer ID Application** | app, `imk`, `pam_immurok.so` | Likely already in your Keychain (local builds use it). |
| **Developer ID Installer** | the `.pkg` itself | Apple Developer → Certificates → **+** → "Developer ID Installer", if you don't have one. |

Export each **with its private key** to a `.p12` (Keychain Access → right-click
the certificate → Export → `.p12`, set an export password), then base64-encode:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy   # → DEVID_APP_CERT_P12_BASE64
base64 -i DeveloperIDInstaller.p12  | pbcopy    # → DEVID_INSTALLER_CERT_P12_BASE64
```

### 2. App Store Connect API key (for notarization)

App Store Connect → **Users and Access → Integrations → Keys** → generate a key
(role *Developer* is enough). Note the **Key ID** and **Issuer ID**, download the
`AuthKey_XXXXXX.p8` (one-time download), then:

```bash
base64 -i AuthKey_XXXXXX.p8 | pbcopy             # → AC_API_KEY_P8_BASE64
```

### 3. GitHub repository secrets

Settings → Secrets and variables → Actions → **New repository secret**:

| Secret | Value |
|--------|-------|
| `DEVID_APP_CERT_P12_BASE64` | base64 of the Developer ID **Application** .p12 |
| `DEVID_APP_CERT_PASSWORD` | that .p12's export password |
| `DEVID_INSTALLER_CERT_P12_BASE64` | base64 of the Developer ID **Installer** .p12 |
| `DEVID_INSTALLER_CERT_PASSWORD` | that .p12's export password |
| `AC_API_KEY_ID` | App Store Connect Key ID |
| `AC_API_ISSUER_ID` | App Store Connect Issuer ID (UUID) |
| `AC_API_KEY_P8_BASE64` | base64 of the `AuthKey_*.p8` |
| `KEYCHAIN_PASSWORD` | any random string (temp keychain password) |

## Building locally

`build-pkg.sh` also runs on your Mac if both Developer ID identities are in your
keychain:

```bash
# Sign only (skips notarization — pkg works but Gatekeeper will still warn on
# a fresh machine without the stapled ticket):
VERSION=1.2.3 packaging/build-pkg.sh

# Sign + notarize + staple:
VERSION=1.2.3 \
AC_API_KEY_ID=XXXXXXXXXX \
AC_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
AC_API_KEY_PATH=/path/to/AuthKey_XXXXXX.p8 \
packaging/build-pkg.sh
```

Output: `app-macos/dist/immurok-<VERSION>.pkg`.

## Notes

- The runner uses its image's default Xcode/Swift toolchain. To pin a version,
  add a `maxim-lobanov/setup-xcode` step before the build.
- `packaging/postinstall` and `uninstall-postinstall` are the self-contained CI
  copies of the legacy `scripts/pam-pkg/*` scripts (which stay for the local
  `scripts/build-pam-pkg.sh` flow). Keep them in sync, or consolidate later.
