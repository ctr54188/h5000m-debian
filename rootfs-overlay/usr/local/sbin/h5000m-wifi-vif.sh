#!/bin/sh
# 为 MT7992 建两个 AP vif。每个 vif 用独立 MAC，避免 udev 别名冲突(ENOTUNIQ)
BASE=0e:c7:2f:5b:6a
iw reg set CN 2>/dev/null
for i in $(seq 1 60); do
    P=$(ls /sys/class/ieee80211/ 2>/dev/null | head -1)
    [ -n "$P" ] && break
    sleep 1
done
[ -n "$P" ] || { echo "no wiphy found"; exit 1; }
mkdir -p /run/h5000m
for n in ap24 ap5g; do
    if ! [ -d /sys/class/net/$n ]; then
        iw dev $n del 2>/dev/null
        case $n in
            ap24) M=$BASE:86 ;;
            ap5g) M=$BASE:87 ;;
        esac
        iw phy "$P" interface add $n type __ap addr $M 2>/dev/null
    fi
    ip link set $n up 2>/dev/null
done
