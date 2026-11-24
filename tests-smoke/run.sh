#!/bin/bash
# No hardware, installed app, PAM settings, passwords or network are used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cp "$ROOT/tests-smoke/desktop-experience.swift" "$BUILD/main.swift"
CLANG_MODULE_CACHE_PATH="$BUILD/cache" swiftc -module-cache-path "$BUILD/cache" \
    "$ROOT/AuthInjectionKit/DesktopExperience.swift" "$BUILD/main.swift" -o "$BUILD/check"
"$BUILD/check"
