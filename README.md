# h5000m-debian

**Hiveton H5000M（MediaTek MT7987A，ARM64）的 Debian 13 镜像构建仓库。**

保留原厂的 BL2 / FIP / GPT 分区表，只替换其中的 **kernel（FIT）** 与 **rootfs（ext4）**，
产出一个可用 U-Boot 网页界面直接上传的 `debian-13-h5000m.bin`。

> 配套仓库：[`h5000m-mt5700-panel`](../h5000m-mt5700-panel) —— MT5700M 5G 模组管理面板
> （Debian 移植版），本仓库在构建 rootfs 时会把它的分发包装进去。

---

## 1. 目标硬件与已实现功能

| 项目 | 事实 |
| --- | --- |
| SoC | MediaTek MT7987A（4×Cortex-A53），内部 HNAT/PPE |
| 内存 | 1 GiB |
| 存储 | eMMC（GPT，`kernel` = FIT，`rootfs` = ext4；原厂另有 squashfs 备份槽） |
| 有线 | 2× 物理网口（2.5G PHY + 内置 PHY），驱动 `mtk_eth_soc` |
| 无线 | MT7992 + MT7976/MT7977（2.4G/5G，`mt7996e` / mt76） |
| 5G | TD Tech **MT5700M-CN**（USB：`cdc_ncm` 网卡 + `option` 串口，APN `cmnet`） |
| 风扇 | PWM 风扇（`pwm-fan`，thermal cooling device） |

Debian 侧已实现并**在真机验证过**：

* 有线：链路 / TX / RX / DHCP 正常；**有线 HNAT（PPE）硬件卸载**（nftables flowtable + `flags offload`）
* 双频 AP：`H5000M-2.4G`(ch6) / `H5000M-5G`(ch149)，hostapd + systemd-networkd 桥接，
  客户端 DHCP + NAT 上网
* 5G 上行：MT5700M USB 模组自动拨号 → `enx*` 拿地址 → 默认路由（`RouteMetric` 有线优先、5G 备用）
* 风扇温控：`pwm-fan` 随 CPU 温度调速（94.6 °C → 68.7 °C）
* eMMC firstboot 扩容（`/` 由 739 M 扩到 7.2 G）+ 1 G swapfile
* 面板：[MT5700M 模组管理面板](../h5000m-mt5700-panel)（12 个页面，systemd 自启）

**未做（结论已定）**：无线侧 WED/PPE 硬件卸载。厂商的无线卸载引擎是闭源
`mtk_warp.ko` + `mtk_wed.ko`（与 `mt_wifi` 用户态强耦合，主线 6.12 无 MT7987 支持），
无法移植 —— 无线走 **CPU 转发**，有线仍走 PPE 卸载。

---

## 2. 构建链路

```
BSP（ImmortalWrt, pin 提交）
  └─ patches/bsp/*.patch                config-6.12（DEVTMPFS/WWAN/MAC80211）+ DTS（以太网 8 条中断、板级 MAC）
  └─ patches/kernel-997-*.patch          mtk_eth_soc：MT7987 TX 完成中断修复
  └─ config/bsp.config                   同一套 .config（可复现）
        │
        ├─ make kernel  → Image + board.dtb + modules-6.12.103.tar.gz
        │
Debian 13 arm64 rootfs（debootstrap）
  └─ scripts/build-rootfs.sh             装包 + 板级配置
  └─ rootfs-overlay/                     网络/AP/防火墙/风扇/5G/面板等系统文件
  └─ 面板分发包（h5000m-mt5700-panel）    /usr/bin/mt5700-web、at-webserver-rust、站点
        │
        └─ scripts/package-image.sh      → kernel.itb（FIT）+ rootfs.ext4 + sysupgrade .bin
```

---

## 3. 构建方法

### 3.1 依赖

* 构建内核：Docker/Linux（**不要**在 macOS 上直接构建 OpenWrt）、`git`、OpenWrt 的主机构建依赖
  （`build-essential flex bison gawk gettext libncurses-dev libssl-dev python3 rsync unzip wget file`）
