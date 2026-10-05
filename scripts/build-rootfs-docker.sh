#!/usr/bin/env bash
# 用 arm64 原生 Docker 构建 Debian rootfs（比 x86_64 + qemu 快一个数量级）。
#
# 思路：所有会改文件系统的步骤都在容器里做（容器内是 root，无需 sudo、无权限问题），
#       最后 `docker export` 成 rootfs 树；导出后只做只读操作（或按需 chown）。
#
# 用法：
#   scripts/build-rootfs-docker.sh
#   BASE_IMAGE=debian:trixie-slim scripts/build-rootfs-docker.sh
#   PANEL_TARBALL=/path/h5000m-mt5700-panel-*.tar.gz scripts/build-rootfs-docker.sh
#   OWROOT=/path/openwrt-rootfs scripts/build-rootfs-docker.sh   # 附带内核模块/firmware
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="${ROOTFS_DIR:-$ROOT/rootfs}"
KVER="${KVER:-6.12.103}"
BASE_IMAGE="${BASE_IMAGE:-debian:trixie}"
PLATFORM="${PLATFORM:-linux/arm64}"
C="${CONTAINER_NAME:-h5000m-rootfs-build}"
PANEL_TARBALL="${PANEL_TARBALL:-}"
OWROOT="${OWROOT:-}"

PKGS="systemd systemd-sysv systemd-resolved udev dbus kmod \
iproute2 iputils-ping ethtool net-tools nftables \
openssh-server \
e2fsprogs f2fs-tools dosfstools parted gdisk \
procps psmisc less nano htop bash-completion \
curl wget ca-certificates rsync \
usbutils pciutils \
iw wireless-regdb wpasupplicant hostapd iperf3 \
chrony zstd xz-utils file"

cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== [1/6] 启动容器（$BASE_IMAGE / $PLATFORM）"
cleanup
docker run -d --name "$C" --platform "$PLATFORM" "$BASE_IMAGE" sleep infinity >/dev/null
echo "   容器架构: $(docker exec "$C" uname -m)"

echo "== [2/6] 安装软件包（原生速度）"
docker exec "$C" bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $PKGS"
docker exec "$C" bash -c 'apt-get -qq clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/*'

echo "== [3/6] 板级 overlay + 面板（必须在板级配置之前铺好）"
# 注意：Docker 会把 /etc/hostname、/etc/hosts、/etc/resolv.conf 绑定挂载进容器，
# 用 docker cp 直接覆盖会报 "unlinkat /etc/hostname: device or resource busy"。
# 因此先拷到容器内临时目录，删掉这三个文件再 cp -a 到根（内容由板级配置脚本写入）。
docker cp "$ROOT/rootfs-overlay/." "$C:/tmp/overlay"
docker exec "$C" bash -c '
set -e
cd /tmp/overlay
rm -f etc/hostname etc/hosts etc/resolv.conf
cp -a . /
rm -rf /tmp/overlay
'
if [ -n "$PANEL_TARBALL" ] && [ -f "$PANEL_TARBALL" ]; then
	docker cp "$PANEL_TARBALL" "$C:/tmp/panel.tgz"
	docker exec "$C" tar xzf /tmp/panel.tgz -C / && docker exec "$C" rm -f /tmp/panel.tgz
	echo "   面板：$(basename "$PANEL_TARBALL")"
else
	echo "   （未提供 PANEL_TARBALL，跳过面板）"
fi
docker exec "$C" bash -c 'chmod 0755 /usr/local/sbin/h5000m-* 2>/dev/null || true'

echo "== [4/6] 板级配置（主机名/用户/静态 /dev/串口/启用 systemd 单元）"
docker cp "$ROOT/scripts/rootfs-board-config.sh" "$C:/tmp/board-config.sh"
docker exec -e KVER="$KVER" "$C" bash /tmp/board-config.sh | sed 's/^/   /'
docker exec "$C" bash -c 'ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true'

echo "== [5/6] 导出 rootfs"
mkdir -p "$ROOT/build"
docker export "$C" -o "$ROOT/build/rootfs.tar"
rm -rf "$R"; mkdir -p "$R"
tar xf "$ROOT/build/rootfs.tar" -C "$R"
rm -f "$ROOT/build/rootfs.tar"
echo "   $(du -sh "$R" | cut -f1) → $R"

echo "== 导出后自检（关键文件 / 启用软链）"
miss=0
for f in etc/hostname etc/hosts etc/fstab etc/nftables.conf \
         etc/hostapd/ap5g.conf etc/hostapd/ap24.conf \
         etc/systemd/network/07-br0.network etc/systemd/network/30-modem.network \
         usr/local/sbin/h5000m-firstboot.sh usr/local/sbin/h5000m-wifi-vif.sh \
         usr/local/sbin/h5000m-5g-width.sh \
         etc/systemd/system/multi-user.target.wants/systemd-networkd.service \
         etc/systemd/system/multi-user.target.wants/nftables.service \
         etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service; do
	[ -e "$R/$f" ] || { echo "   ✗ 缺 $f" >&2; miss=1; }
done
[ "$miss" = 0 ] && echo "   ✓ 全部关键文件在位" || { echo "!! rootfs 自检未通过" >&2; exit 1; }

echo "== [6/6] 内核模块 / 固件（可选，来自 OWROOT）"
if [ -n "$OWROOT" ]; then
	sudo=""; [ "$(id -u)" != 0 ] && command -v sudo >/dev/null && sudo=sudo
	if [ -d "$OWROOT/lib/modules/$KVER" ]; then
		$sudo mkdir -p "$R/lib/modules"; $sudo cp -a "$OWROOT/lib/modules/$KVER" "$R/lib/modules/"
		echo "   模块：$(find "$R/lib/modules/$KVER" -name '*.ko' | wc -l) 个"
	fi
	if [ -d "$OWROOT/lib/firmware" ]; then
		$sudo mkdir -p "$R/lib/firmware"
		$sudo cp -a --remove-destination "$OWROOT/lib/firmware/." "$R/lib/firmware/" 2>/dev/null || true
	fi
else
	echo "   （未提供 OWROOT；模块/固件由 CI 的 package job 从内核产物装入）"
fi
[ -f "$R/etc/resolv.conf" ] || ln -sf /run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
echo "== 完成：$R（$(du -sh "$R" | cut -f1)）"
