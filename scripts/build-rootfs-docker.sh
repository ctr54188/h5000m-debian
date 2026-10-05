#!/usr/bin/env bash
# 用 arm64 原生 Docker 构建 Debian rootfs。
#
# 为什么：原来在 x86_64 runner 上跑 `debootstrap --foreign` + qemu 二阶段 + chroot apt，
# 仿真下装 200MB 包要 1~1.5 小时。改成「arm64 runner + arm64 容器」后 apt 是原生速度，
# 整步约 3~6 分钟。
#
# 用法：
#   scripts/build-rootfs-docker.sh                      # 用 debian:trixie
#   BASE_IMAGE=debian:trixie-slim ...                   # 自定义基础镜像
#   PANEL_TARBALL=/path/panel.tar.gz ...                # 顺便装面板
#   OWROOT=/path/openwrt-rootfs ...                     # 顺便装内核模块与固件
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="${ROOTFS_DIR:-$ROOT/rootfs}"
KVER="${KVER:-6.12.103}"
BASE_IMAGE="${BASE_IMAGE:-debian:trixie}"
PLATFORM="${PLATFORM:-linux/arm64}"
C="${CONTAINER_NAME:-h5000m-rootfs-build}"
PANEL_TARBALL="${PANEL_TARBALL:-}"
OWROOT="${OWROOT:-}"

PKGS="systemd systemd-sysv udev dbus kmod \
iproute2 iputils-ping ethtool net-tools nftables \
openssh-server \
e2fsprogs f2fs-tools dosfstools parted gdisk \
procps psmisc less nano htop bash-completion \
curl wget ca-certificates rsync \
usbutils pciutils \
iw wireless-regdb wpasupplicant hostapd iperf3 \
chrony zstd xz-utils file"

echo "== [1/6] 启动容器（$BASE_IMAGE / $PLATFORM）"
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" --platform "$PLATFORM" "$BASE_IMAGE" sleep infinity >/dev/null
docker exec "$C" uname -m | sed 's/^/   容器架构: /'

echo "== [2/6] 安装软件包（原生速度）"
docker exec "$C" bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $PKGS"
docker exec "$C" bash -c 'apt-get -qq clean && rm -rf /var/lib/apt/lists/* /var/cache/apt/*'

echo "== [3/6] 导出 rootfs"
mkdir -p "$ROOT/build"
docker export "$C" -o "$ROOT/build/rootfs.tar"
rm -rf "$R"; mkdir -p "$R"
tar xf "$ROOT/build/rootfs.tar" -C "$R"
rm -f "$ROOT/build/rootfs.tar"
echo "   $(du -sh "$R" | cut -f1) → $R"

echo "== [4/6] 板级 overlay + 面板（必须先铺，板级配置才能启用这些单元）"
cp -a "$ROOT/rootfs-overlay/." "$R/"
chmod 0755 "$R/usr/local/sbin/"h5000m-* 2>/dev/null || true
if [ -n "$PANEL_TARBALL" ] && [ -f "$PANEL_TARBALL" ]; then
	tar xzf "$PANEL_TARBALL" -C "$R"
	echo "   面板：$(basename "$PANEL_TARBALL")"
else
	echo "   （未提供 PANEL_TARBALL，跳过面板）"
fi

echo "== [5/6] 板级配置（主机名/用户/静态 /dev/串口/启用 systemd 单元）"
docker cp "$ROOT/scripts/rootfs-board-config.sh" "$C:/tmp/board-config.sh" 2>/dev/null || true
# 直接对导出后的树做配置（不需要再进容器）：board-config 支持 PREFIX 前缀
PREFIX="$R/" KVER="$KVER" bash "$ROOT/scripts/rootfs-board-config.sh" | sed 's/^/   /'

echo "== [6/6] 内核模块 / 固件（可选，来自 OWROOT）"
if [ -n "$OWROOT" ] && [ -d "$OWROOT/lib/modules/$KVER" ]; then
	mkdir -p "$R/lib/modules"; cp -a "$OWROOT/lib/modules/$KVER" "$R/lib/modules/"
fi
if [ -n "$OWROOT" ] && [ -d "$OWROOT/lib/firmware" ]; then
	mkdir -p "$R/lib/firmware"
	cp -a --remove-destination "$OWROOT/lib/firmware/." "$R/lib/firmware/" 2>/dev/null || true
fi
[ -f "$R/etc/resolv.conf" ] || ln -sf /run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
docker rm -f "$C" >/dev/null 2>&1 || true
echo "== 完成：$R（$(du -sh "$R" | cut -f1)）"
