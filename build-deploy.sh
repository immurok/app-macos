#!/bin/bash
#
# immurok Build & Deploy Script
# Usage: ./build-deploy.sh [options]
#
# Options:
#   -f, --firmware    Build and flash firmware
#   -a, --app         Build app
#   -p, --pam         Build PAM module
#   -s, --sign        Sign and deploy to /Applications
#   --all             Build everything and deploy (default if no options)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SIGN_IDENTITY=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ── Xcode 工具链兜底 ────────────────────────────────────────────────────
# swift build（尤其 release + SwiftUI）需要 Xcode 工具链自带的宏插件
# (SwiftUIMacros)。本机 xcode-select 若指向 CommandLineTools，它没有宏插件，
# 构建会报 "External macro implementation type 'SwiftUIMacros.StateMacro'
# could not be found" → Build failed。这里在脚本内强制切到 Xcode（若已装），
# 只作用于本次构建的子进程，不改全局 xcode-select、无需 sudo。
if [ -z "${DEVELOPER_DIR:-}" ]; then
    _dd="$(xcode-select -p 2>/dev/null || true)"
    case "$_dd" in
        *CommandLineTools*|"")
            if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
                export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
                log_info "Using Xcode toolchain (xcode-select points at CLT): $DEVELOPER_DIR"
            else
                log_warn "Xcode.app 未找到；swift build 可能失败（CLT 缺 SwiftUI 宏插件）"
                log_warn "请安装 Xcode，或 sudo xcode-select -s /path/to/Xcode.app/Contents/Developer"
            fi
            ;;
    esac
fi

