#!/usr/bin/env bash
# 拉取 MT7987 BSP（ImmortalWrt）到 bsp/，pin 到已验证提交。
#   BSP_REPO / BSP_COMMIT / BSP_DIR 可覆盖。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BSP="${BSP_DIR:-$ROOT/bsp}"
BSP_REPO="${BSP_REPO:-https://github.com/ChenMercy/immortalwrt.git}"
BSP_COMMIT="${BSP_COMMIT:-428fbc3b9920866daa5c1b2753849a6d49ed96ef}"   # openwrt-25.12 / 2026-08-30

if [ -d "$BSP/.git" ]; then
	echo "== 复用已有 $BSP"
	git -C "$BSP" fetch origin "$BSP_COMMIT" 2>/dev/null || git -C "$BSP" fetch origin
else
	echo "== 克隆 $BSP_REPO -> $BSP"
	git clone --filter=blob:none "$BSP_REPO" "$BSP"
fi
git -C "$BSP" checkout --force "$BSP_COMMIT"
git -C "$BSP" log -1 --format='   %h %ad %s' --date=short
echo "== 提示：完整 image 构建还需 feeds（$BSP/scripts/feeds update -a && install -a）"
