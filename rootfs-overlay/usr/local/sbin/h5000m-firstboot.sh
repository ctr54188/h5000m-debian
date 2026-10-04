#!/bin/sh
# H5000M 首次启动：把 ext4 根文件系统扩到整个 rootfs 分区，并建立 1G swap
# 注意：findmnt 可能返回 /dev/root（不是设备节点），所以优先用分区标签
set -x

DEV=/dev/disk/by-partlabel/rootfs
if [ ! -e "$DEV" ]; then
    DEV=$(findmnt -no SOURCE / 2>/dev/null)
fi
if [ -n "$DEV" ] && [ -e "$DEV" ]; then
    resize2fs "$DEV" 2>&1
else
    echo "cannot locate root device (DEV=$DEV)"
fi

if [ ! -f /swapfile ]; then
    if ! fallocate -l 1G /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile
fi
swapon /swapfile 2>/dev/null || true

df -h /
free -m
swapon --show
