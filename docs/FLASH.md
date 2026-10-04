# 刷入自编译的 Debian 13（MT7987A）

本目录已生成两个可直接刷写的 Debian 13 (trixie) arm64 包：

| 文件 | 适用机型 | 大小 | 组成 |
|---|---|---|---|
| `images/debian-13-e87n.bin` | EdgePi E87N | ~782 MB | `sysupgrade-e87n/{CONTROL,kernel,root}` |
| `images/debian-13-h5000m.bin` | Hiveton H5000M | ~782 MB | `sysupgrade-h5000m/{CONTROL,kernel,root}` |

- **kernel**：**自己源码编译**的 Linux **6.12.103** FIT（Image + 对应 DTB）
  - 源码 = Linux 6.12.103 + MediaTek/OpenWrt 的 MT7987 补丁（clk/pinctrl/eth/pcs/phy/pwm/thermal/cpufreq/rng）
  - 已打开 **`CONFIG_DEVTMPFS=y`**、`MMC_MTK=y`、`EXT4_FS=y`、`NET_MEDIATEK_SOC=y`
    → 内核可直接挂载 eMMC 上的 ext4 根，**不需要 initramfs，也不需要任何自定义 init**
- **root**：Debian 13 arm64，ext4，**768 MiB**（已用 473 MB，启动后可 `resize2fs` 撑满分区）
  - systemd / networkd / resolved / openssh / chrony，**标准 `/sbin/init -> /lib/systemd/systemd`**
  - 模块为同一内核编出的 `/lib/modules/6.12.103`（109 个）
  - systemd、systemd-networkd、systemd-resolved、openssh-server、chrony
  - 从 OpenWrt 包中提取的**同版本内核模块 + firmware**（wifi/phy 可用）
  - `root=PARTLABEL=rootfs`（与 DTB 一致），ext4 为内核内建，自动识别
- **未触碰 BL2 / FIP / GPT**，只覆盖 `kernel` 与 `rootfs` 两个分区。

校验：

```bash
cd /Users/long/Desktop/AI_Code/H5000M
shasum -a 256 -c images/debian-13-e87n.bin.sha256
shasum -a 256 -c images/debian-13-h5000m.bin.sha256
```

---

## 0. 重要前提与安全

1. **确认机型**（别刷错）：
   - 串口启动日志里 `compatible = "edgepi,e87n"` → 用 e87n 包
   - `compatible = "hiveton,h5000m"` → 用 h5000m 包
2. **必须确认 `rootfs` 分区 ≥ 805306368 字节（768 MiB）**。
   小于这个值会覆盖后面的分区，导致数据损坏；`07` 脚本会自动检查并拒绝。
   `rootfs` 分区比 768 MiB 大也没关系，进系统后 `resize2fs` 撑满即可。
3. **先备份**（强烈建议）：把当前 kernel / rootfs 分区（或整盘）读出来。
4. 本包 **773 MB**，不要用 U-Boot Web 恢复页上传（内存不够），用 `ums` 或 Linux 侧 `sysupgrade`。

---

## 1. 看分区（串口 U-Boot）

```text
mmc dev 0
mmc part
```

记录 **kernel** 与 **rootfs** 分区的起始块号。典型 GPT（具体以你机器为准）：

```
bl2 / fip / factory / kernel / rootfs ...
```

---

## 2. 备份现有分区（推荐）

U-Boot 里开 U 盘模式：

```text
mmc dev 0
ums 0 mmc 0
```

宿主机（macOS 示例）：

```bash
diskutil list                       # 找到 /dev/diskN
sudo gpt -r show /dev/diskN         # 看分区号
# 备份 kernel / rootfs 分区（示例：s1=kernel, s2=rootfs）
sudo dd if=/dev/rdiskN s1 of=backup-kernel.img bs=1m
sudo dd if=/dev/rdiskN s2 of=backup-rootfs.img bs=1m
```

回 U-Boot：`ums stop 0`。

> Linux 更简单：`sudo dd if=/dev/sdX1 of=backup-kernel.img bs=1M`。

---

## 3. 刷入

### 先看你的 U-Boot 支持什么

本机 FIP（`mt7987_airpi_h5000m-fip.bin`，U-Boot 2025.07 / HiGoOS）实测：

