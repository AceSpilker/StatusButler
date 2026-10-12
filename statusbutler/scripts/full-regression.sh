#!/usr/bin/env bash
# T-057（C1·1.4）：全量回归一键脚本——提交/发布前的最后一道门。
# 双配置构建 → 测试两遍（抓偶发）→ 组包 → dist 产物断言 → butler CLI 冒烟；
# 每步 PASS/FAIL 摘总，任一 FAIL 总退出码 1。用法: bash scripts/full-regression.sh
# 参数白名单（防注入纪律）：--help/-h 之外一律 exit 2，绝不进入构建/文件操作
set -uo pipefail   # 不用 -e：步骤失败要计入摘要继续跑完，最后统一裁决

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.swiftly/bin:$PATH"   # 本地与 CI 同源：swiftly 工具链优先

show_help() {
    cat <<'EOF'
状态管家全量回归（T-057）—— 提交/发布前的最后一道门

用法: bash scripts/full-regression.sh

步骤（每步 PASS/FAIL，任一 FAIL 总退出码 1）:
  1. swift build                    debug 构建
  2. swift build -c release         release 构建
  3. swift test                     全量测试 · 第 1 遍
  4. swift test                     全量测试 · 第 2 遍（抓偶发：负载敏感用例单跑常过、全量偶挂）
  5. build-app.sh release no-open   组包 ad-hoc 签名 .app → dist/
  6. dist 产物断言                  Info.plist 键 / 可执行存在 / codesign -dv ad-hoc 签名
  7. butler CLI 冒烟                --help 动词面 / status 退出码 0（fixture 快照）/
                                    无 App 时 status --json 退出码 2 + 钉死错误载荷

参数: --help | -h 显示本帮助（exit 0）；其余任何参数 exit 2（未知参数）
日志: 每步输出落 /tmp/statusbutler-regression.*（摘要末行给出路径，失败步骤末 20 行就地展开）
EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h) show_help; exit 0 ;;
        *) echo "错误: 未知参数 '$arg'（仅支持 --help）" >&2; exit 2 ;;
    esac
done

LOG_DIR="$(mktemp -d /tmp/statusbutler-regression.XXXXXX)"
PASS_COUNT=0 FAIL_COUNT=0 STEP_INDEX=0
SUMMARY=()

# CLI 冒烟会临时撤走用户真实快照（现场可复现），中断时兜底放回
SNAPSHOT="$HOME/Library/Application Support/StatusButler/WidgetData/widget-snapshot.json"
BACKUP="$LOG_DIR/widget-snapshot.backup.json"
restore_snapshot() {
    if [[ -e "$BACKUP" ]]; then mv -f "$BACKUP" "$SNAPSHOT" 2>/dev/null || true; fi
}
trap restore_snapshot EXIT

record() {  # record <pass|fail> <步骤名>
    if [[ "$1" == "pass" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1)); SUMMARY+=("PASS  $2")
    else
        FAIL_COUNT=$((FAIL_COUNT + 1)); SUMMARY+=("FAIL  $2")
    fi
}

run_step() {  # run_step <步骤名> <命令...>：命令退出码非 0 即 FAIL，失败就地展开日志末 20 行
    local name="$1"; shift
    STEP_INDEX=$((STEP_INDEX + 1))
    local log
    log="$(printf '%s/%02d' "$LOG_DIR" "$STEP_INDEX").log"
    if "$@" >"$log" 2>&1; then
        record pass "$name"
        # swift test 两步额外透出官方摘要行（Suite/Test run 统计）
        case "$name" in
            *swift\ test*) grep -m1 "Test run with" "$log" | sed 's/^/      /' || true ;;
        esac
    else
        record fail "$name"
        echo "      ↳ 失败详情（日志 $log 末 20 行）:"
        tail -20 "$log" | sed 's/^/        /'
    fi
}

# 步骤 6：dist 产物结构断言——Info.plist 关键键值 / 可执行存在且可执行 / ad-hoc 签名
assert_dist_bundle() {
    local app="$ROOT/dist/状态管家.app"
    [[ -d "$app" ]] || { echo "缺 .app 包: $app"; return 1; }
    local exe="$app/Contents/MacOS/StatusButler"
    [[ -x "$exe" ]] || { echo "缺可执行文件（或无执行位）: $exe"; return 1; }

    local spec key want got
    for spec in \
        "CFBundleIdentifier=com.linzhongyang.statusbutler" \
        "CFBundleExecutable=StatusButler" \
        "CFBundleName=状态管家" \
        "CFBundleShortVersionString=0.1.0" \
        "LSMinimumSystemVersion=13.0"; do
        key="${spec%%=*}"; want="${spec#*=}"
        got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null)" \
            || { echo "Info.plist 缺键: $key"; return 1; }
        [[ "$got" == "$want" ]] || { echo "Info.plist $key: 期望 '$want' 实得 '$got'"; return 1; }
    done
    # LSUIElement 必须为 true：菜单栏 App 不进 Dock（A2·S3）；PlistBuddy 对布尔键打印 true
    got="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$app/Contents/Info.plist" 2>/dev/null)" \
        || { echo "Info.plist 缺键: LSUIElement"; return 1; }
    [[ "$got" == "true" ]] || { echo "LSUIElement 应为 true，实得 '$got'"; return 1; }

    local cs
    cs="$(/usr/bin/codesign -dv "$app" 2>&1)" || { echo "codesign -dv 失败: $cs"; return 1; }
    grep -q "Signature=adhoc" <<<"$cs" \
        || { echo "签名不是 ad-hoc: $(grep -m1 'Signature=' <<<"$cs" || echo 无)"; return 1; }
    /usr/bin/codesign --verify --strict "$app" 2>/dev/null \
        || { echo "codesign --verify --strict 未通过"; return 1; }
    # bash 3.2（macOS 自带）会把 $var 后紧跟的多字节字符（如全角括号）解析进变量名，
    # set -u 下即 unbound 崩溃——变量与中文之间一律 ${var} 显式定界（T-057 实测）
    echo "dist 断言通过: ${app}（ad-hoc 签名）"
}

