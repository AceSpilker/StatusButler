#!/usr/bin/env bash
# T-053 iDevice 电量 Helper 构建（代码半场）：按 Support/mobile-battery-dependencies.json
# 逐库 clone 并锁定到 manifest 钉死的 commit，源码构建 libimobiledevice 工具链，
# 最终产出 .build/mobile-battery/statusbutler-mobilebattery 与依赖清单副本。
# 依赖 libimobiledevice 系（LGPL-2.1-or-later / Apache-2.0）走"独立 helper 子进程 +
# 动态库随包分发"路线：主程序不链接这些库，License 边界与发布链都更干净。
# 为什么要求 macOS SDK ≥ 26：链接期依赖新版 clang/ld 的 rpath 处理，
# 老 SDK 产出的 dylib 在合并进 .app 时 install_name 修正不可靠（参考实现踩过的坑）。
# 真跑验证（含真机 USB 冒烟）留 T-053b；本脚本提供 --dry-run/--help 供 CI 契约测试钉住。
#
# 用法: bash scripts/build-mobile-battery-helper.sh [--dry-run]
#   --dry-run  只打印构建计划（六库名单/commit/产物路径），零副作用
#   --help     打印用法
# 环境变量: BUILD_JOBS（正整数，默认 hw.ncpu）
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/Support/mobile-battery-dependencies.json"
WORK="$ROOT/.build/mobile-battery"
HELPER_NAME="statusbutler-mobilebattery"
HELPER_SOURCES="$ROOT/Support/MobileBatteryHelper"
MINIMUM_MACOS="13.0"
DRY_RUN=0

usage() {
    cat <<'EOF'
用法: bash scripts/build-mobile-battery-helper.sh [--dry-run]
  --dry-run  打印构建计划后退出（不 clone、不编译、无文件副作用）
  --help     打印本说明
依赖清单: Support/mobile-battery-dependencies.json（六库 tag+commit 锁定）
产物: .build/mobile-battery/statusbutler-mobilebattery（helper 可执行）
      .build/mobile-battery/dependencies.json / dependency-locks.txt（依赖清单副本）
真跑前置: macOS SDK ≥ 26（xcrun --sdk macosx --show-sdk-version）、git、python3、pkg-config
EOF
}

