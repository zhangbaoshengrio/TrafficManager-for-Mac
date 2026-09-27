#!/usr/bin/env bash
# 编译 + 测试。CI 与本地共用同一入口。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ Swift: $(swift --version | head -1)"
echo "▸ 解析依赖"
swift package resolve
echo "▸ 编译 (release)"
swift build -c release
echo "▸ 运行测试"
swift test
echo "✓ 全部通过 — 产物: .build/release/TrafficMonitor"
echo "  打包成 .app: Scripts/make-app.sh"
