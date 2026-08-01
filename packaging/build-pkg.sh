#!/bin/bash
#
# build-pkg.sh — Build a signed + notarized immurok installer .pkg.
#
# Produces dist/immurok-<VERSION>.pkg containing:
#   /Applications/immurok.app          (menu bar app, Developer ID signed)
#   /usr/local/bin/imk                 (CLI, Developer ID signed)
#   /usr/local/lib/pam/pam_immurok.so  (PAM module, Developer ID signed)
# plus a postinstall that wires pam_immurok into sudo_local + authorization.
#
# Designed to run unattended in CI (see .github/workflows/release.yml) but also
# works locally as long as the two Developer ID identities are in the keychain.
#
# Required env:
#   VERSION                  Release version, e.g. 1.2.3 (no leading "v").
# Optional env (notarization — skipped with a warning if AC_API_KEY_ID unset):
#   AC_API_KEY_ID            App Store Connect API key id.
#   AC_API_ISSUER_ID         App Store Connect issuer id (UUID).
#   AC_API_KEY_PATH          Path to the AuthKey_*.p8 file.
# Identity override (else auto-detected from keychain):
#   DEVID_APP_IDENTITY       "Developer ID Application: ... (TEAMID)"
#   DEVID_INSTALLER_IDENTITY "Developer ID Installer: ... (TEAMID)"

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}==> $*${NC}"; }

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"           # app-macos/packaging
APP_DIR="$(dirname "$PKG_DIR")"                    # app-macos
DIST_DIR="$APP_DIR/dist"
BUNDLE="$APP_DIR/immurok.app"

: "${VERSION:?VERSION env is required (e.g. VERSION=1.2.3)}"

cd "$APP_DIR"

# ---------------------------------------------------------------------------
# Resolve signing identities
# ---------------------------------------------------------------------------
detect_identity() {
    # $1 = identity prefix, e.g. "Developer ID Application".
    # Use the unfiltered identity list (no -p codesigning): the Developer ID
    # *Installer* identity is a productsign/basic-policy identity and does NOT
    # appear under the codesigning policy. `|| true` keeps a no-match (or the
    # SIGPIPE from head closing the pipe early) from tripping pipefail/set -e
    # before the explicit emptiness check below can print a clean error.
    security find-identity -v 2>/dev/null \
        | grep "$1" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true
}

APP_IDENTITY="${DEVID_APP_IDENTITY:-$(detect_identity 'Developer ID Application')}"
INSTALLER_IDENTITY="${DEVID_INSTALLER_IDENTITY:-$(detect_identity 'Developer ID Installer')}"

if [ -z "$APP_IDENTITY" ]; then
    log_error "No 'Developer ID Application' identity found in keychain."
    exit 1
fi
if [ -z "$INSTALLER_IDENTITY" ]; then
    log_error "No 'Developer ID Installer' identity found in keychain (needed to sign the .pkg)."
    exit 1
fi
log_info "App identity:       $APP_IDENTITY"
log_info "Installer identity: $INSTALLER_IDENTITY"

rm -rf "$DIST_DIR" "$BUNDLE"
mkdir -p "$DIST_DIR"

# ---------------------------------------------------------------------------
# 1. Universal build (app + imk), each arch built separately then lipo'd
#    (matches build-deploy.sh: CLT-friendly, no full Xcode needed).
# ---------------------------------------------------------------------------
log_step "Building universal binaries (arm64 + x86_64)"
# imk 没有 Info.plist 可以事后 stamp，版本号是编译进去的常量 —— 必须在
# swift build 之前用本次发布的版本覆盖掉仓库里的值，否则 pkg 里的 imk
# 会报上一次本地构建的版本。
"$PKG_DIR/sync-cli-version.sh" "$VERSION"
swift build -c release --arch arm64
swift build -c release --arch x86_64
mkdir -p .build/universal/release
lipo -create -output .build/universal/release/immurokApp \
    .build/arm64-apple-macosx/release/immurokApp \
    .build/x86_64-apple-macosx/release/immurokApp
lipo -create -output .build/universal/release/imk \
    .build/arm64-apple-macosx/release/imk \
    .build/x86_64-apple-macosx/release/imk
log_info "app: $(lipo -archs .build/universal/release/immurokApp) | imk: $(lipo -archs .build/universal/release/imk)"

# ---------------------------------------------------------------------------
# 2. Build PAM module
# ---------------------------------------------------------------------------
log_step "Building PAM module"
make -C pam clean >/dev/null 2>&1 || true
make -C pam
[ -f pam/pam_immurok.so ] || { log_error "pam/pam_immurok.so not produced"; exit 1; }

# ---------------------------------------------------------------------------
# 3. Assemble immurok.app bundle
# ---------------------------------------------------------------------------
log_step "Assembling immurok.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
# Executable must be named "immurok" per Info.plist CFBundleExecutable.
cp .build/universal/release/immurokApp "$BUNDLE/Contents/MacOS/immurok"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

# Stamp the release version. CFBundleShortVersionString = user-facing version
# from the git tag; CFBundleVersion stays the committed monotonic build number.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE/Contents/Info.plist"
log_info "CFBundleShortVersionString = $VERSION"

# Copy bundle resources (everything in Resources/ except the source Info.plist
# and any prebuilt *.pkg — the uninstall pkg is rebuilt fresh below).
mkdir -p "$BUNDLE/Contents/Resources"
( cd Resources && \
  rsync -a --exclude 'Info.plist' --exclude '*.pkg' ./ "$BUNDLE/Contents/Resources/" )