# 参数白名单（Mimosa 防注入纪律，与 release-app.sh 同源）：只收已知旗标，
# 任何未知参数（含裸位置参数）先于一切文件/git/编译动作拒绝——不存在把用户输入
# 拼进命令行的路径
while (( $# > 0 )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --dry-run) DRY_RUN=1 ;;
        *) echo "错误: 未知参数 '$1'（白名单: --dry-run --help）" >&2; exit 2 ;;
    esac
    shift
done

BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
if ! [[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误: BUILD_JOBS 必须是正整数，收到 '$BUILD_JOBS'" >&2
    exit 2
fi

if [[ ! -f "$MANIFEST" ]]; then
    echo "错误: 依赖清单不存在: $MANIFEST" >&2
    exit 2
fi

# manifest 不是可信输入的反面——它是仓库内钉死的交付物；此处仍然按使用前校验纪律
# 过一遍形态（github https / 40 位 hex commit / tag 非空），坏清单在 clone 之前就拦下
read_manifest() {
    python3 - "$MANIFEST" <<'PY'
import json
import re
import sys

with open(sys.argv[1]) as handle:
    manifest = json.load(handle)
order = manifest.get("sourceBuildOrder") or []
entries = manifest.get("dependencies") or []
by_name = {entry.get("name"): entry for entry in entries}
problems = []
if not order or set(order) != set(by_name) or len(order) != len(set(order)):
    problems.append("sourceBuildOrder 与 dependencies 名单不一致")
for name in order:
    entry = by_name.get(name)
    if entry is None:
        continue
    if not str(entry.get("repository") or "").startswith("https://github.com/"):
        problems.append(f"{name}: repository 必须是 https://github.com/ 地址")
    if re.fullmatch(r"[0-9a-f]{40}", str(entry.get("commit") or "")) is None:
        problems.append(f"{name}: commit 必须是 40 位小写十六进制")
    if not entry.get("tag"):
        problems.append(f"{name}: 缺 tag")
if problems:
    for problem in problems:
        print(f"错误: 依赖清单校验失败: {problem}", file=sys.stderr)
    sys.exit(1)
for name in order:
    entry = by_name[name]
    print("\t".join((name, entry["repository"], entry["commit"], entry["tag"], str(entry["version"]))))
PY
}

PLAN="$(read_manifest)"

# SDK 探测放参数校验之后：--help/--bogus 路径不需要 Xcode 也不产生副作用
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
SDK_MAJOR=0
if [[ "$SDK_VERSION" =~ ^([0-9]+) ]]; then
    SDK_MAJOR="${BASH_REMATCH[1]}"
fi

if (( DRY_RUN )); then
    echo "[dry-run] 目标 SDK: ${SDK_VERSION}（要求 ≥ 26）；本机架构: $(uname -m)；并行度: ${BUILD_JOBS}"
    if (( SDK_MAJOR > 0 && SDK_MAJOR < 26 )); then
        echo "[dry-run] 注意: 当前 SDK < 26，真跑将在门禁处 exit 2"
    fi
    echo "[dry-run] 工作目录: ${WORK}"
    echo "[dry-run] helper 产物: ${WORK}/${HELPER_NAME}"
    if [[ -d "$HELPER_SOURCES" ]]; then
        echo "[dry-run] helper 源码: ${HELPER_SOURCES}（就绪）"
    else
        echo "[dry-run] helper 源码: ${HELPER_SOURCES}（缺失，T-053b 交付 Support/MobileBatteryHelper/*.m）"
    fi
    echo "[dry-run] 依赖（按构建顺序，tag+commit 双锁）:"
    while IFS=$'\t' read -r name repository commit tag version; do
        echo "[dry-run]   ${version}  ${name}  ${repository}  tag=${tag}  commit=${commit}"
    done <<< "$PLAN"
    echo "[dry-run] 构建序列: openssl(Configure) → libplist → libimobiledevice-glue → libusbmuxd → libtatsu → libimobiledevice(autotools)"
    echo "[dry-run] 产物清单: ${WORK}/${HELPER_NAME}  ${WORK}/dependencies.json  ${WORK}/dependency-locks.txt"
    exit 0
fi

# SDK ≥ 26 门禁（真跑）
if (( SDK_MAJOR < 26 )); then
    echo "错误: iDevice 电量 helper 需要 macOS SDK ≥ 26，当前 ${SDK_VERSION}" >&2
    exit 2
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  openssl_target="darwin64-arm64-cc";   host="aarch64-apple-darwin" ;;
    x86_64) openssl_target="darwin64-x86_64-cc";  host="x86_64-apple-darwin" ;;
    *) echo "错误: 不支持的架构: $ARCH" >&2; exit 2 ;;
esac

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES="$WORK/sources"
PREFIX="$WORK/prefix"

# 逐库取源并锁 commit：clone 一次常驻复用，每次构建 fetch+detach 到 manifest 钉的
# commit，rev-parse 回读不一致立即失败——供应链锁的可执行化，不赌 tag 可变性
mkdir -p "$SOURCES" "$PREFIX"
while IFS=$'\t' read -r name repository commit tag version; do
    source="$SOURCES/$name"
    if [[ ! -d "$source/.git" ]]; then
        git clone --filter=blob:none "$repository" "$source"
    fi
    git -C "$source" fetch --quiet origin "$commit"
    git -C "$source" checkout --quiet --detach "$commit"
    actual="$(git -C "$source" rev-parse HEAD)"
    if [[ "$actual" != "$commit" ]]; then
        echo "错误: ${name} 源码锁定校验失败: 期望 ${commit}，实得 ${actual}" >&2
        exit 1
    fi
done <<< "$PLAN"

export MACOSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS"
CLANG="$(xcrun --sdk macosx --find clang)"
CLANGXX="$(xcrun --sdk macosx --find clang++)"
export CC="$CLANG -arch $ARCH -isysroot $SDK_PATH"
export CXX="$CLANGXX -arch $ARCH -isysroot $SDK_PATH"
export CFLAGS="-O2 -arch $ARCH -isysroot $SDK_PATH -mmacosx-version-min=$MINIMUM_MACOS"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch $ARCH -isysroot $SDK_PATH -mmacosx-version-min=$MINIMUM_MACOS -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"

# openssl（Configure 体系，非 autotools）
(
    cd "$SOURCES/openssl"
    ./Configure "$openssl_target" shared no-tests --prefix="$PREFIX" --openssldir="$PREFIX/etc/ssl"
    make -j"$BUILD_JOBS"
    make install_sw
)

build_autotools() {
    local name="$1"
    shift
    local source="$SOURCES/$name"
    local build="$WORK/build/$name"
    mkdir -p "$build"
    ( cd "$source" && NOCONFIGURE=1 ./autogen.sh )
    ( cd "$build" && "$source/configure" --host="$host" --prefix="$PREFIX" --enable-shared --disable-static "$@" && make -j"$BUILD_JOBS" && make install )
}

build_autotools libplist --without-cython --without-tools --without-tests
build_autotools libimobiledevice-glue
build_autotools libusbmuxd --without-inotify
build_autotools libtatsu
build_autotools libimobiledevice --without-cython --without-readline --with-openssl

# helper 源码是 T-053b 交付物：缺失给可行动的错误，不做任何"顺手生成占位"的动作
if [[ ! -d "$HELPER_SOURCES" ]]; then
    echo "错误: helper 源码目录不存在: $HELPER_SOURCES（T-053b 交付 Support/MobileBatteryHelper/*.m）" >&2
    exit 2
fi

HELPER_CFLAGS="$(pkg-config --cflags libimobiledevice-1.0 libusbmuxd-2.0 libplist-2.0)"
HELPER_LIBS="$(pkg-config --libs libimobiledevice-1.0 libusbmuxd-2.0 libplist-2.0)"
"$CLANG" $CFLAGS -fobjc-arc -O2 -I"$PREFIX/include" \
    $HELPER_CFLAGS \
    "$HELPER_SOURCES"/*.m \
    $HELPER_LIBS \
    -framework Foundation -framework CoreFoundation \
    -Wl,-rpath,"$PREFIX/lib" -Wl,-headerpad_max_install_names \
    -o "$WORK/$HELPER_NAME"
chmod 755 "$WORK/$HELPER_NAME"

# 依赖清单副本随产物落盘：排查现场版本 / License 审计都不用回溯 git 历史
cp "$MANIFEST" "$WORK/dependencies.json"
while IFS=$'\t' read -r name repository commit tag version; do
    printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$tag" "$commit"
done <<< "$PLAN" > "$WORK/dependency-locks.txt"

echo "已构建 helper: $WORK/$HELPER_NAME"
echo "依赖清单: $WORK/dependencies.json  $WORK/dependency-locks.txt"
