#!/usr/bin/env bash
# 组装 ad-hoc 签名的 StatusButler.app（T-001）；T-054 起附带组装 WidgetKit 扩展 appex、
# T-055 起附带嵌入 Sparkle.framework（Core 经 SPM 二进制依赖链接，拷出 .build 后必须随包携带）
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
WIDGET_TARGET="StatusButlerWidgets"
DIST="$ROOT/dist"

cd "$ROOT"
# --product 逐个点名：主 App 与扩展都要（默认 swift build 亦会全建，这里显式声明组装依赖）
swift build -c "$CONFIG" --product "$BINARY"
swift build -c "$CONFIG" --product "$WIDGET_TARGET"

APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIG/$BINARY" "$APP/Contents/MacOS/$BINARY"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

# Sparkle.framework：Core 依赖 Sparkle → 主 App 与扩展二进制都带 LC_LOAD_DYLIB(Sparkle.framework)。
# 离开 .build 的 rpath 后必须把框架嵌进 bundle，否则两个进程都起不来；
# 单份放主 App Contents/Frameworks，扩展经 rpath 回指（见 assemble-appex.sh 的补丁说明）
SPARKLE="$ROOT/.build/$CONFIG/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
    # 主二进制 rpath 补丁：SPM 给的 rpath 只在 .build 内有效，@loader_path 从 Contents/MacOS 回指 ../Frameworks
    /usr/bin/install_name_tool -add_rpath "@loader_path/../Frameworks" \
        "$APP/Contents/MacOS/$BINARY" 2>/dev/null || true
else
    echo "警告: 未找到 $SPARKLE（Sparkle 依赖缺失？），跳过框架嵌入" >&2
fi

# T-054：组装 WidgetKit 扩展（Info.plist 模板 + 版本注入 + 清单输出见该脚本）
bash "$ROOT/scripts/assemble-appex.sh" "$APP" "$CONFIG"

/usr/bin/codesign --force --deep --sign - "$APP" >/dev/null
echo "已构建: ${APP}（ad-hoc 签名，含 StatusButlerWidgets.appex）"

if [[ "$OPEN" != "no-open" ]]; then
    open "$APP"
fi