* 打包镜像：`u-boot-tools`（`mkimage`/`fdtput`）、`device-tree-compiler`、`e2fsprogs`
* rootfs：`debootstrap`，交叉架构还需 `qemu-user-static`

### 3.2 完整步骤（在 Linux/容器里，需 root）

```sh
git clone https://github.com/ctr54188/h5000m-debian && cd h5000m-debian

make bsp          # 拉 BSP（pin: ChenMercy/immortalwrt@428fbc3）
make patches      # 打补丁：BSP config/DTS + 内核 997/998 + 写入 .config

# 内核（首次含 tools + toolchain，4 核约 40~90 分钟）
make kernel JOBS=$(nproc)
# 产物：out/kernel/{Image,board.dtb,modules-6.12.103.tar.gz,kernel.config}

# 面板分发包（从面板仓库 release 取，或 PANEL_TARBALL=... 指定本地包）
make panel

# Debian rootfs
make rootfs       # = debootstrap-rootfs.sh + build-rootfs.sh
#   带内核模块与 firmware（推荐，从 BSP 的完整 image 构建或原厂固件里取）：
#   OWROOT=/path/to/openwrt-rootfs make rootfs

# 打包刷机镜像
make package
# 产物：out/image-<时间戳>/debian-13-h5000m.bin(+.sha256)
```

仅校验补丁（不需要 BSP，几秒钟）：

```sh
make check        # 校验 patches/bsp/*.patch 与内核 997/998 能否干净应用
```

### 3.3 BSP 完整 image（可选，用于取 `OWROOT`）

内核模块与 firmware 也可以直接从 BSP 的完整 image 构建里拿：

```sh
cd bsp
./scripts/feeds update -a && ./scripts/feeds install -a
make -j$(nproc)                     # 完整 image（很久）
# 之后：bin/targets/mediatek/filogic/*rootfs.tar.gz 解出来就是 OWROOT
```

---

## 4. GitHub Actions（两个独立 workflow）

本仓库有**两个互不干扰**的 workflow，都在 `.github/workflows/`：

| workflow | 面板 | 触发 | 说明 |
| --- | --- | --- | --- |
| `image.yml` | **不带面板** | push(main) / PR / tag / 手动 | 纯系统镜像：内核 + Debian rootfs + overlay + 打包 |
| `image-with-panel.yml` | **带面板** | 仅手动 / tag | 在上面基础上，从 **A 仓库**（`ctr54188/h5000m-mt5700-panel`）取面板并装进 rootfs |

两个 workflow 内部均为 4 个 job：

| Job | 触发条件 | 作用 | 耗时 |
| --- | --- | --- | --- |
| `check` | 总是 | 补丁校验 + 关键配置回归检查 | ~2 min |
| `rootfs` | 非 PR | debootstrap arm64（x86_64 runner 用 qemu 二阶段）→ 装包 → overlay（+面板）→ `rootfs.ext4` | ~15–40 min |
| `kernel` | tag 或手动勾选 `build_kernel` | feeds → 主机工具/交叉工具链（**单独一步并缓存**）→ 内核 + 模块 + DTB | 首次 ~1.5–2 h，有缓存 ~10–20 min |
| `package` | tag 或手动勾选 `build_kernel` | 装入内核模块 + `depmod` → `package-image.sh` → `.bin`；tag 时发 Release | ~5 min |

### 4.1 与 A 仓库的关系（**单向、无触发**）

* `image-with-panel.yml` **只会去 A 仓库拉东西**：优先读 A 的 release 资产（`scripts/fetch-panel.sh`），
  取不到就**回退到源码构建**（`scripts/build-panel-from-source.sh`：`git clone` A → `make build` → 打包）。
* A 仓库不会触发本仓库，本仓库也不会触发 A 仓库 —— 两边都没有
  `repository_dispatch` / `workflow_run` 之类的联动。
* 因此：**A 挂了不影响 `image.yml`**；`image-with-panel.yml` 在 A 没有 release 时也能自己编出来。

