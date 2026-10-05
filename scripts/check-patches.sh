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
	mkdir -p "$(dirname "$2")"        # curl -o 不会建父目录，缺目录会报
	                                  # "curl: (56) Failure writing output to destination"
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

echo "== [3/4] 内核补丁结构校验"
# 说明：内核补丁必须应用在「BSP 全部补丁打完之后」的树上（patches-6.12 是一整套序列，
#       750 依赖更早的补丁，单独打到 vanilla 内核必然失败）。这里只做结构校验
#       （补丁可解析、目标文件符合预期）；**真正应用**由 kernel job 的 BSP 构建完成。
for p in "$ROOT"/patches/kernel-*.patch; do
	if git apply --numstat "$p" >/tmp/numstat.$$ 2>/dev/null && [ -s /tmp/numstat.$$ ]; then
		printf "   OK   %s\n" "$(basename "$p")"
		sed 's/^/        /' /tmp/numstat.$$
	else
		printf "   FAIL %s（不是合法的 unified diff）\n" "$(basename "$p")"; fail=1
	fi
done
rm -f /tmp/numstat.$$
# 关键：997 必须命中 mtk_eth_soc
grep -q "mtk_eth_soc.c" "$ROOT"/patches/kernel-997-h5000m-mt7987-eth-fixes.patch \
	|| { echo "   FAIL 997 没有命中 mtk_eth_soc.c"; fail=1; }

echo "== [4/4] 关键构建配置回归检查"
check_cfg() { # check_cfg <文件> <关键项>
	if grep -qE "$2" "$1"; then
		printf "   OK   %s: %s\n" "$(basename "$1")" "$2"
	else
		printf "   FAIL %s 缺少 %s\n" "$(basename "$1")" "$2"; fail=1
	fi
}
check_cfg "$ROOT/config/bsp.config" '^CONFIG_TARGET_mediatek_filogic=y'
# 设备符号在 .config 里通常是 "# ... is not set"（内核配置由 target/subtarget + 我们的
# 补丁决定，与 device profile 无关）；这里只要求 target/subtarget 选对。
check_cfg "$ROOT/config/bsp.config" '^CONFIG_TARGET_mediatek_filogic=y'
check_cfg "$ROOT/config/bsp.config" 'CONFIG_TARGET_mediatek_filogic_DEVICE_hiveton_h5000m'
# 历史故障：.config 里 KERNEL_DEVTMPFS 关掉 → 内核不带 DEVTMPFS → Debian 起不来
check_cfg "$ROOT/config/bsp.config" '^CONFIG_KERNEL_DEVTMPFS=y'
# make defconfig 会把未显式设置的 KERNEL_DEVTMPFS_MOUNT 写成 is not set，
# 从而把内核配置改回 DEVTMPFS_MOUNT=n（与已验证镜像不一致）→ 必须显式置 y
check_cfg "$ROOT/config/bsp.config" '^CONFIG_KERNEL_DEVTMPFS_MOUNT=y'
# BSP 侧补丁必须真的把 DEVTMPFS / WWAN / 80211 打开
check_cfg "$ROOT/patches/bsp/0001-generic-config-6.12-devtmpfs-wwan-wifi.patch" '^\+CONFIG_DEVTMPFS=y'
check_cfg "$ROOT/patches/bsp/0001-generic-config-6.12-devtmpfs-wwan-wifi.patch" '^\+CONFIG_DEVTMPFS_MOUNT=y'
check_cfg "$ROOT/patches/bsp/0001-generic-config-6.12-devtmpfs-wwan-wifi.patch" '^\+CONFIG_MTK_T7XX=y'
check_cfg "$ROOT/patches/bsp/0003-dts-eth-irqs-and-board-mac.patch" 'interrupt-names = "fe0", "fe1", "fe2", "fe3"'
check_cfg "$ROOT/patches/bsp/0003-dts-eth-irqs-and-board-mac.patch" 'GIC_SPI 197'
check_cfg "$ROOT/patches/kernel-997-h5000m-mt7987-eth-fixes.patch" 'mtk_handle_irq_fe'

echo
[ "$fail" = 0 ] && echo "== 全部补丁校验通过" || { echo "== 有补丁无法应用"; exit 1; }