| 命令 | 有没有 |
|---|---|
| `tftpboot` / `dhcp` / `ping` / `wget` | ✅ |
| `mmc read/write/part` / `setexpr` | ✅ |
| `mtkupgrade` / `mtkboardboot` / Web 页 | ✅ |
| `bootm` / `booti` | ✅ |
| `ums` / `fastboot` / `usb` / `fatload` / `ext4load` | ❌ **没有** |

> ⚠️ **所以不能用 U 盘模式（`ums`）或 fastboot**。上一版我说 `ums` 是错的。
> 进 U-Boot 后先执行 `help`（或 `?`）确认真实命令集。

### 方法 A（推荐，纯 U-Boot）：TFTP + `mmc write` 分块

不需要电脑写盘，只要同网段有一台 TFTP 服务器。先切块并生成命令：

```bash
./scripts/08-split-for-tftp.sh images/debian-13-e87n.bin images/tftp 128 0x1000 0x2000
#                                                             块MB kernel起始块 rootfs起始块
```

块号用 U-Boot 的 `mmc part` 查（512 字节/块）。然后在 U-Boot 里执行
`images/tftp/uboot-cmds.txt`（宿主机 TFTP 根目录设为 `images/tftp`）：

```text
setenv ipaddr 192.168.1.1
setenv serverip 192.168.1.2
setenv netmask 255.255.255.0
ping ${serverip}
mmc dev 0

# 写 kernel 分区
tftpboot 0x48000000 kernel.itb
setexpr cnt ${filesize} / 0x200
mmc write 0x48000000 0x1000 ${cnt}

# 写 rootfs 分区（768MiB，6 块，每块 128MiB）
setenv blk 0x2000
tftpboot 0x48000000 root.part00
setexpr cnt ${filesize} / 0x200
mmc write 0x48000000 ${blk} ${cnt}
setexpr blk ${blk} + ${cnt}
# 重复 root.part01 ... root.part05
reset
```

要点：
- `${filesize}` 是**字节**，`mmc write` 要**块数** → 必须 `/ 0x200`。
- 128MiB 分块是为了不占满 1GB RAM；也可以改成 64MiB 更保险。
- 宿主机起 TFTP：`./scripts/02-serve-tftp.sh images/tftp`。

### 方法 B：U-Boot Web 恢复页 / `mtkupgrade fw`

网线接 LAN → 断电 → 按住 Reset → 上电 → 浏览器 `192.168.1.1` → Upload Firmware；
或串口菜单 → Upgrade firmware（`mtkupgrade fw`，TFTP server 默认 `192.168.1.2`）。

> ⚠️ 这两种方式会把**整个包读进 RAM**再写。你的包 **781 MB**，1 GB RAM 的机器
> 很可能失败。所以大包优先用方法 A 分块；这两种只在刷小固件（<100MB）时舒服。

### 方法 C：设备上已有 Linux（OpenWrt / 旧 Debian）

流式写入，不占内存：

```bash
lsblk                                  # 找 mmcblk0 的 kernel / rootfs 分区
tar -xOf debian-13-e87n.bin sysupgrade-e87n/kernel | dd of=/dev/mmcblk0pX bs=1M
tar -xOf debian-13-e87n.bin sysupgrade-e87n/root   | dd of=/dev/mmcblk0pY bs=1M
sync && reboot
```

> OpenWrt 里也可以 `sysupgrade -F -n debian-13-e87n.bin`。

---

## 4. 首次启动

串口 115200 8N1，应看到：

```
[init] MT7987 Debian early init (6.12.103)
[init] /dev prepared; starting systemd
...
Debian GNU/Linux 13 edgepi-e87n ttyS0
```

登录：

| 用户 | 密码 |
|---|---|
| `root` | `root` |
| `debian` | `debian` |

**第一时间改密码**：`passwd` / `passwd debian`。

网络：`systemd-networkd` 对所有 `en*/eth*/end*` 接口 DHCP，插网线即可拿 IP：

```bash
ip a
systemctl status systemd-networkd
```

---

## 5. 如果 rootfs 分区更大：扩容

若 `rootfs` 分区比 768 MiB 大（通常是），**进系统第一件事**就是把文件系统撑满，

```bash
lsblk                                  # 确认 rootfs 分区设备，如 /dev/mmcblk0p2
resize2fs /dev/mmcblk0p2
df -h /
```

---

## 6. 关于内核（为什么不是 Debian 官方内核）