在 A 仓库只提供源码、没有 release 时，带面板的构建会自动走源码回退；也可以显式勾选
`panel_from_source`，或指定 `panel_repo` / `panel_tag`（比如要固定某个面板版本）。

### 4.2 用法

```sh
# 纯系统镜像（不需要面板）：push 到 main 即自动跑；或手动
#   Actions → image → Run workflow
#
# 带面板的镜像：
#   Actions → image-with-panel → Run workflow
#     build_kernel   = true   # 顺带编内核并打包成 .bin
#     panel_tag      = v2.0.0 # 留空 = 用 A 的最新 release
#     panel_from_source = false
#
# 出正式版本（两个 workflow 都会在 tag 上跑，各自发 Release）：
git tag v1.0.0 && git push origin v1.0.0
```

### 4.3 内核构建为什么要先装 feeds

CI 上首次跑内核构建曾失败：`target/linux failed to build`（18 秒即失败）。根因是
**BSP 克隆后没有安装 feeds**，`.config` 与源码树不同步（日志里成片的
`has a dependency on 'xxx', which does not exist` 就是证据）。现在：

1. 先 `./scripts/feeds update -a && ./scripts/feeds install -a`；
2. 再 `make defconfig` 让 `.config` 与当前树对齐（消除 `out of sync` 警告）；
3. 失败时自动 `make -j1 V=s` 重跑并打印最后 120 行，让根因直接出现在 CI 日志里；
4. 工具链与 `dl/`、`feeds/` 单独缓存（**失败也会保存**），改补丁后不必重编 2 小时的工具链。

## 5. 注意事项（都是真机踩出来的）

### 5.1 刷写

1. **只刷 Firmware 项**：U-Boot 网页界面 → Firmware → 上传 `debian-13-h5000m.bin`。
   **不要**刷 BL2 / FIP / GPT，也不要用其它机型（如 E87N）的 BL2。
2. 上传前核对哈希：`sha256sum -c debian-13-h5000m.bin.sha256`。
3. 镜像内 `rootfs` 固定 `805306368` 字节（768 MiB），与升级槽位一致；首次启动会
   自动扩容到整块 eMMC 并创建 1 G swap（`h5000m-firstboot.service`）。

### 5.2 内核 / 设备树

* **`CONFIG_DEVTMPFS=y` 必须开**（`patches/bsp/0001-*`）：否则内核对 `/dev` 不做
  devtmpfs 填充，Debian 的 systemd 无法挂载 `/dev` → 起不来。
  （历史上有过用 busybox init 手工 `mknod` 的绕法，见 `legacy/debian-init.busybox`，已不需要。）
* **ABI 必须一致**：rootfs 里的 `.ko` 只能来自同一个 `6.12.103` 构建树，
  否则 `insmod` 报 version magic 不匹配。
* **以太网 TX 修复要两处齐备**（缺一不可）：
  * `patches/bsp/0003-*`：DTS 里列出 **8 条**中断（`SPI 189/190/191/192/196/197/198/199`）
    并加 `interrupt-names = "fe0".."fe3"`。真机上 **TX 完成中断落在 DTS 索引 5
    （SPI197 → hwirq 229）**，主线驱动只注册索引 1/2，索引 5 从未注册 →
    TX 完成无人处理（`tx_packets` 卡在 1 + `NETDEV WATCHDOG`）。
  * `patches/kernel-997-*`：`mtk_eth_soc` 侧把安全合并 handler
    （无匹配源返回 `IRQ_NONE`，不风暴）注册到**全部 8 条**中断线；
    并修正 RX done mask = `MTK_RX_DONE_INT0 | MTK_RX_DONE_INT_V2`。
  * 反面教材：厂商的 `FE_INT_GRP=0x210FFFF2` 在单队列配置下会**掐死全部以太网中断**
    （两个 IRQ 计数恒为 0），不要照抄。
* **板级 MAC** 写在 DTS 里（`gmac0/gmac1` 的 `mac-address`），用于保证 udev 别名稳定。

### 5.3 rootfs / 系统

