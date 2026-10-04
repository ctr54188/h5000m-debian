#!/usr/bin/env bash
# 打包可刷写镜像（U-Boot 网页 Firmware 上传用）：
#   sysupgrade tar = CONTROL + kernel(FIT) + root(rootfs.ext4)
#
# 输入：
#   out/kernel/Image, out/kernel/board.dtb   （scripts/build-kernel.sh 产物，或自行指定）
#   rootfs/ 目录                              （scripts/build-rootfs.sh 产物）
# 依赖：u-boot-tools(mkimage/fdtput)、device-tree-compiler、e2fsprogs
#
# 用法：
#   IMAGE=/path/Image DTB=/path/board.dtb scripts/package-image.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="${ROOTFS_DIR:-$ROOT/rootfs}"
IMAGE="${IMAGE:-$ROOT/out/kernel/Image}"
DTB="${DTB:-$ROOT/out/kernel/board.dtb}"
OUT="${OUT_DIR:-$ROOT/out}/image-$(date +%Y%m%d-%H%M%S)"
BOARD="${BOARD:-hiveton,h5000m}"
ROOTFS_SIZE="${ROOTFS_SIZE:-805306368}"     # 768 MiB，与网页升级槽位一致
ROOTFS_LABEL="${ROOTFS_LABEL:-rootfs}"
BOOTARGS="${BOOTARGS:-console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x11000000 root=PARTLABEL=$ROOTFS_LABEL rootwait rootfstype=ext4 ro pci=pcie_bus_perf}"

[ -f "$IMAGE" ] || { echo "缺少内核 Image：$IMAGE" >&2; exit 1; }
[ -f "$DTB" ]   || { echo "缺少 board.dtb：$DTB" >&2; exit 1; }
[ -d "$R" ]     || { echo "缺少 rootfs：$R" >&2; exit 1; }
for t in mkimage fdtput mkfs.ext4 e2fsck; do command -v "$t" >/dev/null || { echo "缺少工具：$t" >&2; exit 1; }; done

mkdir -p "$OUT"
cp "$IMAGE" "$OUT/Image"
cp "$DTB" "$OUT/board.dtb"
cp "${KERNEL_CONFIG:-$ROOT/out/kernel/kernel.config}" "$OUT/kernel.config" 2>/dev/null || true

echo "== [1/5] 写入 bootargs"
fdtput -t s "$OUT/board.dtb" /chosen bootargs "$BOOTARGS"

echo "== [2/5] 生成 kernel.itb（FIT：kernel + fdt + sha256）"
cat > "$OUT/kernel.its" <<ITS
/dts-v1/;
/ {
 description = "H5000M Debian 13 kernel";
 #address-cells = <1>;
 images {
  kernel-1 {
   description = "Linux 6.12.103";
   data = /incbin/("$OUT/Image");
   type = "kernel"; arch = "arm64"; os = "linux";
   compression = "none"; load = <0x40000000>; entry = <0x40000000>;
   hash-1 { algo = "sha256"; };
  };
  fdt-1 {
   description = "mt7987a-hiveton-h5000m";
   data = /incbin/("$OUT/board.dtb");
   type = "flat_dt"; arch = "arm64"; compression = "none";
   hash-1 { algo = "sha256"; };
  };
 };
 configurations {
  default = "conf-1";
  conf-1 { description = "H5000M"; kernel = "kernel-1"; fdt = "fdt-1"; };
 };
};
ITS
mkimage -f "$OUT/kernel.its" "$OUT/kernel.itb" > "$OUT/fit-inspection.txt"

echo "== [3/5] 生成 rootfs.ext4（$ROOTFS_SIZE 字节，label=${ROOTFS_LABEL}）"
truncate -s "$ROOTFS_SIZE" "$OUT/root.part"
mkfs.ext4 -F -L "$ROOTFS_LABEL" -d "$R" "$OUT/root.part" > "$OUT/mkfs.log" 2>&1
e2fsck -fn "$OUT/root.part" > "$OUT/fsck.log" 2>&1 || true

echo "== [4/5] 组装 sysupgrade tar"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
dir="sysupgrade-hiveton_h5000m"
mkdir -p "$stage/$dir"
printf 'BOARD=%s\n' "$BOARD" > "$stage/$dir/CONTROL"
cp "$OUT/kernel.itb" "$stage/$dir/kernel"
cp "$OUT/root.part"  "$stage/$dir/root"
( cd "$stage" && tar --format=ustar -cf "$OUT/debian-13-h5000m.bin" "$dir/CONTROL" "$dir/kernel" "$dir/root" )

echo "== [5/5] 校验与哈希"
( cd "$OUT" && sha256sum debian-13-h5000m.bin > debian-13-h5000m.bin.sha256 \
  && sha256sum Image board.dtb kernel.itb root.part > artifacts.sha256 \
  && sha256sum -c debian-13-h5000m.bin.sha256 )
rm -f "$OUT/root.part"
echo
echo "== 产物目录：$OUT"
ls -l "$OUT"
echo
echo "刷写：U-Boot 网页 → Firmware → 上传 debian-13-h5000m.bin（仅此项，勿刷 BL2/FIP/GPT）"
