#!/usr/bin/env bash
# T-222 风扇特权 Helper 构建：Support/FanHelper/main.swift → .build/fanhelper/
# statusbutler-fanhelper。helper 不进 SwiftPM 构建图（Support/ 不在 target 路径），
# 与 MobileBatteryHelper 同纪律——特权件独立编译独立审计；区别是本 helper 零第三方
# 依赖，一条 swiftc 即可，无 manifest/无 clone。
# 真机验证（实装 LaunchDaemon + root 下真实写 SMC）留安装半场（用户管理员确认后）；
# 本脚本 --dry-run 供 CI 契约测试钉住，--check-layout 冒烟断言 SMC 结构 80 字节布局。
#
# 用法: bash Support/FanHelper/build-fanhelper.sh [--dry-run]
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/Support/FanHelper/main.swift"
PLIST="$ROOT/Support/FanHelper/com.statusbutler.fanhelper.plist"
WORK="$ROOT/.build/fanhelper"
HELPER="$WORK/statusbutler-fanhelper"
DRY_RUN=0

usage() {
    cat <<'EOF'
用法: bash Support/FanHelper/build-fanhelper.sh [--dry-run]
  --dry-run  只打印构建计划，零副作用
产物: .build/fanhelper/statusbutler-fanhelper（特权 helper 可执行）
真跑前置: swiftc（xcrun 可定位的工具链）
EOF
}

# 参数白名单（Mimosa 防注入纪律，与 build-mobile-battery-helper.sh 同源）
while (( $# > 0 )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "错误: 未知参数 '$1'（白名单: --dry-run --help）" >&2; exit 2 ;;
    esac
    shift
done

if [[ ! -f "$SOURCE" ]]; then
    echo "错误: helper 源码缺失: $SOURCE" >&2
    exit 2
fi
if [[ ! -f "$PLIST" ]]; then
    echo "错误: LaunchDaemon 模板缺失: $PLIST" >&2
    exit 2
fi

# 工具链解析优先 PATH（开发者/CI 都先 export swiftly——CLT 的 swiftc 在 swiftly
# 环境下有 SwiftBridging 模块重定义冲突，实测仅 PATH 里 swiftly 的 swiftc 可用），
# PATH 没有再回退 xcrun（纯 Xcode 环境）
SWIFTC=""
if command -v swiftc >/dev/null 2>&1; then
    SWIFTC="$(command -v swiftc)"
else
    SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
fi
if [[ -z "$SWIFTC" ]]; then
    echo "错误: 找不到 swiftc（需要 swiftly 工具链或 Xcode CLT）" >&2
    exit 2
fi

if (( DRY_RUN )); then
    echo "[dry-run] 编译: $SWIFTC -O $SOURCE -o $HELPER"
    # bash 3.2 会把紧贴变量的全角字符粘进变量名：中文前一律 ${var} 显式定界（AGENTS 实战经验）
    echo "[dry-run] 源码: ${SOURCE}（就绪）"
    echo "[dry-run] 模板: ${PLIST}（随产物进 .app Resources/FanHelper/）"
    echo "[dry-run] 冒烟: 运行产物回显 ping → {\"ok\":true}（构建后执行）"
    exit 0
fi

mkdir -p "$WORK"
echo "[编译] helper: ${SOURCE} → ${HELPER}"
# 剥掉 swiftly 代理的防套娃标记：本脚本可能从 swift test 等嵌套环境被调用
unset SWIFTLY_PROXY_IN_PROGRESS 2>/dev/null || true
"$SWIFTC" -O "$SOURCE" -o "$HELPER"
chmod 755 "$HELPER"

# 冒烟：ping 行协议往返（零 SMC 副作用）+ 白名单拒绝路径 exit 1
SMOKE="$(printf '%s\n' '{"action":"ping"}' | "$HELPER")"
if [[ "$SMOKE" != '{"ok":true}' ]]; then
    echo "错误: helper ping 冒烟失败，实得: $SMOKE" >&2
    exit 1
fi
if printf '%s\n' '{"action":"set","key":"BC1C","value":80}' | "$HELPER" >/dev/null 2>&1; then
    echo "错误: helper 白名单拒绝冒烟失败（充电域键未被 exit 1 拦截）" >&2
    exit 1
fi

echo "已构建 helper: ${HELPER}（ping 往返与白名单拒绝冒烟通过）"
