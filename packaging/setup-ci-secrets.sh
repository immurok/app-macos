#!/bin/bash
#
# setup-ci-secrets.sh — Push the 8 GitHub Actions secrets that
# .github/workflows/release.yml needs, to immurok/app-macos.
#
# You provide the two Developer ID .p12 exports (cert + private key) and the
# App Store Connect API key (.p8 + Key ID + Issuer ID). This script base64-
# encodes them and sets them as repo secrets via `gh`. The temporary keychain
# password is generated for you.
#
# Export the .p12 files first (Keychain Access → right-click each identity →
# Export → .p12, set an export password):
#   - "Developer ID Application: Nervina Next PTE. LTD (UH43X23J62)"
#   - "Developer ID Installer:  Nervina Next PTE. LTD (UH43X23J62)"
#
# Usage (env vars or interactive prompts):
#   APP_P12=~/Desktop/DevIDApp.p12        APP_P12_PASS=...    \
#   INSTALLER_P12=~/Desktop/DevIDInst.p12 INSTALLER_P12_PASS=... \
#   AC_API_KEY_ID=XXXXXXXXXX               AC_API_ISSUER_ID=xxxx-... \
#   AC_P8=~/Downloads/AuthKey_XXXXXX.p8    \
#   packaging/setup-ci-secrets.sh
#
# Anything not passed as an env var is prompted for (passwords hidden).

set -euo pipefail

REPO="${REPO:-immurok/app-macos}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
step() { echo -e "${CYAN}==> $*${NC}"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

command -v gh >/dev/null  || die "gh CLI not found"
command -v base64 >/dev/null || die "base64 not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

prompt()      { local v; read -r -p "$1: " v; echo "$v"; }
prompt_pass() { local v; read -r -s -p "$1: " v; echo >&2; echo "$v"; }

APP_P12="${APP_P12:-$(prompt 'Developer ID *Application* .p12 path')}"
[ -f "$APP_P12" ] || die "not found: $APP_P12"
APP_P12_PASS="${APP_P12_PASS:-$(prompt_pass 'Application .p12 export password')}"

INSTALLER_P12="${INSTALLER_P12:-$(prompt 'Developer ID *Installer* .p12 path')}"
[ -f "$INSTALLER_P12" ] || die "not found: $INSTALLER_P12"
INSTALLER_P12_PASS="${INSTALLER_P12_PASS:-$(prompt_pass 'Installer .p12 export password')}"

AC_P8="${AC_P8:-$(prompt 'App Store Connect AuthKey_*.p8 path')}"
[ -f "$AC_P8" ] || die "not found: $AC_P8"
AC_API_KEY_ID="${AC_API_KEY_ID:-$(prompt 'App Store Connect Key ID')}"
AC_API_ISSUER_ID="${AC_API_ISSUER_ID:-$(prompt 'App Store Connect Issuer ID (UUID)')}"

# Random temp-keychain password for the CI runner (value is arbitrary).
KEYCHAIN_PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)"

b64() { base64 -i "$1" | tr -d '\n'; }

step "Setting secrets on $REPO"
gh secret set DEVID_APP_CERT_P12_BASE64       --repo "$REPO" --body "$(b64 "$APP_P12")"
gh secret set DEVID_APP_CERT_PASSWORD         --repo "$REPO" --body "$APP_P12_PASS"
gh secret set DEVID_INSTALLER_CERT_P12_BASE64 --repo "$REPO" --body "$(b64 "$INSTALLER_P12")"
gh secret set DEVID_INSTALLER_CERT_PASSWORD   --repo "$REPO" --body "$INSTALLER_P12_PASS"
gh secret set AC_API_KEY_P8_BASE64            --repo "$REPO" --body "$(b64 "$AC_P8")"
gh secret set AC_API_KEY_ID                   --repo "$REPO" --body "$AC_API_KEY_ID"
gh secret set AC_API_ISSUER_ID                --repo "$REPO" --body "$AC_API_ISSUER_ID"
gh secret set KEYCHAIN_PASSWORD               --repo "$REPO" --body "$KEYCHAIN_PASSWORD"

echo
info "Done. Secrets now set:"
gh secret list --repo "$REPO"
