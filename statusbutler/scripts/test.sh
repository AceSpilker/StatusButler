#!/usr/bin/env bash
# 测试入口（T-001）: bash scripts/test.sh [过滤词]
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ $# -gt 0 ]]; then
    swift test --filter "$1"
else
    swift test
fi
