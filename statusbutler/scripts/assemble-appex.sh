#!/usr/bin/env bash
# T-054（A6·5）：把 swift build 产出的 StatusButlerWidgets 可执行文件组装成 .app 内 appex。
# 用法: bash scripts/assemble-appex.sh <.app 路径> [release|debug] [--dry-run]
# --dry-run 不构建不写盘，只打印组装清单（键=值 一行一项，相对 .app 根）——测试/CI 结构预检用
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WIDGET_TARGET="StatusButlerWidgets"
APPEX_REL="Contents/PlugIns/StatusButlerWidgets.appex"
EXT_POINT="com.apple.widgetkit-extension"

APP_PATH=""
CONFIG="release"
for arg in "$@"; do
    case "$arg" in
        release|debug) CONFIG="$arg" ;;
        --dry-run) DRY_RUN="yes" ;;
        -*) echo "错误: 未知参数 '$arg'（仅支持 <.app 路径> [release|debug] [--dry-run]）" >&2; exit 2 ;;
        *) if [[ -n "$APP_PATH" ]]; then
               echo "错误: 多余参数 '$arg'（.app 路径只取一个）" >&2; exit 2
           fi
           APP_PATH="$arg" ;;
    esac
done
if [[ -z "${DRY_RUN:-}" ]]; then DRY_RUN="no"; fi
[[ -n "$APP_PATH" ]] || { echo "错误: 缺少 <.app 路径> 参数" >&2; exit 2; }

# 组装清单先行（dry-run 与实装共用同一份输出，预检与实装不会各说各话）
echo "appex=$APPEX_REL"
echo "binary=$APPEX_REL/Contents/MacOS/$WIDGET_TARGET"
echo "plist=$APPEX_REL/Contents/Info.plist"
echo "extpoint=$EXT_POINT"

if [[ "$DRY_RUN" == "yes" ]]; then
    exit 0
fi

APPEX="$APP_PATH/$APPEX_REL"
BIN="$ROOT/.build/$CONFIG/$WIDGET_TARGET"
if [[ ! -f "$BIN" ]]; then
    echo "错误: 未找到 $BIN（先 swift build -c $CONFIG --product $WIDGET_TARGET）" >&2
    exit 2
fi

mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN" "$APPEX/Contents/MacOS/$WIDGET_TARGET"
cp "$ROOT/Support/StatusButlerWidgets-Info.plist" "$APPEX/Contents/Info.plist"

# 版本两键与主 App Support/Info.plist 同源：组装期注入，杜绝扩展/主 App 版本漂移
for key in CFBundleShortVersionString CFBundleVersion; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ROOT/Support/Info.plist")"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$APPEX/Contents/Info.plist"
done

# rpath 补丁：扩展二进制链接 @rpath/Sparkle.framework（Core 的 SPM 依赖），SPM 给的 rpath 只在
# .build 内有效。指向主 App 的 Contents/Frameworks（appex 与主 App 共享同一份框架，不双拷）：
# MacOS →(1) appex/Contents →(2) appex →(3) PlugIns →(4) 主 Contents/Frameworks
if [[ -d "$ROOT/.build/$CONFIG/Sparkle.framework" ]]; then
    /usr/bin/install_name_tool -add_rpath "@executable_path/../../../../Frameworks" \
        "$APPEX/Contents/MacOS/$WIDGET_TARGET" 2>/dev/null || true
fi

# 签名不在此做：调用方（build-app.sh）对整个 .app codesign --deep，appex 随主 bundle 一并签
echo "已组装: $APPEX"