# ---------------------------------------------------------------------------
# 4. Build the (nopayload) uninstall pkg, sign it, bundle it inside the app
#    so the in-app "uninstall" action keeps working. Must happen BEFORE the
#    app is signed so codesign --deep seals it into the bundle.
# ---------------------------------------------------------------------------
log_step "Building uninstall pkg"
UNINST_SCRIPTS="$(mktemp -d)"
cp "$PKG_DIR/uninstall-postinstall" "$UNINST_SCRIPTS/postinstall"
chmod +x "$UNINST_SCRIPTS/postinstall"
pkgbuild --nopayload --scripts "$UNINST_SCRIPTS" \
    --identifier "com.immurok.uninstall" --version "$VERSION" \
    "$DIST_DIR/immurok_uninstall_unsigned.pkg"
productsign --sign "$INSTALLER_IDENTITY" \
    "$DIST_DIR/immurok_uninstall_unsigned.pkg" \
    "$BUNDLE/Contents/Resources/immurok_uninstall.pkg"
rm -f "$DIST_DIR/immurok_uninstall_unsigned.pkg"
log_info "Uninstall pkg signed + bundled into app Resources"

# Build the (nopayload) repair pkg: re-adds the immurok PAM line that a macOS
# upgrade strips from /etc/pam.d/authorization. Runs via system_installd (the
# only context permitted to write /etc/pam.d; osascript admin root is TCC-
# blocked). Signed + bundled like the uninstall pkg, BEFORE the app is signed
# so codesign --deep seals it in.
log_step "Building repair pkg"
REPAIR_SCRIPTS="$(mktemp -d)"
cp "$PKG_DIR/repair-postinstall" "$REPAIR_SCRIPTS/postinstall"
chmod +x "$REPAIR_SCRIPTS/postinstall"
pkgbuild --nopayload --scripts "$REPAIR_SCRIPTS" \
    --identifier "com.immurok.repair" --version "$VERSION" \
    "$DIST_DIR/immurok_repair_unsigned.pkg"
productsign --sign "$INSTALLER_IDENTITY" \
    "$DIST_DIR/immurok_repair_unsigned.pkg" \
    "$BUNDLE/Contents/Resources/immurok_repair.pkg"
rm -f "$DIST_DIR/immurok_repair_unsigned.pkg"
rm -rf "$REPAIR_SCRIPTS"
log_info "Repair pkg signed + bundled into app Resources"

# ---------------------------------------------------------------------------
# 5. Sign everything with Developer ID Application + hardened runtime.
#    Sign inner Mach-Os first, the app bundle last.
# ---------------------------------------------------------------------------
log_step "Code signing (Developer ID Application, hardened runtime)"
SIGN=(codesign --force --timestamp --options runtime --sign "$APP_IDENTITY")

"${SIGN[@]}" .build/universal/release/imk
"${SIGN[@]}" pam/pam_immurok.so
"${SIGN[@]}" --entitlements immurok.entitlements --deep "$BUNDLE"

codesign --verify --strict --verbose=2 "$BUNDLE"
log_info "Signatures verified"

# ---------------------------------------------------------------------------
# 6. Build install payload and the component pkg
# ---------------------------------------------------------------------------
log_step "Building installer pkg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$UNINST_SCRIPTS"' EXIT

mkdir -p "$WORK/payload/Applications"
cp -R "$BUNDLE" "$WORK/payload/Applications/immurok.app"

mkdir -p "$WORK/payload/usr/local/bin"
cp .build/universal/release/imk "$WORK/payload/usr/local/bin/imk"
chmod 755 "$WORK/payload/usr/local/bin/imk"

mkdir -p "$WORK/payload/usr/local/lib/pam"
cp pam/pam_immurok.so "$WORK/payload/usr/local/lib/pam/pam_immurok.so"
chmod 644 "$WORK/payload/usr/local/lib/pam/pam_immurok.so"

# Disable bundle relocation (else Installer may target an existing copy
# elsewhere instead of /Applications).
pkgbuild --analyze --root "$WORK/payload" "$WORK/component.plist"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$WORK/component.plist"

INST_SCRIPTS="$WORK/scripts"
mkdir -p "$INST_SCRIPTS"
cp "$PKG_DIR/postinstall" "$INST_SCRIPTS/postinstall"
chmod +x "$INST_SCRIPTS/postinstall"

pkgbuild \
    --root "$WORK/payload" \
    --component-plist "$WORK/component.plist" \
    --scripts "$INST_SCRIPTS" \
    --identifier "com.immurok.pkg" \
    --version "$VERSION" \
    --install-location "/" \
    "$WORK/immurok_unsigned.pkg"

FINAL_PKG="$DIST_DIR/immurok-$VERSION.pkg"
log_step "Signing pkg (Developer ID Installer)"
productsign --sign "$INSTALLER_IDENTITY" "$WORK/immurok_unsigned.pkg" "$FINAL_PKG"
pkgutil --check-signature "$FINAL_PKG" | head -3

# ---------------------------------------------------------------------------
# 7. Notarize + staple
# ---------------------------------------------------------------------------
if [ -n "${AC_API_KEY_ID:-}" ]; then
    log_step "Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$FINAL_PKG" \
        --key "$AC_API_KEY_PATH" \
        --key-id "$AC_API_KEY_ID" \
        --issuer "$AC_API_ISSUER_ID" \
        --wait
    log_step "Stapling notarization ticket"
    xcrun stapler staple "$FINAL_PKG"
    xcrun stapler validate "$FINAL_PKG"
    log_info "Notarized + stapled"
else
    log_warn "AC_API_KEY_ID unset — skipping notarization (pkg is signed but NOT notarized)."
fi

echo
log_info "Done: $FINAL_PKG"
ls -lh "$FINAL_PKG"
