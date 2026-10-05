#!/bin/bash
# Debian rootfs 的板级配置（在目标 rootfs 内运行；也可用 PREFIX 指定前缀做本机测试）
#
#   PREFIX=/tmp/fakeroot bash rootfs-board-config.sh    # 本机演练
#   bash rootfs-board-config.sh                          # 容器/chroot 内直接跑
set -euo pipefail

P="${PREFIX:-}"
KVER="${KVER:-6.12.103}"
HOSTNAME_LOCAL="${HOSTNAME_LOCAL:-h5000m}"
R="$P"

echo "== 主机名 / hosts / fstab"
printf '%s\n' "$HOSTNAME_LOCAL" > "$R/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' "$HOSTNAME_LOCAL" > "$R/etc/hosts"
printf '# <file system>   <mount point>  <type>  <options>          <dump> <pass>\nPARTLABEL=rootfs  /              auto    defaults,noatime   0      1\nproc              /proc          proc    defaults           0      0\n/swapfile         none           swap    sw                 0      0\n' > "$R/etc/fstab"

echo "== 用户 / 时区 / firstboot 抑制"
if [ -z "$P" ]; then   # 只有在目标 rootfs 内才改用户（PREFIX 演练时跳过）
	echo 'root:root' | chpasswd 2>/dev/null || true
	if ! id debian >/dev/null 2>&1; then
		useradd -m -s /bin/bash debian 2>/dev/null || true
		echo 'debian:debian' | chpasswd 2>/dev/null || true
	fi
fi
: > "$R/etc/machine-id"
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$R/etc/localtime" 2>/dev/null || true
printf 'Asia/Shanghai\n' > "$R/etc/timezone"
ln -sf /dev/null "$R/etc/systemd/system/systemd-firstboot.service"
printf 'console\ntty1\nttyS0\n' > "$R/etc/securetty"

echo "== SSH（首次可用密码登录 root）"
mkdir -p "$R/etc/ssh/sshd_config.d"
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > "$R/etc/ssh/sshd_config.d/10-permit-root.conf"

echo "== 串口控制台 ttyS0"
mkdir -p "$R/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$R/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \u' --keep-baud 115200,57600,38400,9600 %I $TERM
Type=idle
EOF

echo "== 静态 /dev 节点"
mkdir -p "$R/dev/pts" "$R/dev/shm"
for n in "null c 1 3 666" "zero c 1 5 666" "full c 1 7 666" "random c 1 8 666" \
         "urandom c 1 9 666" "console c 5 1 600" "tty c 5 0 666" "ttyS0 c 4 64 666" "tty1 c 4 1 666"; do
	set -- $n
	mknod -m "$4" "$R/dev/$1" "$2" "$3" "$5" 2>/dev/null || true
done
ln -sf /proc/self/fd "$R/dev/fd" 2>/dev/null || true

echo "== 启用 systemd 单元（手工建软链；容器内没有运行 systemd 也能用）"
MU="$R/etc/systemd/system/multi-user.target.wants"
GU="$R/etc/systemd/system/getty.target.wants"
mkdir -p "$MU" "$GU"

# Debian 自带单元（注意 serial-getty 是模板，要链到 @.service 并放 getty.target.wants）
# 注意：这里一律用 if 而不是 `[ -f x ] && cmd` —— 后者在文件不存在时返回非 0，
# 配合 set -e 会让脚本静默退出（CI 上就踩过：容器没装 systemd-resolved）。
link_lib() { # link_lib <单元名> <目标目录>
	local u="$1" d="$2" src="/lib/systemd/system/$u"
	if [ ! -f "$R$src" ]; then src="/usr/lib/systemd/system/$u"; fi
	if [ -f "$R$src" ]; then
		ln -sf "$src" "$d/$u"
	else
		echo "   （跳过 $u：未安装）"
	fi
}
for u in ssh.service systemd-networkd.service systemd-resolved.service chrony.service \
         nftables.service wpa_supplicant.service; do link_lib "$u" "$MU"; done
[ -f "$R/lib/systemd/system/serial-getty@.service" ] || \
	[ -f "$R/usr/lib/systemd/system/serial-getty@.service" ]
if [ -f "$R/lib/systemd/system/serial-getty@.service" ] || [ -f "$R/usr/lib/systemd/system/serial-getty@.service" ]; then
	src=/lib/systemd/system/serial-getty@.service
	[ -f "$R$src" ] || src=/usr/lib/systemd/system/serial-getty@.service
	ln -sf "$src" "$GU/serial-getty@ttyS0.service"   # 串口控制台（救援通道）
fi
if [ -f "$R/lib/systemd/system/getty@.service" ] || [ -f "$R/usr/lib/systemd/system/getty@.service" ]; then
	src=/lib/systemd/system/getty@.service
	[ -f "$R$src" ] || src=/usr/lib/systemd/system/getty@.service
	ln -sf "$src" "$GU/getty@tty1.service"
fi

# 本仓库的板级单元（含模板实例：h5000m-ap@ap24/ap5g → 指向 h5000m-ap@.service）
for u in h5000m-firstboot.service h5000m-wifi-vif.service h5000m-boot-diagnostics.timer \
         at-webserver.service mt5700-web.service; do
	if [ -f "$R/etc/systemd/system/$u" ]; then ln -sf "/etc/systemd/system/$u" "$MU/$u"; fi
done
for inst in h5000m-ap@ap24.service h5000m-ap@ap5g.service; do
	tpl="${inst%@*}@.service"
	if [ -f "$R/etc/systemd/system/$tpl" ]; then
		ln -sf "/etc/systemd/system/$tpl" "$MU/$inst"
	elif [ -f "$R/etc/systemd/system/$inst" ]; then
		ln -sf "/etc/systemd/system/$inst" "$MU/$inst"
	else
		echo "   （跳过 $inst：单元未铺开）"
	fi
done
echo "   multi-user.target.wants:"; ls "$MU" | sed 's/^/     /'
echo "   getty.target.wants:";     ls "$GU" | sed 's/^/     /'

echo "== 板级 overlay（由调用方拷入 /etc、/usr/local/sbin 后再跑本脚本亦可）"
[ -n "${OWROOT:-}" ] && [ -d "${OWROOT}/lib/modules/$KVER" ] && {
	mkdir -p "$R/lib/modules"; cp -a "${OWROOT}/lib/modules/$KVER" "$R/lib/modules/";
	echo "   模块：$(find "$R/lib/modules/$KVER" -name '*.ko' | wc -l) 个";
}
[ -n "${OWROOT:-}" ] && [ -d "${OWROOT}/lib/firmware" ] && {
	mkdir -p "$R/lib/firmware"; cp -a --remove-destination "${OWROOT}/lib/firmware/." "$R/lib/firmware/" 2>/dev/null || true;
}
command -v depmod >/dev/null 2>&1 && depmod -b "$R" "$KVER" 2>/dev/null || true
echo "== 板级配置完成"
