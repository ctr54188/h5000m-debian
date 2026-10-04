#!/usr/bin/env bash
# 把本仓库的全部改动打到 BSP 上（幂等）：
#   patches/bsp/*.patch        → BSP 的 config-6.12 与 DTS（以太网 8 条中断 + 板级 MAC）
#   patches/kernel-997-*.patch → target/linux/mediatek/patches-6.12/（mtk_eth_soc TX 修复）
#   patches/kernel-998-*.patch → 同上（GCC plugins 默认关闭，构建环境相关）
#   config/bsp.config          → BSP 的 .config（复现同一套内核配置）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BSP="${BSP_DIR:-$ROOT/bsp}"
[ -d "$BSP/target/linux/mediatek" ] || { echo "缺少 BSP：${BSP}（先跑 scripts/fetch-bsp.sh）" >&2; exit 1; }

apply() {
	if git -C "$BSP" apply --reverse --check "$1" 2>/dev/null; then
		echo "== 已应用，跳过：$2"
	else
		echo "== 应用：$2"
		git -C "$BSP" apply -p1 "$1"
	fi
}

for p in "$ROOT"/patches/bsp/*.patch; do apply "$p" "bsp/$(basename "$p")"; done

echo "== 内核补丁 → target/linux/mediatek/patches-6.12/"
install -m0644 "$ROOT/patches/kernel-997-h5000m-mt7987-eth-fixes.patch" \
	"$BSP/target/linux/mediatek/patches-6.12/997-h5000m-mt7987-eth-fixes.patch"
install -m0644 "$ROOT/patches/kernel-998-disable-gcc-plugins.patch" \
	"$BSP/target/linux/mediatek/patches-6.12/998-disable-gcc-plugins.patch"

if [ -f "$ROOT/config/bsp.config" ]; then
	echo "== 写入构建配置 .config"
	cp "$ROOT/config/bsp.config" "$BSP/.config"
fi
echo "== 完成"
