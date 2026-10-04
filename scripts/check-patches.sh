#!/usr/bin/env bash
# 快速校验（CI 的 check job）：
#   1) patches/bsp/*.patch 能否干净应用到 pin 提交的 BSP 文件
#   2) 内核补丁 997 能否干净应用到「内核 + BSP 的 750/751 补丁」之上
# 不编译内核（那由 kernel.yml 负责）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/build/check}"
KVER="${KVER:-6.12.103}"
BSP_COMMIT="${BSP_COMMIT:-428fbc3b9920866daa5c1b2753849a6d49ed96ef}"
BSP_RAW="${BSP_RAW:-https://raw.githubusercontent.com/ChenMercy/immortalwrt/$BSP_COMMIT}"
KERNEL_TARBALL_URL="${KERNEL_TARBALL_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz}"

mkdir -p "$WORK"; cd "$WORK"
fail=0

echo "== [1/4] 取 BSP 被我们改动的文件（pin ${BSP_COMMIT}）"
mkdir -p bsp
fetch() { # fetch <仓库内路径> <本地路径>
	if [ -s "$2" ]; then echo "   复用 $2"; return; fi
	curl -fsSL "$BSP_RAW/$1" -o "$2" || { echo "!! 取不到 $1"; return 1; }
	echo "   $1 -> $2 ($(wc -c < "$2") B)"
}
fetch target/linux/generic/config-6.12                  bsp/target/linux/generic/config-6.12
fetch target/linux/mediatek/filogic/config-6.12         bsp/target/linux/mediatek/filogic/config-6.12
fetch target/linux/mediatek/dts/mt7987.dtsi             bsp/target/linux/mediatek/dts/mt7987.dtsi
fetch target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts bsp/target/linux/mediatek/dts/mt7987a-hiveton-h5000m.dts

echo "== [2/4] 校验 patches/bsp/*.patch"
for p in "$ROOT"/patches/bsp/*.patch; do
	if patch -p1 --dry-run -d bsp < "$p" >/dev/null 2>&1; then
		echo "   OK   $(basename "$p")"
		patch -p1 -d bsp < "$p" >/dev/null 2>&1
	else
		echo "   FAIL $(basename "$p")"; fail=1
	fi
done

echo "== [3/4] 取内核源码 $KVER"
if [ ! -d "linux-$KVER" ]; then
	if [ ! -s "linux-$KVER.tar.xz" ]; then
		curl -fL "$KERNEL_TARBALL_URL" -o "linux-$KVER.tar.xz"
	fi
	tar xf "linux-$KVER.tar.xz"
fi

echo "== [4/4] 校验内核补丁（先应用 BSP 的 750/751，再应用我们的 997/998）"
for f in 750-net-ethernet-mtk_eth_soc-add-mt7987-support.patch \
         751-net-ethernet-mtk_eth_soc-revise-hardware-configuration-for-mt7987.patch; do
	if [ ! -s "$f" ]; then curl -fsSL "$BSP_RAW/target/linux/mediatek/patches-6.12/$f" -o "$f"; fi
	if patch -p1 --dry-run -d "linux-$KVER" < "$f" >/dev/null 2>&1; then
		patch -p1 -d "linux-$KVER" < "$f" >/dev/null 2>&1; echo "   OK   (BSP) $f"
	else
		echo "   FAIL (BSP) $f"; fail=1
	fi
done
for p in "$ROOT/patches/kernel-997-h5000m-mt7987-eth-fixes.patch" \
         "$ROOT/patches/kernel-998-disable-gcc-plugins.patch"; do
	if patch -p1 --dry-run -d "linux-$KVER" < "$p" >/dev/null 2>&1; then
		echo "   OK   $(basename "$p")"
	else
		echo "   FAIL $(basename "$p")"; fail=1
	fi
done

echo
[ "$fail" = 0 ] && echo "== 全部补丁校验通过" || { echo "== 有补丁无法应用"; exit 1; }