# Find and select a signing identity from Keychain
select_sign_identity() {
    if [ -n "$SIGN_IDENTITY" ]; then
        return
    fi

    # Check saved identity
    local saved_id_file="$SCRIPT_DIR/.sign-identity"
    if [ -f "$saved_id_file" ]; then
        SIGN_IDENTITY="$(cat "$saved_id_file")"
        # Verify it still exists
        if security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
            log_info "Using saved signing identity: $SIGN_IDENTITY"
            return
        else
            log_warn "Saved identity no longer valid, re-selecting..."
            rm -f "$saved_id_file"
        fi
    fi

    # List available identities
    local identities=()
    while IFS= read -r line; do
        # Extract the quoted identity name
        local name
        name=$(echo "$line" | sed 's/.*"\(.*\)".*/\1/')
        if [ -n "$name" ]; then
            identities+=("$name")
        fi
    done < <(security find-identity -v -p codesigning | grep -v "^$" | grep -v "valid identities found")

    if [ ${#identities[@]} -eq 0 ]; then
        log_error "No codesigning identities found in Keychain."
        log_error "Install a certificate from Xcode > Settings > Accounts > Manage Certificates."
        exit 1
    fi

    if [ ${#identities[@]} -eq 1 ]; then
        SIGN_IDENTITY="${identities[0]}"
        log_info "Using signing identity: $SIGN_IDENTITY"
    else
        echo ""
        echo -e "${CYAN}Available signing identities:${NC}"
        for i in "${!identities[@]}"; do
            echo "  $((i + 1))) ${identities[$i]}"
        done
        echo ""
        while true; do
            read -rp "Select identity [1-${#identities[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#identities[@]} ]; then
                SIGN_IDENTITY="${identities[$((choice - 1))]}"
                break
            fi
            echo "Invalid choice. Try again."
        done
        log_info "Selected: $SIGN_IDENTITY"
    fi

    # Save for next time
    echo "$SIGN_IDENTITY" > "$saved_id_file"
    log_info "Saved identity to $saved_id_file"
}

# Build firmware
build_firmware() {
    log_info "Building firmware..."
    cd "$PROJECT_DIR/firmware"
    pio run
    log_info "Firmware build complete"
}

# Flash firmware
flash_firmware() {
    log_info "Flashing firmware..."
    cd "$PROJECT_DIR/firmware"
    pio run -t upload
    log_info "Firmware flashed"
}

# Build PAM module
build_pam() {
    log_info "Building PAM module..."
    cd "$SCRIPT_DIR/pam"
    make
    log_info "PAM module build complete"
}

# Build PAM installer packages
build_pam_pkg() {
    log_info "Building PAM installer packages..."
    "$PROJECT_DIR/scripts/build-pam-pkg.sh"
    log_info "PAM packages built"
}

# Build app (Menu Bar App with integrated BLE/PAM)
build_app() {
    log_info "Building app (v4.0 - Menu Bar) [universal arm64 + x86_64]..."
    cd "$SCRIPT_DIR"

    # imk 的版本号是编译进去的常量，必须在 swift build 之前从 app 的
    # CFBundleShortVersionString 同步过去。改了 Info.plist 版本号后，
    # 生成的 CLISources/Version.swift 会出现在 git status 里，记得一起提交。
    "$SCRIPT_DIR/packaging/sync-cli-version.sh" \
        "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
    # swift build's `--arch arm64 --arch x86_64` flag needs the xcbuild backend
    # which only ships with full Xcode.app. To stay CLT-friendly we build each
    # arch separately and lipo-combine. Cross-compile from arm64 host to
    # x86_64 works fine on Apple Silicon + CLT.
    swift build -c release --arch arm64
    swift build -c release --arch x86_64
    mkdir -p .build/universal/release
    lipo -create -output .build/universal/release/immurokApp \
        .build/arm64-apple-macosx/release/immurokApp \
        .build/x86_64-apple-macosx/release/immurokApp
    lipo -create -output .build/universal/release/imk \
        .build/arm64-apple-macosx/release/imk \
        .build/x86_64-apple-macosx/release/imk
    log_info "App build complete (universal: $(lipo -archs .build/universal/release/immurokApp))"
}

# Assemble + sign the app bundle (no sudo needed) — shared by sign_deploy / agent_deploy
prepare_bundle() {
    log_info "Preparing app bundle..."
    cd "$SCRIPT_DIR"

    # Ensure app bundle structure exists
    mkdir -p immurok.app/Contents/{MacOS,Resources}

    # Copy executable (must be named "immurok" per Info.plist).
    # Source is the lipo'd universal binary from build_app.
    cp .build/universal/release/immurokApp immurok.app/Contents/MacOS/immurok

    # Copy Info.plist
    cp Resources/Info.plist immurok.app/Contents/

    # Auto-increment build number
    BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" immurok.app/Contents/Info.plist)
    NEW_BUILD=$((BUILD_NUM + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" immurok.app/Contents/Info.plist
    # Also update source Info.plist to persist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" Resources/Info.plist
    log_info "Build number: $BUILD_NUM -> $NEW_BUILD"

    # Copy uninstall pkg to app bundle Resources (for in-app uninstall)
    if [ -f "Resources/immurok_uninstall.pkg" ]; then
        cp "Resources/immurok_uninstall.pkg" immurok.app/Contents/Resources/
        log_info "Uninstall package bundled in app Resources"
    else
        log_warn "Uninstall package not found in Resources/"
    fi

    # Copy bundled OTA bridge firmware (1.6.0 HMAC bridge, frozen forever)
    if [ -f "Resources/fw-1.6.0-bridge.imfw" ]; then
        cp "Resources/fw-1.6.0-bridge.imfw" immurok.app/Contents/Resources/
        log_info "OTA bridge firmware bundled in app Resources"
    else
        log_warn "OTA bridge firmware not found in Resources/"
    fi

    # Copy app icon
    if [ -f "Resources/AppIcon.icns" ]; then
        cp Resources/AppIcon.icns immurok.app/Contents/Resources/
        log_info "App icon bundled"
    fi

    # Copy About-page logo (template PNG, tinted by accent color)
    if [ -f "Resources/icon.png" ]; then
        cp Resources/icon.png immurok.app/Contents/Resources/
        log_info "About logo bundled"
    fi

    # Copy status bar icon template
    for f in Resources/StatusBarIconTemplate*.png; do
        [ -f "$f" ] && cp "$f" immurok.app/Contents/Resources/
    done

    # Build the repair pkg (re-adds the immurok PAM line after a macOS upgrade
    # strips it from /etc/pam.d/authorization). Must run via system_installd —
    # osascript admin root is TCC-blocked from writing /etc/pam.d. Mirrors the
    # uninstall pkg flow. UNSIGNED here for local dev; build-pkg.sh signs it for
    # release. An unsigned pkg still installs via Installer after a Gatekeeper
    # override (right-click → Open).
    if [ -f "packaging/repair-postinstall" ]; then
        REPAIR_SCRIPTS="$(mktemp -d)"
        cp packaging/repair-postinstall "$REPAIR_SCRIPTS/postinstall"
        chmod +x "$REPAIR_SCRIPTS/postinstall"
        pkgbuild --nopayload --scripts "$REPAIR_SCRIPTS" \
            --identifier "com.immurok.repair" --version "1.0" \
            immurok.app/Contents/Resources/immurok_repair.pkg >/dev/null
        rm -rf "$REPAIR_SCRIPTS"
        log_info "Repair pkg (unsigned, dev) bundled in app Resources"
    else
        log_warn "packaging/repair-postinstall not found"
    fi

    # Copy localization files to app bundle
    if [ -d "Resources/Localization" ]; then
        mkdir -p immurok.app/Contents/Resources/Localization
        cp Resources/Localization/*.json immurok.app/Contents/Resources/Localization/
        log_info "Localization files bundled in app Resources"
    fi

    select_sign_identity
    log_info "Signing app with: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" \
        --entitlements immurok.entitlements \
        --options runtime \
        immurok.app

    # Verify signature
    codesign -vv immurok.app
}

# Sign and deploy (interactive: sudo prompts in terminal)
sign_deploy() {
    prepare_bundle

    # Quit running immurok before deploying
    if pgrep -x immurok > /dev/null 2>&1; then
        log_info "Quitting running immurok..."
        osascript -e 'quit app "immurok"' 2>/dev/null || true
        sleep 1
        # Force kill if still running
        pkill -x immurok 2>/dev/null || true
        sleep 0.5
    fi

    log_info "Deploying to /Applications..."
    sudo rm -rf /Applications/immurok.app
    sudo cp -r immurok.app /Applications/

    log_info "App deployed to /Applications/immurok.app"

    # Install imk CLI
    if [ -f ".build/universal/release/imk" ]; then
        log_info "Installing imk CLI to /usr/local/bin..."
        sudo mkdir -p /usr/local/bin
        sudo cp .build/universal/release/imk /usr/local/bin/imk
        sudo chmod 755 /usr/local/bin/imk
        log_info "imk CLI installed"
    fi

    # Relaunch
    log_info "Relaunching immurok..."
    open /Applications/immurok.app
}

# Agent deploy: all privileged ops in ONE `imk run --agent -- sudo` —
# imk pre-auth is single-consume and sudo timestamps don't cache on this
# machine, so a second sudo would hit the fingerprint gate after the app
# is already dead. Killing the app severs the imk wrapper (its exit code
# becomes meaningless) but the root shell keeps running, so success is
# judged by the DEPLOY_OK sentinel in the output, not the exit code.
agent_deploy() {
    prepare_bundle

    if ! command -v imk >/dev/null || ! pgrep -x immurok >/dev/null; then
        log_error "imk not installed or immurok app not running — use -s for interactive deploy"
        exit 1
    fi

    log_info "Requesting single-sudo deploy via imk (touch the sensor)..."
    local out
    out=$(imk run --agent -- sudo /bin/bash -c "
        pkill -x immurok 2>/dev/null || true
        sleep 1
        rm -rf /Applications/immurok.app
        cp -R '$SCRIPT_DIR/immurok.app' /Applications/
        mkdir -p /usr/local/bin
        cp '$SCRIPT_DIR/.build/universal/release/imk' /usr/local/bin/imk
        chmod 755 /usr/local/bin/imk
        echo DEPLOY_OK
    " 2>&1) || true
    echo "$out"

    if ! grep -q DEPLOY_OK <<< "$out"; then
        log_error "Agent deploy failed — no DEPLOY_OK sentinel (denied or error above)"
        exit 1
    fi

    log_info "App deployed to /Applications/immurok.app, imk CLI updated"
    log_info "Relaunching immurok..."
    open /Applications/immurok.app
}

# Parse arguments
DO_FIRMWARE=false
DO_FLASH=false
DO_PAM=false
DO_APP=false
DO_SIGN=false
DO_AGENT=false
DO_ALL=false

if [ $# -eq 0 ]; then
    DO_ALL=true
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--firmware)
            DO_FIRMWARE=true
            DO_FLASH=true
            shift
            ;;
        --firmware-only)
            DO_FIRMWARE=true
            shift
            ;;
        -p|--pam)
            DO_PAM=true
            shift
            ;;
        -a|--app)
            DO_APP=true
            shift
            ;;
        -s|--sign)
            DO_SIGN=true
            shift
            ;;
        --agent)
            DO_AGENT=true
            shift
            ;;
        --all)
            DO_ALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -f, --firmware    Build and flash firmware"
            echo "  --firmware-only   Build firmware without flashing"
            echo "  -p, --pam         Build PAM module"
            echo "  -a, --app         Build app"
            echo "  -s, --sign        Sign and deploy to /Applications"
            echo "  --agent           Sign and deploy via imk single-sudo (for AI agents)"
            echo "  --all             Build everything and deploy (default)"
            echo "  -h, --help        Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Execute based on options
if $DO_ALL; then
    build_pam
    build_app
    sign_deploy
    build_pam_pkg
    log_info "All done! (Use -f to also build/flash firmware)"
else
    $DO_FIRMWARE && build_firmware
    $DO_FLASH && flash_firmware
    $DO_PAM && build_pam
    $DO_APP && build_app
    $DO_SIGN && sign_deploy
    $DO_AGENT && agent_deploy
fi

log_info "Complete!"
