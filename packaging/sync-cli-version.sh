#!/bin/bash
#
# 把 imk CLI 的版本号同步成 macOS app 的版本号。
#
# 单一真源是 app 的 CFBundleShortVersionString。两条构建路径各自取值：
#   - 本地：build-deploy.sh 从 Resources/Info.plist 读
#   - 发布：build-pkg.sh 用 git tag 派生的 $VERSION
#
# 必须在 `swift build` 之前调用 —— 版本号是编译进 imk 的常量。发布流程里
# app 的 Info.plist 是编译完才刷版本的（build-pkg.sh 的 stamp 步骤），imk
# 没有 Info.plist 可刷，只能提前生成。
#
# 生成的 CLISources/Version.swift 要入 git：这样不经过脚本的裸
# `swift build` 也能编过，拿到的是上次构建时的版本号。
#
set -euo pipefail

VERSION="${1:?usage: sync-cli-version.sh <version>}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/CLISources/Version.swift"

NEW="// 由 packaging/sync-cli-version.sh 生成，勿手改。
// imk 的版本号始终等于 macOS app 的 CFBundleShortVersionString —— 两者由
// 同一个 .pkg 一起安装，分开编号只会让用户报 issue 时对不上号。
let version = \"$VERSION\""

# 只在真的变了才写：否则每次构建都会 touch 到 mtime，白白触发重编。
if [ ! -f "$OUT" ] || [ "$(cat "$OUT")" != "$NEW" ]; then
    printf '%s\n' "$NEW" > "$OUT"
    echo "[INFO] imk 版本号同步为 $VERSION"
fi
