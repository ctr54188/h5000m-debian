#!/usr/bin/env bash
# 在 BSP 内构建内核 + 模块 + DTB，产物收集到 out/kernel/。
# 前置：先跑 scripts/build-toolchain.sh（或 make toolchain）。
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

# 失败时自动用 -j1 V=s 重跑一次，把真正的报错打到日志里。
# 原因：并行构建的输出里，真正的错误往往被淹没/截断（CI 上曾只看到
#      "ERROR: target/linux failed to build" 而看不到根因）。
run_step() { # run_step <说明> <make 目标...>
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

echo "== [1/3] 对齐 .config（feeds 安装后重新解析，消除 out-of-sync）"
make defconfig

echo "== [2/3] 内核 + DTB"
run_step "[2/3] 内核 + DTB" target/linux/compile
echo "== [3/3] 内核模块"
run_step "[3/3] 内核模块" package/kernel/linux/compile

mkdir -p "$OUT"
BD="$(ls -d "$BSP"/build_dir/target-*/linux-*/linux-"$KVER" 2>/dev/null | head -1 || true)"
echo "== 收集产物（${BD}）"
cp "$BD/arch/arm64/boot/Image" "$OUT/Image"
# 板级 DTB 的取法（两级）：
#   1) OpenWrt 会把 target/linux/mediatek/dts/*.dts 编成 build_dir/<target>/image-<name>.dtb
#      —— 但只在设备 profile 被选中时才编，所以不一定存在；
#   2) 兜底：直接用内核树里的 dtc 编我们自己的 DTS（等价于 OpenWrt 的那条命令）。
DTB="$(ls "$BSP"/build_dir/target-*/linux-mediatek_filogic/image-*hiveton-h5000m*.dtb 2>/dev/null | head -1 || true)"
if [ -z "$DTB" ]; then
	echo "   未在 build_dir 找到板级 DTB，直接用内核 dtc 编译 target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts"
	DTS="$BSP/target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts"
	[ -f "$DTS" ] || { echo "!! 找不到 DTS：$DTS" >&2; exit 1; }
	CPP="$(ls "$BSP"/staging_dir/toolchain-*/bin/*-openwrt-linux-musl-cpp 2>/dev/null | head -1 || true)"
	[ -n "$CPP" ] || CPP="$(command -v cpp)"
	"$CPP" -nostdinc -x assembler-with-cpp \
		-I"$BD/arch/arm64/boot/dts/mediatek" -I"$BD/arch/arm64/boot/dts/mediatek/include" \
		-I"$BD/include" -I"$BD/scripts/dtc/include-prefixes" \
		-undef -D__DTS__ -o "$OUT/board.dtb.dts" "$DTS"
	"$BD/scripts/dtc/dtc" -O dtb -i"$BSP/target/linux/mediatek/dts/" \
		-Wno-interrupt_provider -Wno-unique_unit_address -Wno-unit_address_vs_reg \
		-Wno-avoid_unnecessary_addr_size -Wno-alias_paths -Wno-graph_child_address \
		-Wno-simple_bus_reg -@ -o "$OUT/board.dtb" "$OUT/board.dtb.dts"
	rm -f "$OUT/board.dtb.dts"
	DTB="$OUT/board.dtb"
fi
[ -n "$DTB" ] && [ -f "$DTB" ] || { echo "!! 没能得到板级 DTB" >&2; exit 1; }
if [ "$(readlink -f "$DTB" 2>/dev/null || echo "$DTB")" != "$(readlink -f "$OUT/board.dtb" 2>/dev/null || echo "$OUT/board.dtb")" ]; then
	cp -f "$DTB" "$OUT/board.dtb"
fi
echo "   DTB: $OUT/board.dtb ($(wc -c < "$OUT/board.dtb") B)"

find "$BD" -name '*.ko' > "$OUT/modules.list"
( cd "$BD" && tar czf "$OUT/modules-${KVER}.tar.gz" $(sed "s|$BD/||" "$OUT/modules.list") )
cp "$BD/.config" "$OUT/kernel.config"
ls -lh "$OUT" | sed -n '2,9p'
echo "模块数：$(wc -l < "$OUT/modules.list")"
echo "提示：/lib/firmware 不在内核产物里，可用 OWROOT=<openwrt-rootfs> 传给 scripts/build-rootfs.sh"
