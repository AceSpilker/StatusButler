#!/usr/bin/env bash
# 组装 ad-hoc 签名的 StatusButler.app（T-001）
# 用法: bash scripts/build-app.sh [release|debug] [no-open]
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
OPEN="${2:-open}"
case "$CONFIG" in
    release|debug) ;;
    *) echo "错误: 配置只能是 release 或 debug，收到 '$CONFIG'" >&2; exit 2 ;;
esac
case "$OPEN" in
    open|no-open) ;;
    *) echo "错误: 第二参数只能是 open 或 no-open" >&2; exit 2 ;;
esac
APP_NAME="状态管家"
BINARY="StatusButler"
DIST="$ROOT/dist"

cd "$ROOT"
swift build -c "$CONFIG"

APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIG/$BINARY" "$APP/Contents/MacOS/$BINARY"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null
echo "已构建: ${APP}（ad-hoc 签名）"

if [[ "$OPEN" != "no-open" ]]; then
    open "$APP"
fi
