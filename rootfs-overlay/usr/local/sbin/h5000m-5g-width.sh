#!/bin/sh
# H5000M 5GHz AP 带宽修复
#
# 背景：/etc/hostapd/ap5g.conf 原来只有 ieee80211n/ac=1，没有带宽与 HT/VHT/HE 能力，
#       hostapd 于是用默认 20MHz → 协商速率上限只有 ~173Mbps（11ac 2SS）。
#       本脚本写入 80MHz 配置（11n/11ac/11ax），并做备份、校验、回滚。
#
# 用法：
#   h5000m-5g-width.sh            应用 80MHz 配置（延时重启，避免断线把自己踢掉）
#   h5000m-5g-width.sh --check    只查看当前 5GHz 状态与客户端协商速率
#   h5000m-5g-width.sh --rollback 恢复备份配置并重启
#   h5000m-5g-width.sh --eht      先尝试 Wi-Fi 7(EHT)，失败自动回退到 11ax 配置
#
# 说明：设备上 hostapd 为 v2.10，最高支持 11ax(HE)；EHT 需要 hostapd >= 2.11，
#       所以 --eht 会先做一次「试启动」探测，起不来就不采用。
set -eu

CONF=/etc/hostapd/ap5g.conf
BAK=/etc/hostapd/ap5g.conf.bak
UNIT=h5000m-ap@ap5g
TRY=/etc/hostapd/ap5g.conf.try
LOG=/tmp/h5000m-5g-width.log

show_state() {
	echo "== 当前 5GHz 状态 =="
	iw dev ap5g info 2>/dev/null | grep -E "channel|width|txpower" || echo "  (ap5g 不存在)"
	echo "== 已关联客户端协商速率 =="
	iw dev ap5g station dump 2>/dev/null | grep -E "Station|rx bitrate|tx bitrate|signal:" || echo "  (暂无客户端)"
}

write_conf() {
	cat > "$CONF" <<'CONF_EOF'
interface=ap5g
driver=nl80211
ssid=H5000M-5G
country_code=CN
hw_mode=a
channel=149
ieee80211d=1
ieee80211n=1
ieee80211ac=1
ieee80211ax=1
wmm_enabled=1
auth_algs=1
ht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40][MAX-AMSDU-7935]
vht_capab=[MAX-MPDU-11454][RXLDPC][SHORT-GI-80][TX-STBC-2BY1][RX-STBC-1][SU-BEAMFORMEE][MU-BEAMFORMEE][MAX-A-MPDU-LEN-EXP7]
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=155
he_oper_chwidth=1
he_oper_centr_freq_seg0_idx=155
CONF_EOF
}

restart_later() {
	# 延时 2 秒重启：重启 AP 会断开当前 Wi-Fi，用 systemd-run 让重启脱离本会话
	if command -v systemd-run >/dev/null 2>&1; then
		systemd-run --on-active=2 --unit=h5000m-ap-restart-$$ \
			systemctl restart "$UNIT" >/dev/null 2>&1
		echo "  已在 2 秒后重启 ${UNIT}（Wi-Fi 会短暂断开，几秒后自动重连）"
	else
		echo "  立即重启 $UNIT"
		systemctl restart "$UNIT"
	fi
}

# 试跑 hostapd 配置（前台跑 4 秒，能活着就算通过），用于 --eht 探测
probe_conf() {
	systemctl stop "$UNIT" >/dev/null 2>&1 || true
	sleep 1
	hostapd -d "$1" >"$LOG" 2>&1 &
	HP=$!
	sleep 4
	if kill -0 "$HP" 2>/dev/null; then
		kill "$HP" 2>/dev/null || true
		wait "$HP" 2>/dev/null || true
		return 0
	fi
	wait "$HP" 2>/dev/null || true
	return 1
}

case "${1:-}" in
--check)
	show_state
	exit 0
	;;
--rollback)
	if [ -f "$BAK" ]; then
		cp "$BAK" "$CONF"
		echo "已从 $BAK 恢复配置"
		restart_later
	else
		echo "没有备份文件 ${BAK}，无法回滚" >&2
		exit 1
	fi
	exit 0
	;;
-h|--help)
	sed -n '2,20p' "$0"
	exit 0
	;;
"") ;;
*)
	echo "未知参数：$1（可用：--check / --rollback / --eht）" >&2
	exit 2
	;;
esac

[ -f "$CONF" ] || { echo "找不到 ${CONF}（这台设备的 5GHz AP 配置路径不对？）" >&2; exit 1; }
[ -f "$BAK" ] || { cp "$CONF" "$BAK"; echo "已备份原配置 → $BAK"; }

write_conf
echo "已写入 80MHz 配置到 $CONF"

if [ "${1:-}" = "--eht" ]; then
	cp "$CONF" "$TRY"
	echo "ieee80211be=1" >> "$TRY"
	echo "正在试启动 EHT(Wi-Fi 7) 配置……"
	if probe_conf "$TRY"; then
		echo "  ✓ EHT 可用，采用 EHT 配置"
		cp "$TRY" "$CONF"
	else
		echo "  ✗ EHT 启动失败（hostapd v2.10 不支持 11be），保持 11ax 80MHz 配置"
		tail -3 "$LOG" 2>/dev/null | sed 's/^/    /' || true
	fi
	rm -f "$TRY"
	systemctl start "$UNIT" >/dev/null 2>&1 || true
	echo "已重启 $UNIT"
else
	restart_later
fi

echo
echo "== 重连后验证（这就是客户端协商速率）=="
echo "   iw dev ap5g info | grep -E 'channel|width'          # 期望 width: 80 MHz"
echo "   iw dev ap5g station dump | grep -E 'rx bitrate|tx bitrate'"
echo "   预期：11ax 2SS ≈ 1200.9 MBit/s，11ac 2SS ≈ 866.7 MBit/s（20MHz 时只有 ~173）"
echo "   回滚：$0 --rollback"
