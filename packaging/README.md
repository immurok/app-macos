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
| `HOMEBREW_TAP_TOKEN` | *(optional)* PAT with **Contents: read & write** on `immurok/homebrew-tap`; lets the workflow bump the Homebrew cask after a release |

### 4. Homebrew tap (optional)

[`immurok/homebrew-tap`](https://github.com/immurok/homebrew-tap) serves
`brew install --cask immurok/tap/immurok`, which installs this same pkg.
After a `v*` tag publishes, the **Bump Homebrew cask** step clones the tap
with `HOMEBREW_TAP_TOKEN`, runs its `scripts/bump.sh <version> <sha256>` and
pushes. Pre-release tags are skipped. Without the secret the step only prints
a warning; bump by hand:

```bash
cd homebrew-tap && scripts/bump.sh 1.7.0 && git commit -am "immurok 1.7.0" && git push
```

Create the token at GitHub → Settings → Developer settings → Fine-grained
tokens: resource owner `immurok`, repository `homebrew-tap` only, permission
*Contents: Read and write*. Set it with
`gh secret set HOMEBREW_TAP_TOKEN --repo immurok/app-macos`.

#### Known issue: `brew upgrade` resets user configuration (not fixed yet)

Found 2026-11-24 by reading the Homebrew source (7.0.16), the cask and
`uninstall-postinstall`; not reproduced by running an actual upgrade.

`brew upgrade --cask immurok` is a full uninstall followed by a fresh install.
On upgrade Homebrew runs the installed cask's whole `uninstall` stanza (only
`signal` is skipped) and gives the script no hint that it is an upgrade, so
`immurok_uninstall.pkg` runs every time.

| | Result of a `brew upgrade` |
|---|---|
| `~/.immurok` (`automation.json`, `ssh_keys.json`, `key_name_cache.json`) | removed: custom Automation items and per-item switches are lost |
| `com.immurok.app` preferences | removed: every feature switch and sound setting is lost, first-run setup shows again |
| immurok lines in `/etc/pam.d` | removed by the uninstall pkg, written again by the new pkg's postinstall |
| `/etc/immurok/pam` (PAM channel key) | removed and **not** recreated by the pkg: PAM authentication has to be enabled again in the app (`imk pam-key install`) |
| Keychain (login password, per-item passwords, pairing key, verified device) | kept: only the in-app uninstall clears it (`SetupManager` → `clearAllKeychainData()`), the brew path never reaches that code |

Related cases:

- Installed from the pkg only, never through brew: `brew upgrade` reports the
  cask as not installed and does nothing. `brew install --cask` runs just the
  installer, so nothing is lost; later upgrades go through the path above.
- The uninstall script cannot simply be skipped on upgrade. The `pkgutil:`
  directive deletes `pam_immurok.so` by receipt, and with the `/etc/pam.d`
  lines still in place PAM fails to initialise: sudo and the system
  authorization dialog stop working if the new pkg then fails to install.

Planned fix (not implemented):

1. The cask script drops a "keep user data" marker file before it runs the
   uninstall pkg.
2. `uninstall-postinstall` skips removing `~/.immurok` and the preferences
   when the marker is present; everything else stays as it is.
3. Removing user data is left to the cask's `zap` stanza, which already lists
   both. The in-app uninstall and a hand-run uninstall pkg leave no marker and
   keep their current behaviour.

Limit of that fix: on upgrade Homebrew uses the **installed** cask and the
**installed** uninstall pkg, not the new ones. The fix therefore takes effect
one upgrade late; the upgrade from 1.6.11 or earlier still resets the
configuration once.

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
