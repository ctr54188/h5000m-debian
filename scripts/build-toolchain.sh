#!/usr/bin/env bash
# 安装 feeds + 构建主机工具与交叉工具链（BSP 构建里最耗时的部分，CI 会缓存它）。
#   bsp/dl          —— 下载的源码包
#   bsp/staging_dir —— 已编好的主机工具与工具链
#   bsp/feeds       —— feeds 源码
# 幂等：已完成的步骤 make 会跳过。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BSP="${BSP_DIR:-$ROOT/bsp}"
JOBS="${1:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"
[ -d "$BSP" ] || { echo "缺少 BSP：$BSP" >&2; exit 1; }
"$ROOT/scripts/apply-bsp-patches.sh"
cd "$BSP"
echo "== [0/5] 安装 feeds（缺 feeds 会导致 .config 与源码树不同步）"
if [ ! -e "$BSP/feeds/luci" ] || [ ! -e "$BSP/feeds/packages" ]; then
	./scripts/feeds update -a
	./scripts/feeds install -a
else
	echo "   feeds 已就绪"
fi

echo "== [1/2] 主机工具"
run_step "[1/2] 主机工具" tools/install
echo "== [2/2] 交叉工具链"
run_step "[2/2] 交叉工具链" toolchain/install

