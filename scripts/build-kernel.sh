#!/usr/bin/env bash
# 在 BSP 内构建内核 + 模块 + DTB，产物收集到 out/kernel/。
# 首次运行需先编 tools/ 与 toolchain/（本机 4 核约 40~90 分钟）。
# 用法：scripts/build-kernel.sh [jobs]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BSP="${BSP_DIR:-$ROOT/bsp}"
JOBS="${1:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"
OUT="${OUT_DIR:-$ROOT/out}/kernel"
KVER="${KVER:-6.12.103}"

[ -d "$BSP" ] || { echo "缺少 BSP：$BSP" >&2; exit 1; }
"$ROOT/scripts/apply-bsp-patches.sh"

cd "$BSP"
echo "== [1/4] 主机工具"
make -j"$JOBS" tools/install
echo "== [2/4] 交叉工具链"
make -j"$JOBS" toolchain/install
echo "== [3/4] 内核 + DTB"
make -j"$JOBS" target/linux/compile
make -j"$JOBS" target/linux/install
echo "== [4/4] 内核模块"
make -j"$JOBS" package/kernel/linux/compile
make -j"$JOBS" package/kernel/linux/install

mkdir -p "$OUT"
BD="$(ls -d "$BSP"/build_dir/target-*/linux-*/linux-"$KVER" | head -1)"
echo "== 收集产物（${BD}）"
cp "$BD/arch/arm64/boot/Image" "$OUT/Image"
find "$BD/arch/arm64/boot/dts" -name 'mt7987a-hiveton-h5000m.dtb' -exec cp {} "$OUT/board.dtb" \;
find "$BD" -name '*.ko' > "$OUT/modules.list"
( cd "$BD" && tar czf "$OUT/modules-${KVER}.tar.gz" $(sed "s|$BD/||" "$OUT/modules.list") )
cp "$BD/.config" "$OUT/kernel.config"
ls -lh "$OUT" | sed -n '2,9p'
echo "模块数：$(wc -l < "$OUT/modules.list")"
echo "提示：/lib/firmware 不在内核产物里，可用 OWROOT=<openwrt-rootfs> 传给 scripts/build-rootfs.sh"
