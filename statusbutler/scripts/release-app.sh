#!/usr/bin/env bash
# T-056a（B1·发布链）：release 构建 → DMG（UDZO）→ SHA-256 → 自校验。
# 用法: bash scripts/release-app.sh [--no-publish]
# --no-publish 是默认且当前唯一模式：GitHub Release 上传留待 Developer ID Secrets
# 配置后由 release-draft.yml 的 manual 步骤接入（本脚本不依赖任何 Secrets 即可全链路跑通）
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="状态管家"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist")"
DMG="$DIST/StatusButler-$VERSION.dmg"

# 参数白名单校验（防注入纪律：任何未登记参数立即失败，绝不进入文件操作）
PUBLISH="no-publish"
for arg in "$@"; do
    case "$arg" in
        --no-publish) PUBLISH="no-publish" ;;
        *) echo "错误: 未知参数 '$arg'（仅支持 --no-publish）" >&2; exit 2 ;;
    esac
done
if [[ "$PUBLISH" != "no-publish" ]]; then
    # 占位：publish 模式尚未开通（Developer ID 签名/公证 Secrets 未配置）
    echo "错误: publish 模式未实现，当前仅支持 --no-publish" >&2
    exit 2
fi

# 组包复用既有 build-app.sh（ad-hoc 签名 .app → dist/），单一事实源不重复实现
bash "$ROOT/scripts/build-app.sh" release no-open

# dist 只保留本次产物：旧 DMG/校验文件清场，保证"一个 .app + 一个 .dmg + 一个 .sha256"
rm -f "$DIST"/*.dmg "$DIST"/*.sha256

# DMG：UDZO（zlib 压缩只读镜像，Sparkle 分发标准形态）；
# -quiet 抑制 hdiutil 的进度噪音，错误仍走 stderr（不会被吞）
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DIST/$APP_NAME.app" -format UDZO -ov "$DMG"

# SHA-256 清单：shasum 标准格式 "<hash>  <filename>"（文件名相对 dist，供 --check 原地复核）
( cd "$DIST" && shasum -a 256 -- "${DMG##*/}" > "${DMG##*/}.sha256" )

# 自校验：校验失败 = 发布链产物不可信，立即失败（fail closed）
( cd "$DIST" && shasum -a 256 --check --status "${DMG##*/}.sha256" )

echo "已发布链产出（--no-publish 模式）:"
echo "  DMG    : ${DMG}"
echo "  SHA-256: ${DMG}.sha256"
echo "  校验   : OK"
