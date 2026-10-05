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
echo "== [3/4] 内核模块（内核内建 + kmod 包）"
run_step "[3/4] 内核模块" package/kernel/linux/compile

echo "== [4/4] 无线栈（mt76 驱动 + MT7992 固件）"
# 说明：有线 HNAT/PPE 走主线 mtk_eth_soc（无需厂商 mtkhnat/mtk_wed 模块）；
#       无线 WED 是闭源厂商引擎（不可移植），rootfs 里已显式 wed_enable=0。
if [ -d "$BSP/package/kernel/mt76" ]; then
	run_step "[4/4] mt76 驱动与固件" package/kernel/mt76/compile
else
	echo "   !! BSP 里没有 package/kernel/mt76 —— 跳过（Wi-Fi 将不可用）"
fi

mkdir -p "$OUT"
BD="$(ls -d "$BSP"/build_dir/target-*/linux-*/linux-"$KVER" 2>/dev/null | head -1 || true)"
[ -n "$BD" ] || { echo "!! 找不到内核构建目录" >&2; exit 1; }
cp "$BD/arch/arm64/boot/Image" "$OUT/Image"

# ---- 板级 DTB（两级取法）
#   1) OpenWrt 会把 target/linux/mediatek/dts/*.dts 编成 build_dir/<target>/image-<name>.dtb
#      —— 但只有设备 profile 被选中时才编，所以不一定存在；
#   2) 兜底：直接用内核树里的 dtc 编我们自己的 DTS（等价于 OpenWrt 的那条命令）。
DTB="$(ls "$BSP"/build_dir/target-*/linux-mediatek_filogic/image-*hiveton-h5000m*.dtb 2>/dev/null | head -1 || true)"
if [ -z "$DTB" ]; then
	echo "   未在 build_dir 找到板级 DTB，改用内核 dtc 直接编译 target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts"
	DTS="$BSP/target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts"
	[ -f "$DTS" ] || { echo "!! 找不到 DTS：$DTS" >&2; exit 1; }
	CPP="$(ls "$BSP"/staging_dir/toolchain-*/bin/*-openwrt-linux-musl-cpp 2>/dev/null | head -1 || true)"
	[ -n "$CPP" ] || CPP="$(command -v cpp)"
	[ -n "$CPP" ] || { echo "!! 找不到 C 预处理器（cpp）" >&2; exit 1; }
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
if [ "$(readlink -f "$DTB" 2>/dev/null || echo "$DTB")" != "$(readlink -f "$OUT/board.dtb" 2>/dev/null || echo "$OUT/board.dtb")" ]; then
	cp -f "$DTB" "$OUT/board.dtb"
fi
echo "   板级 DTB：$OUT/board.dtb ($(wc -c < "$OUT/board.dtb") 字节)"

# ---- 模块：内核内建 + kmod 包（.pkgdir 是每个包的安装布局，compile 后即存在）
# 设备上模块是平铺的（/lib/modules/<kver>/<name>.ko），与已验证镜像一致
MODDIR="$OUT/.mods/lib/modules/$KVER"
rm -rf "$OUT/.mods"; mkdir -p "$MODDIR"
find "$BD" -name '*.ko' 2>/dev/null | while read -r f; do cp -n "$f" "$MODDIR/" 2>/dev/null || true; done
find "$BSP"/build_dir/target-* -path '*.pkgdir*' -name '*.ko' 2>/dev/null \
	| while read -r f; do cp -n "$f" "$MODDIR/" 2>/dev/null || true; done
( cd "$OUT/.mods" && tar czf "$OUT/modules-${KVER}.tar.gz" . )
find "$MODDIR" -name '*.ko' > "$OUT/modules.list"
echo "   模块数：$(wc -l < "$OUT/modules.list")"
for m in mt7996e mt76 mt76-connac-lib cfg80211 mac80211 cdc_ncm option qmi_wwan pwm_fan; do
	if [ -f "$MODDIR/$m.ko" ]; then echo "     ✓ $m.ko"; else echo "     ✗ 缺 $m.ko"; fi
done
rm -rf "$OUT/.mods"

# ---- 固件：包安装布局 + linux-firmware 的 mediatek 子树
FW="$OUT/.fw"
rm -rf "$FW"; mkdir -p "$FW"
find "$BSP"/build_dir/target-* -path '*.pkgdir*' -path '*lib/firmware*' -type f 2>/dev/null \
	| while read -r f; do
		rel="${f##*lib/firmware/}"
		mkdir -p "$FW/$(dirname "$rel")"; cp -n "$f" "$FW/$rel" 2>/dev/null || true
	done
LFW="$(ls -d "$BSP"/build_dir/target-*/linux-firmware-* 2>/dev/null | head -1 || true)"
if [ -n "$LFW" ] && [ -d "$LFW/mediatek" ]; then
	mkdir -p "$FW/mediatek"
	cp -rn "$LFW/mediatek/." "$FW/mediatek/" 2>/dev/null || true
fi
if [ -d "$FW/mediatek" ] || [ -n "$(find "$FW" -type f 2>/dev/null | head -1)" ]; then
	( cd "$FW" && tar czf "$OUT/firmware.tar.gz" . )
	echo "   固件：$(find "$FW" -type f | wc -l) 个文件 → firmware.tar.gz"
	for f in mt7992_wm_23.bin mt7992_eeprom_23_2i5i.bin mt7992_rom_patch_23.bin mt7992_wa_23.bin mt7992_dsp_23.bin; do
		[ -f "$FW/mediatek/mt7996/$f" ] && echo "     ✓ $f" || echo "     ✗ 缺 $f"
	done
else
	echo "   !! 没有收集到固件（无线的固件/校准会缺失）"
fi
rm -rf "$FW"

# ---- 产物完整性硬校验（缺任何一项都直接失败，别让残缺 artifact 静默上传）
missing=0
for f in Image board.dtb "modules-${KVER}.tar.gz" modules.list; do
	if [ ! -s "$OUT/$f" ]; then echo "!! 缺少产物：out/kernel/$f" >&2; missing=1; fi
done
[ -s "$OUT/firmware.tar.gz" ] || echo "   （提示：没有 firmware.tar.gz，Wi-Fi 固件将缺失）" >&2
[ "$missing" = 0 ] || exit 1
ls -lh "$OUT" | sed -n '2,12p'
echo "模块数：$(wc -l < "$OUT/modules.list")"
echo "提示：/lib/firmware 不在内核产物里，可用 OWROOT=<openwrt-rootfs> 传给 scripts/build-rootfs.sh"
