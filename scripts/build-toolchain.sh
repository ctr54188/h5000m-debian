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

# 失败时自动 -j1 V=s 重跑并打印最后 120 行，便于定位（CI 日志常被截断）
run_step() {
	local desc="$1"; shift
	echo "== $desc"
	if make -j"$JOBS" "$@"; then
		return 0
	fi
	echo "!!! $desc 失败，用 -j1 V=s 重跑以定位错误（只打印最后 120 行）"
	set +e
	make -j1 V=s "$@" 2>&1 | tail -120
	set -e
	return 1
}
echo "== [0/5] 安装 feeds（缺 feeds 会导致 .config 与源码树不同步）"
if [ ! -e "$BSP/feeds/luci" ] && [ ! -e "$BSP/feeds/packages" ]; then
	./scripts/feeds update -a
	./scripts/feeds install -a
else
	echo "   feeds 已就绪"
fi

echo "== [1/2] 主机工具"
run_step "[1/2] 主机工具" tools/install
echo "== [2/2] 交叉工具链"
# 缓存（staging_dir + build_dir）可能来自不同时刻，导致 make 认为部分组件要重编、
# 但依赖已被清掉 → 报错。这里失败就清干净重来一次（慢但可靠），成功则下次走缓存。
if ! run_step "[2/2] 交叉工具链" toolchain/install; then
	echo "!! 工具链构建失败，清理构建状态后重试一次（缓存可能不一致）"
	rm -rf build_dir/host build_dir/toolchain-* staging_dir/host* staging_dir/toolchain-* tmp
	run_step "[2/2] 交叉工具链（清理后重试）" toolchain/install
fi

