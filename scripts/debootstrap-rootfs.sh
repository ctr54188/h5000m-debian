#!/usr/bin/env bash
# 生成 Debian arm64（trixie）最小根文件系统。
#   arm64 本机：直接安装；x86_64 主机：foreign 模式 + qemu-user-static（需要 sudo）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="${ROOTFS_DIR:-$ROOT/rootfs}"
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

if [ -e "$R/usr/lib/systemd/systemd" ]; then
	echo "== 已存在 rootfs：$R（跳过 debootstrap）"
	exit 0
fi

case "$(uname -m)" in
aarch64|arm64)
	sudo debootstrap --arch=arm64 --include=systemd-sysv "$SUITE" "$R" "$MIRROR"
	;;
*)
	sudo debootstrap --arch=arm64 --foreign "$SUITE" "$R" "$MIRROR"
	command -v qemu-aarch64-static >/dev/null || {
		sudo apt-get update; sudo apt-get install -y qemu-user-static binfmt-support
	}
	sudo cp /usr/bin/qemu-aarch64-static "$R/usr/bin/"
	sudo update-binfmts --enable qemu-aarch64 2>/dev/null || true
	sudo chroot "$R" /debootstrap/debootstrap --second-stage
	;;
esac
echo "== debootstrap 完成：$R"