我验证过：**Debian 官方内核（6.12 trixie / 7.1 backports / 7.2 sid）都没有 MT7987 支持**
（没有 `COMMON_CLK_MT7987`、`PINCTRL_MT7987`、`mt7987-eth`），只认到温度传感器
`mediatek,mt7987-lvts`。刷官方 `linux-image-arm64` 是**起不来**的。

所以这里用的是「Linux 6.12.103 + MediaTek MT7987 板级补丁」自己编的内核，
但它是标准内核（**`CONFIG_DEVTMPFS=y`**），所以：

- `/sbin/init` 就是 Debian 的 systemd，PID1 直接启动，无任何定制脚本；
- eMMC/ext4 驱动内建，内核自己挂载 `PARTLABEL=rootfs`，无需 initramfs；
- 模块与内核同源同版本，放在标准 `/lib/modules/6.12.103`。

这跟 Armbian 对「还没进主线的板子」的做法一致：**Debian 用户态 + 板级 BSP 内核**。

其它说明：
- Wi-Fi 需要 `wpa_supplicant`（已装）+ 模块/firmware（已装），但默认没配 SSID。
- 个别 Debian 服务可能因内核选项差异报错，可 `systemctl --failed` 查看。

---

## 7. 回滚 / 救砖

### 回到原始固件

用第 2 节的备份写回，或重新刷厂商包（同样走 ums 分区 dd / Linux sysupgrade）：

- `mwrt-edgepi-e87n-1139-24-20260921(...).bin`（E87N）
- `/Users/long/Desktop/airpi/immortalwrt-hiveton-h5000m-*.bin`（H5000M）
- 微信 `2026-08/immortalwrt-mediatek-filogic-edgepi_e87n-squashfs-sysupgrade.bin`

```
07-ums-flash-sysupgrade.sh <原厂包.bin> <kernel分区> <rootfs分区>
```

### Debian 起不来时拿一个 shell

串口进 U-Boot，手动指定 init：

```text
setenv bootargs 'console=ttyS0,115200n8 root=PARTLABEL=rootfs rootwait rw init=/bin/busybox sh'
# 然后按你的启动方式 boot（mtkboardboot / bootm）
```

能进 busybox shell 后：

```sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /dev
# 手动起 systemd 看报错
/lib/systemd/systemd --log-target=console --log-level=debug
```

### 完全变砖

只覆盖了 kernel/rootfs，BL2/FIP 未动，正常不会变砖。若误刷引导链，进 BootROM
（按住 BROM 键/短接上电，USB 识别为 MTK 设备）用 `mtkclient` 重刷本机 BL2+FIP。

---

## 8. 这些包是怎么做的（可复现）

1. **内核**：用 ImmortalWrt 的 MT7987 补丁源（`target/linux/mediatek/patches-6.12`）准备好
   Linux 6.12.103 源码树，补上 `mt7987a-edgepi-e87n.dts` / `mt7987a-hiveton-h5000m.dts`，
   然后用系统 gcc 直接编译：
   ```bash
   make ARCH=arm64 CROSS_COMPILE= HOSTCC=gcc-14 CC=gcc-14 \
        -j8 Image dtbs modules modules_install INSTALL_MOD_PATH=/build/kmods
   ```
   关键配置：`CONFIG_DEVTMPFS=y CONFIG_DEVTMPFS_MOUNT=y CONFIG_MMC_MTK=y
   CONFIG_EXT4_FS=y CONFIG_NET_MEDIATEK_SOC=y CONFIG_PINCTRL_MT7987=y
   CONFIG_COMMON_CLK_MT7987=y`。
2. **FIT**：`mkimage` 把 `Image` + 对应 dtb 打成 U-Boot FIT（load/entry `0x40000000`）。
3. **Debian 根**：`debootstrap --arch=arm64 trixie`，装 systemd/网络/ssh/`wpa_supplicant` 等，
   把上一步的 `/lib/modules/6.12.103` 拷进去。
4. **ext4**：`mke2fs -t ext4 -d rootfs/ rootfs.img 768M`（无需挂载）。
5. **打包**：`tar` 成 `sysupgrade-<board>/{CONTROL,kernel,root}`。

脚本在 `build/`：`build-rootfs.sh`、`debian-init`（仅早期版本使用，现已不需要）、
`scan2.py`（识别各固件内核能力）。
