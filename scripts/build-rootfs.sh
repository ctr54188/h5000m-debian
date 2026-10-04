#!/usr/bin/env bash
# 配置 Debian rootfs：装包 → 板级配置 → rootfs-overlay → 面板。
#
# 用法：
#   scripts/debootstrap-rootfs.sh
#   OWROOT=/path/to/openwrt-rootfs PANEL_TARBALL=... scripts/build-rootfs.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="${ROOTFS_DIR:-$ROOT/rootfs}"
KVER="${KVER:-6.12.103}"
OWROOT="${OWROOT:-}"
PANEL_TARBALL="${PANEL_TARBALL:-}"
HOSTNAME_LOCAL="${HOSTNAME_LOCAL:-h5000m}"
MIRROR_DEB="${MIRROR_DEB:-http://deb.debian.org/debian}"
MIRROR_SEC="${MIRROR_SEC:-http://deb.debian.org/debian-security}"
export DEBIAN_FRONTEND=noninteractive

[ -e "$R/usr/lib/systemd/systemd" ] || { echo "缺少 rootfs：$R（先跑 scripts/debootstrap-rootfs.sh）" >&2; exit 1; }

echo "== 挂载伪文件系统"
mountpoint -q "$R/proc"    || mount -t proc proc "$R/proc" 2>/dev/null || true
mountpoint -q "$R/sys"     || mount -t sysfs sysfs "$R/sys" 2>/dev/null || true
mountpoint -q "$R/dev"     || mount --bind /dev "$R/dev" 2>/dev/null || true
mountpoint -q "$R/dev/pts" || mount --bind /dev/pts "$R/dev/pts" 2>/dev/null || true

printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > "$R/etc/resolv.conf"
if [ ! -f "$R/etc/apt/sources.list.d/debian.sources" ] && [ ! -f "$R/etc/apt/sources.list" ]; then
	{
		echo "deb $MIRROR_DEB trixie main contrib non-free non-free-firmware"
		echo "deb $MIRROR_DEB trixie-updates main contrib non-free non-free-firmware"
		echo "deb $MIRROR_SEC trixie-security main contrib non-free non-free-firmware"
	} > "$R/etc/apt/sources.list"
fi

echo "== 禁用 chroot 内服务自启"
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod +x "$R/usr/sbin/policy-rc.d"

echo "== apt update + 安装软件包"
chroot "$R" apt-get -o Acquire::ForceIPv4=true update -qq
chroot "$R" apt-get -o Acquire::ForceIPv4=true install -y -qq --no-install-recommends \
	systemd systemd-sysv udev dbus kmod \
	iproute2 iputils-ping ethtool net-tools nftables \
	openssh-server \
	e2fsprogs f2fs-tools dosfstools parted gdisk \
	procps psmisc less nano htop bash-completion \
	curl wget ca-certificates rsync \
	usbutils pciutils \
	iw wireless-regdb wpasupplicant hostapd \
	chrony zstd xz-utils file
rm -f "$R/usr/sbin/policy-rc.d"

echo "== 基础系统文件"
printf '%s\n' "$HOSTNAME_LOCAL" > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' \
	"$HOSTNAME_LOCAL" > "$R/etc/hosts"
printf '# <file system>   <mount point>  <type>  <options>          <dump> <pass>\nPARTLABEL=rootfs  /              auto    defaults,noatime   0      1\nproc              /proc          proc    defaults           0      0\n' > "$R/etc/fstab"
echo 'root:root' | chroot "$R" chpasswd
: > "$R/etc/machine-id"
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$R/etc/localtime" 2>/dev/null || true
printf 'Asia/Shanghai\n' > "$R/etc/timezone"
ln -sf /dev/null "$R/etc/systemd/system/systemd-firstboot.service"
printf 'console\ntty1\nttyS0\n' > "$R/etc/securetty"
mkdir -p "$R/etc/ssh/sshd_config.d"
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "$R/etc/ssh/sshd_config.d/10-permit-root.conf"

echo "== 串口控制台"
mkdir -p "$R/etc/systemd/system/serial-getty@ttyS0.service.d"
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty -o %s--keep-baud 115200,57600,38400,9600 %%I $TERM\nType=idle\n' \
	"'-p -- \\\\u' " > "$R/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf"

echo "== 静态 /dev 节点"
mkdir -p "$R/dev/pts" "$R/dev/shm"
for n in "null c 1 3 666" "zero c 1 5 666" "full c 1 7 666" "random c 1 8 666" \
         "urandom c 1 9 666" "console c 5 1 600" "tty c 5 0 666" "ttyS0 c 4 64 666" "tty1 c 4 1 666"; do
	set -- $n
	mknod -m "$4" "$R/dev/$1" "$2" "$3" "$5" 2>/dev/null || true
done
ln -sf /proc/self/fd "$R/dev/fd" 2>/dev/null || true

echo "== 内核模块与 firmware"
if [ -n "$OWROOT" ] && [ -d "$OWROOT/lib/modules/$KVER" ]; then
	mkdir -p "$R/lib/modules"
	cp -a "$OWROOT/lib/modules/$KVER" "$R/lib/modules/"
	echo "   模块：$(find "$R/lib/modules/$KVER" -name '*.ko' | wc -l) 个"
else
	echo "   !! 未提供 OWROOT/lib/modules/$KVER —— 跳过（设备上 Wi-Fi/5G 需要这批 .ko）"
fi
if [ -n "$OWROOT" ] && [ -d "$OWROOT/lib/firmware" ]; then
	mkdir -p "$R/lib/firmware"
	cp -a --remove-destination "$OWROOT/lib/firmware/." "$R/lib/firmware/" 2>/dev/null || \
		rsync -a --copy-unsafe-links "$OWROOT/lib/firmware/" "$R/lib/firmware/"
fi
chroot "$R" depmod -a "$KVER" 2>/dev/null || depmod -b "$R" "$KVER" 2>/dev/null || true

echo "== 应用 rootfs-overlay/"
cp -a "$ROOT/rootfs-overlay/." "$R/"
chmod 0755 "$R/usr/local/sbin/"h5000m-* 2>/dev/null || true

echo "== 面板"
if [ -n "$PANEL_TARBALL" ] && [ -f "$PANEL_TARBALL" ]; then
	tar xzf "$PANEL_TARBALL" -C "$R"
	echo "   已装入 $(basename "$PANEL_TARBALL")"
else
	echo "   （未提供 PANEL_TARBALL；可后补 tar xzf <面板包> -C $R）"
fi

echo "== 启用 systemd 单元"
"$ROOT/scripts/enable-units.sh"

echo "== 清理"
chroot "$R" apt-get -qq clean
rm -rf "$R/var/lib/apt/lists"/* "$R/var/cache/apt"/* "$R"/var/log/*.log 2>/dev/null || true
rm -f "$R/etc/resolv.conf"
ln -sf /run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"

umount "$R/dev/pts" 2>/dev/null || true; umount "$R/dev" 2>/dev/null || true
umount "$R/sys" 2>/dev/null || true;     umount "$R/proc" 2>/dev/null || true
echo "== 完成：$R（$(du -sh "$R" | cut -f1)）"