* `mkfs.ext4 -d <rootfs>` 之前必须 **umount chroot 里的 `/proc /sys /dev`**，否则打包会出现
  空目录/挂载点残留（`scripts/build-rootfs.sh` 已在结尾做 umount）。
* 服务名/单元由 `rootfs-overlay/` 提供，`enable-units.sh` 只做 enable（不启动）。
* 面板默认监听 `:8181` 且**无鉴权**；`rootfs-overlay/etc/nftables.conf` 里
  `table inet h5000m_mgmt` 在 5G 上行口（`enx*`/`wwan*`）丢弃 8181，只允许内网。

### 5.4 网络 / NAT / Wi-Fi

* **flowtable 必须带 `flags offload`** 才是开启 PPE 硬件卸载的开关；表名不要用保留字
  `offload`（本仓库用 `table inet hwnat`）。
* **NAT 必须写在自己的 `/etc/nftables.conf`**：`flush ruleset` 会清掉
  systemd-networkd 的 `IPMasquerade`，两者不要混用。
* 双上行时用 `[DHCPv4] RouteMetric`（`[Network] RouteMetric` 对 DHCP 无效）：
  有线 100 优先、5G 200 备用。
* **AP 的 vif 必须各用独立 MAC**（`h5000m-wifi-vif.sh`），否则 udev 的 `wlx<mac>`
  别名冲突 → `ENOTUNIQ`。
* Wi-Fi 校准：本机 DTB **没有** eeprom/nvmem 校准节点，驱动从固件文件加载默认值，
  实测各信道 27 dBm 正常 —— 不需要改内核或 EEPROM。
* 无线 WED/PPE 卸载不可移植（见 §1）；有线卸载不受影响。

---

## 6. 刷入后自检

```bash
df -h / ; free -m                                  # / 已扩容 + swap 生效
lsusb                                              # 3466:3301 TDTECH MT5700M-CN
ip -br addr | grep -E "enx|ap24|ap5g|br0"          # 5G 网卡 / 双频 AP / 网桥
ip route                                           # 默认路由与 metric
iw dev                                             # H5000M-2.4G / H5000M-5G
cat /sys/class/thermal/thermal_zone0/temp          # ~68-76 °C（风扇工作）
cat /sys/kernel/debug/ppe0/bind                    # 有线 HNAT 绑定条目（需要 debugfs）
systemctl is-active at-webserver mt5700-web        # 面板两个服务
curl -s http://127.0.0.1:8181/health               # 面板
ethtool -S eth0 | grep -i tx | head                # TX 计数在涨（TX 修复验证）
```

---

## 7. 目录结构

```
patches/
  bsp/                     BSP 侧改动（config-6.12 片段、DTS：以太网中断 + 板级 MAC）
  kernel-997-h5000m-mt7987-eth-fixes.patch     mtk_eth_soc MT7987 中断修复
  kernel-998-disable-gcc-plugins.patch         GCC plugins 默认关闭（构建环境）
config/
  bsp.config               OpenWrt 构建配置（pin 的 .config）
  kernel-6.12.103.config   参考内核配置
rootfs-overlay/            板级系统文件（网络/AP/防火墙/风扇/5G/面板 unit 等 27 个文件）
dts/                       打补丁后的 DTS 参考副本（便于比对）
scripts/                   fetch-bsp / apply-bsp-patches / check-patches / build-kernel
                           debootstrap-rootfs / build-rootfs / enable-units / fetch-panel / package-image
legacy/debian-init.busybox 历史方案（DEVTMPFS 未开时的手工 /dev 初始化），留档
docs/                      刷机说明、以太网 TX 逆向记录
```

---

## 8. 许可

* 内核补丁、设备树、BSP 配置片段：**GPL-2.0-only**（Linux 内核衍生）。
* 本仓库的脚本与 rootfs overlay 配置：**GPL-2.0-only**（与镜像内 GPL 组件保持一致）。
* 面板与 LuCI 运行时来自各自上游（GPL-3.0 / Apache-2.0），见配套仓库说明。
* 厂商固件（BL2/FIP/内核原厂镜像）与本仓库无关，请自行备份，勿再分发。
