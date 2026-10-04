#!/usr/bin/env bash
# 在 rootfs 内启用开机自启（不启动）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
R="${ROOTFS_DIR:-$ROOT/rootfs}"
W="$R/etc/systemd/system/multi-user.target.wants"
mkdir -p "$W"
chroot "$R" systemctl enable ssh.service systemd-networkd.service systemd-resolved.service \
	chrony.service nftables.service 2>/dev/null || true
chroot "$R" systemctl enable serial-getty@ttyS0.service 2>/dev/null || true

for u in h5000m-firstboot.service h5000m-wifi-vif.service h5000m-boot-diagnostics.timer \
         h5000m-ap@ap24.service h5000m-ap@ap5g.service \
         at-webserver.service mt5700-web.service; do
	[ -f "$R/etc/systemd/system/$u" ] || continue
	ln -sf "../$u" "$W/$u"
	echo "   enable $u"
done