# 步骤 7：butler CLI 冒烟——契约可复现：无主 App 时注入 fixture 快照测码 0，撤走测码 2；
# 用户真实快照（若有）移入日志目录，结束原样放回（现场零破坏）
cli_smoke() {
    local butler="$ROOT/.build/debug/butler"
    [[ -x "$butler" ]] || { echo "缺 CLI 可执行: ${butler}（依赖步骤 1 的 debug 构建）"; return 1; }

    # ① --help 动词面：帮助文本由 ButlerCommand.allowed 现算，锚代表动词 + 退出码表
    local help code=0 out
    help="$("$butler" --help)" || { echo "--help 退出码非 0"; return 1; }
    grep -q "status" <<<"$help" && grep -q "volume" <<<"$help" && grep -q "退出码" <<<"$help" \
        || { echo "--help 缺动词面/退出码表"; return 1; }

    # ② status 退出码 0：fixture 快照（契约格式见 WidgetSnapshotModels，键名钉死）
    local dir had_real=0 rc=0
    dir="$(dirname "$SNAPSHOT")"
    if [[ -e "$SNAPSHOT" ]]; then mv "$SNAPSHOT" "$BACKUP"; had_real=1; fi
    mkdir -p "$dir"
    printf '%s' '{"schemaVersion":1,"generatedAt":700000000,"battery":{"battery":{"level":66,"charging":true}},"link":{"wifi":{"ssid":"Regression","signalBars":4}},"volume":{"level":50,"isMuted":false},"maxCelsius":45.5,"fanAverageRPM":1800,"netBytesPerSec":{"in":1250000,"out":250000}}' > "$SNAPSHOT"
    out="$("$butler" status)" || code=$?
    if [[ $code -ne 0 ]]; then
        echo "status（有快照）退出码 ${code}，期望 0"; rc=1
    elif ! grep -q "电池" <<<"$out"; then
        echo "status 输出缺电池行，实得: $out"; rc=1
    else
        # ③ 无 App 时 --json：撤走快照 → 码 2 + 钉死载荷（AU-04 契约）
        rm -f "$SNAPSHOT"
        code=0; out="$("$butler" status --json)" || code=$?
        if [[ $code -ne 2 ]]; then
            echo "status --json（无快照）退出码 ${code}，期望 2"
            pgrep -x StatusButler >/dev/null 2>&1 \
                && echo "（注意: 主 App 正在运行，可能在检查窗口内重建了快照）"
            rc=1
        elif [[ "$out" != '{"error":"app-not-running"}' ]]; then
            echo "码 2 载荷不符，实得: $out"; rc=1
        fi
    fi
    # 恢复现场：原有快照放回；原本就没有则清掉 fixture，保持"无 App 未产帧"原状
    if [[ $had_real -eq 1 ]]; then
        mv -f "$BACKUP" "$SNAPSHOT"
    else
        rm -f "$SNAPSHOT"
    fi
    [[ $rc -eq 0 ]] && echo "CLI 冒烟通过: --help 动词面 / status 码 0 / --json 无 App 码 2"
    return "$rc"
}

cd "$ROOT"
echo "状态管家全量回归（T-057）· $(date '+%F %T') · 日志 $LOG_DIR"
echo

run_step "swift build（debug）" swift build
run_step "swift build（release）" swift build -c release
run_step "swift test · 第 1 遍" swift test
run_step "swift test · 第 2 遍" swift test
run_step "build-app.sh release no-open（组包）" bash "$ROOT/scripts/build-app.sh" release no-open
run_step "dist 产物断言（Info.plist/可执行/ad-hoc 签名）" assert_dist_bundle
run_step "butler CLI 冒烟（--help/status 0/--json 无 App 2）" cli_smoke

echo
echo "════════ 回归摘要 ════════"
printf '%s\n' "${SUMMARY[@]}"
echo "通过 $PASS_COUNT / $FAIL_COUNT 失败 · 日志目录 $LOG_DIR"
[[ $FAIL_COUNT -eq 0 ]] && echo "全量回归：全绿 ✔"
[[ $FAIL_COUNT -eq 0 ]]
