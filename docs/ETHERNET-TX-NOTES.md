# MT7987 以太网 TX 故障：厂商内核逆向与修复依据

参考物料（全部为本地只读副本）：

```text
backups/h5000m-20260930-162949/mmcblk0p4.img     设备上正常工作的 OpenWrt kernel 分区（FIT, lzma, Linux 6.6.94）
build/openwrt-kernel-p4.img                      p4 副本（容器 /w/openwrt-kernel-p4.img）
build/openwrt-kernel-p4.dtb / fit.dts            FIT 结构
refs/capA/                                       设备 SSH 实时抓取（kallsyms/config/dtb/debugfs/ethtool/interrupts）
refs/capA/live.dtb                               运行中系统的 device tree
refs/capA/kallsyms.txt                           48347 个符号（含文件偏移换算基准）
```

符号地址→文件偏移换算（已验证）：

```text
file_offset = kallsyms_addr - 0xffffffc080000000
_stext = 0xffffffc080010000   _etext = 0xffffffc080910000
```

反汇编流程（容器内）：

```bash
TC=/build/imw/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.3.0_musl/bin
python3 /w/fit_kernel.py                     # 从 p4 的 FIT data 属性解出 lzma 内核 → /w/kernel-image.bin
$TC/aarch64-openwrt-linux-objcopy -I binary -O elf64-littleaarch64 -B aarch64 \
    /w/kernel-image.bin /w/kernel-image.o
$TC/aarch64-openwrt-linux-objcopy --set-section-flags .data=alloc,load,readonly,code \
    /w/kernel-image.o /w/kernel-code.o        # objdump -d 只反汇编 code 段
$TC/aarch64-openwrt-linux-objdump -d --start-address=<off> --stop-address=<off> /w/kernel-code.o
```

## 1. 厂商驱动与我们的移植版：静态配置完全一致

| 项目 | 厂商 6.6.94 | 我们 6.12.103 | 结论 |
|---|---|---|---|
| `reg_map`（`mt7988_reg_map`） | `tx_irq_mask=0x461c`、`tx_irq_status=0x4618`、`pdma.irq_status=0x6a20`、`pdma.irq_mask=0x6a28`、`qdma.int_grp=0x4620`、`qdma.ctx_ptr=0x4700`… | 完全相同 | 一致 |
| `gdma_to_ppe` / `ppe_base` / `wdma_base` / `pse_iq_sta` | `{0x3333,0x4444,0xcccc}` / `0x2000` / `{0x4800,0x4c00,0x5000}` / `0x180` | 完全相同 | 一致 |
| `mt7987 soc_data` tx/rx 参数 | desc_size `0x20`、tx.dma_size `0x800`、fq `0x1000`、rx.dma_size `0x800` | 相同 | 一致 |
| TX 完成位 | `BIT(28)` @ `0x4618`(status) / `0x461c`(mask) | 相同 | 一致 |
| **FE 中断分组 `MTK_FE_INT_GRP`(0x20)** | **`0x210ffff2`**（且**不写** `pdma.int_grp`） | `0x21021000`（且写 `pdma.int_grp`） | **不一致** |
| `qdma.int_grp+4` (0x4624) | 厂商写 `BIT(24)`（netsys v3 的 RX done） | 写 `rx.irq_done_mask` | 不一致 |

厂商 `mtk_hw_init` 中的原始逻辑（反汇编 0x6384c0–0x6386a0）：

```asm
mov  w5, #0x10000000                 ; BIT(28) = TX done
ldr  w1, [x24,#140]                  ; reg_map->qdma.int_grp (0x4620)
str  w5, [x0,x1]                     ; 0x4620 |= TX done  -> group0
...
csel w2, w2, w6, cc                  ; version<3 ? BIT(30) : BIT(24)
str  w2, [x0,x1]                     ; 0x4624 = RX done  -> group1
ldr  x4, [x4,#16]                    ; soc->caps
add  x6, x0, #0x20                   ; MTK_FE_INT_GRP
tbz  w4, #14, 638b20                 ; caps bit14(MTK_RSTCTRL_PPE1) == 0 -> 旧路径
mov  w1, #0xfff2 ; movk w1,#0x210f,lsl#16   ; 0x210ffff2
str  w1, [x6]                        ; FE_INT_GRP = 0x210ffff2   （PPE1 SoC 新路径）
...
638b20: ldr w1,[x24,#52]             ; reg_map->pdma.int_grp (0x6a50)  ← 仅旧路径才写
        ... 0x6a50/0x6a54 分组 ...
        mov w1,#0x1000 ; movk w1,#0x2102,lsl#16 ; MTK_FE_INT_GRP = 0x21021000
```

MT7987/MT7988 的 `caps` 最低 16 位为 `…0x5d94` / `…0x59bc`，bit14 均为 1 → **走 `0x210ffff2` 分支**。

## 2. 厂商 IRQ 注册布局（反汇编 `mtk_probe`，调用 `devm_request_threaded_irq`）

| DTS 资源 | handler | 备注 |
|---|---|---|
| irq[0]（hwirq 221） | `mtk_handle_irq`（TX+RX 合并） | 厂商额外注册 |
| irq[1]（hwirq 222） | `mtk_handle_irq_tx` | **TX 完成** |
| irq[2]（hwirq 223） | `mtk_handle_irq_rx` | RX |
| irq[3..7] | `mtk_handle_irq_rx`（`IRQF_SHARED`，per-queue） | 多队列 |

`mtk_probe` 用 `platform_get_irq(pdev, i)`（i=0..3）取第一批，再取 i+4（共 8 个），与厂商 DTB 的 8 个 `interrupts` 对应；DTB **没有** `interrupt-names`，所以主线的 `platform_get_irq_byname("fe1"/"fe2")` 会失败并回落到 legacy 位置映射——其结果与厂商一致（TX=资源 1、RX=资源 2）。

`mtk_handle_irq` 内部：读 `0x6a20`(pdma status) 与 `0x6a28`(mask)，用 `version>=3 ? BIT(24) : BIT(30)` 判 RX；再读 `0x461c`(mask) 与 `0x4618`(status) 用 `BIT(28)` 判 TX。

## 3. 本次改动（已生成正式补丁）

补丁文件：

```text
/build/imw/target/linux/mediatek/patches-6.12/997-h5000m-mt7987-eth-fixes.patch
（本地副本：build/997-h5000m-mt7987-eth-fixes.patch）
```

内容三项：

1. `mt7987_data.rx.irq_done_mask = MTK_RX_DONE_INT0 | MTK_RX_DONE_INT_V2`
   （原 750 补丁只有 `MTK_RX_DONE_INT_V2`；只清 `0x4000` 会残留 `BIT(16)` → RX IRQ 风暴 + RCU stall）
2. FE 中断分组按厂商逻辑：`MTK_RSTCTRL_PPE1` 类 SoC 写 `0x210ffff2` 且不碰 `pdma.int_grp`，否则保持原 `0x21021000` 路径；
   并打印 `MT7987 grouping: fe=… qgrp0=… qgrp1=… pgrp0=… pgrp1=…`
3. MT7987 额外把合并 handler 挂到 `irq[0]`（与厂商一致），TX/RX 仍走 `irq[1]`/`irq[2]`

被禁用的旧半成品补丁（已移到容器 /tmp，不再参与构建）：

```text
998-mt7987-ordered-ethernet-irqs.patch        ← 内容畸形，会导致 prepare 失败
```

## 4. 下一步验证（刷机后看串口）

```bash
dmesg | grep -E 'MT7987 IRQ map|MT7987 grouping|MT7987 QDMA init|MT7987 open|TX handler|WATCHDOG|Link is'
cat /proc/interrupts
ethtool -S eth0 ; ethtool -S eth1
ip -s link show eth0
```

判定：

- 出现 `MT7987 grouping: fe=0x210ffff2 …` → 补丁生效
- 若 `tx_packets` 开始增长、`NETDEV WATCHDOG` 消失 → TX 修复成功
- 若仍 watchdog，则下一批取证：`MT7987 Tx handler`/`MT7987 Tx NAPI` 是否触发、`0x4618` 是否出现 `BIT(28)`

---

## 5. 两轮实机验证结果（2026-10-04）

### v1 镜像（31f685fa…）：probe -EINVAL，无 eth
关键：本板 DTB **带 `interrupt-names = "fe0","fe1","fe2","fe3"`**，于是
`platform_get_irq_byname("fe1"/"fe2")` 成功 → `mtk_get_irqs()` 提前 `return 0`
→ `eth->irq[MTK_FE_IRQ_SHARED]` **保持 0**。
v1 把合并 handler 挂在 `eth->irq[SHARED]`(0) → `devm_request_irq(irq=0)`
→ **-EINVAL** → `probe with driver mtk_soc_eth failed with error -22`
→ 无 eth0/eth1，6.38s 另有一次 `PC=0` Oops（netdevice notifier 回调指针为 0）。

### v2 镜像（9eed5bab…）：probe 正常，但所有以太网中断消失
```
/proc/interrupts
 67:  0 0 0 0  GICv3 222 Level  15100000.ethernet
 68:  0 0 0 0  GICv3 223 Level  15100000.ethernet
ethtool -S eth0:  tx_packets=1  rx_packets=214
```
硬件在收发（MAC MIB 有值），但**两个 IRQ 计数全 0** → 中断投递整体失效。
结论：厂商的 `MTK_FE_INT_GRP = 0x210FFFF2`（+ 跳过 pdma.int_grp）依赖其自身
多队列/mask 方案，直接搬到我们的单队列配置会**掐死全部以太网中断** → 必须回退。
（同时 `eth0: … irq 0` 只是 `eth->irq[SHARED]==0` 的显示问题。）

### v3 镜像（f013da29…）：回退分组 + 全 IRQ 线安全 handler
- 回退 `MTK_FE_INT_GRP` 为原 `0x21021000` 路径
- 新增 `mtk_handle_irq_fe()`：仅在 `pdma/ qdma` 状态确实有我们拥有的位时才处理，
  否则返回 `IRQ_NONE`（内核会禁用该线而不会风暴），并打印
  `MT7987 fe irq=N UNHANDLED pdma_st=… pdma_msk=… qtx_st=… qtx_msk=… fe=…`
- MT7987 用 `platform_irq_count()` + `platform_get_irq(pdev,k)` 把该 handler
  挂到 DTB 的**全部 8 条**中断线上（覆盖 0..7 组），并打印 `MT7987: probing N IRQ resources`
- 保留 RX 掩码修复 `MTK_RX_DONE_INT0 | MTK_RX_DONE_INT_V2`

判定：dmesg 里出现哪条线有中断、`qtx_st` 是否出现 `BIT(28)`（TX 完成）；
若 8 条线全部无中断而 MAC 计数在动 → 说明 QDMA 根本不发 TX/RX 中断，
方向转向 QDMA/PSE 环与 descriptor 配置，而不是 IRQ 线选择。

---

## 6. 最终根因与修复（2026-10-04，已实机验证）

### 根因
MT7987 的以太网节点在 DTB 中提供 **8 个中断**：

```
idx 0..3 = SPI 189..192 -> hwirq 221..224   （interrupt-names fe0..fe3）
idx 4..7 = SPI 196..199 -> hwirq 228..231
```

实测（v3 镜像，把安全合并 handler 挂到全部 8 条线）：

```
 68: 4020  GICv3 223 Level  15100000.ethernet   ← RX  = idx 2 (fe2)
 74:  923  GICv3 229 Level  15100000.ethernet   ← TX完成 = idx 5 (SPI 197)
dmesg: MT7987 TX irq=74 qtx_st=0x10000001 qtx_msk=0x10000000   ← BIT(28) TX done 出现
```

主线/移植驱动只注册 **idx 1（经典 TX 槽，hwirq 222）与 idx 2（RX）**，
**从不注册 idx 5（SPI197 → hwirq 229）**，而 TX 完成恰恰在那条线上 →
所以 TX 完成永远无人处理 → `tx_packets=1` + `NETDEV WATCHDOG`。

> 这也解释了正常 OpenWrt 的 `/proc/interrupts`：hwirq 229 一直有明显计数；
> 以及厂商驱动为什么把 handler 挂在 0、1、2 和 4..7 全部线上。

### 最终补丁（`997-h5000m-mt7987-eth-fixes.patch`，v4）
1. `mt7987_data.rx.irq_done_mask = MTK_RX_DONE_INT0 | MTK_RX_DONE_INT_V2`
2. `mtk_get_irqs()`：MT7987 用资源 0/1/2 填 shared/TX/RX 槽（同时修掉 `eth0 … irq 0` 的显示）
3. 新增 `mtk_handle_irq_fe()`：合并安全 handler，无匹配源时返回 `IRQ_NONE`（不会风暴，只会打印/禁用该线）
4. MT7987 用 `platform_irq_count()` 把该 handler 注册到 **DTB 的全部 8 条中断线**

### 被证伪的两条假设（务必不要再走）
- 厂商 `MTK_FE_INT_GRP = 0x210FFFF2`（+跳过 pdma.int_grp）：在单队列配置下会**掐死全部以太网中断**（v2 实测两 IRQ 计数全 0）。
- `mac@2`/HNAT/PPE/WED 与 TX 无关（早期已证）：TX 根因就是 IRQ 线选择。

### 可用镜像
```text
build/images/build-h5000m-udev-20261004-083859/   eth-only + pci=off（已验证上网/SSH）
build/images/build-h5000m-udev-20261004-085503/   正式版（8 中断 DTB + PCIe 开启）
```

### 注意：DTB 陷阱
```text
/tmp/mt7987a-hiveton-h5000m.dtb          只有 4 个中断（SPI196-199）—— 不能用
/tmp/mt7987a-hiveton-h5000m-2mac.dtb     8 个中断 + interrupt-names ✅（与厂商一致）
/tmp/mt7987a-hiveton-h5000m-eth-only.dtb 8 个中断 + PCIe disabled（隔离测试用）
```

---

## 7. Wi‑Fi 与有线 HNAT 现状（2026-10-04，正式镜像已含修复）

### 有线以太网
已修复并实机验证（见第 6 节）：TX 完成走 DTS 中断索引 5（SPI197 → hwirq 229），
补丁把安全合并 handler 注册到全部 8 条中断线后，`tx_packets` 正常增长、无 WATCHDOG。

### 有线 HNAT（PPE 硬件卸载）
- 内核侧就绪：`/sys/kernel/debug/ppe0`、`ppe1`、`wed0` 均存在（`mtk_ppe_init` 在 probe 内完成）；
  `nf_flow_table.ko` / `nft_flow_offload.ko` / `nf_tables.ko` / `nf_conntrack.ko` 都在
  `/lib/modules/6.12.103/`。
- 缺用户态 → 新镜像已装 `nftables` 并落盘 `/etc/nftables.conf`：
  `table inet hwnat { flowtable f { hook ingress priority 0; devices = { eth0, eth1 } }
   chain forward { ... flow add @f } }`，并启用 `nftables.service`、`net.ipv4.ip_forward=1`。
  ⚠️ 表名不能叫 `offload`（nftables 保留字）。
- 验证方法：eth1（2.5G 口）插网线并构成 eth0↔eth1 转发路径后，
  `cat /sys/kernel/debug/ppe0/bind` 应出现已绑定（硬件加速）的流。
- 主线不需要厂商的 `eth2`/`hnat` netdev；PPE 卸载直接挂在普通 netdev 上。
- 打包注意：`mkfs.ext4 -d` 前必须把 chroot 里的 /proc /sys /dev 卸载，否则打包失败。

### Wi‑Fi（MT7992 / mt7996e）
- PCIe 设备、WM/DSP/WA 固件全部正常；**`/sys/class/ieee80211/phy0` 已注册**。
- mac80211 未自动建 vif → `iw phy phy0 interface add wlan0 type managed && ip link set wlan0 up`
  即可用（实测成功，addr 00:0c:43:26:60:10，type managed）。
  新镜像已加 `h5000m-wifi-vif.service` 开机自动创建。
- **未解决**：EEPROM 校准。dmesg 报
  `eeprom tx_power zeros detected, using defaults` + `eeprom load fail, use default bin`，
  驱动退回到通用默认 EEPROM → `txpower` 只有 **5.00 dBm**（正常应 ~20 dBm）。
  真实校准在 eMMC factory 分区（厂商 DTB 的 `eeprom_factory_0` nvmem cell），
  下一步：给 PCIe/WiFi 节点加 `nvmem-cells = <&eeprom_factory_0>; nvmem-cell-names = "eeprom";`
  （mt76 的 `mt76_eeprom_init()` 支持从 nvmem 读取），或把 factory 校准导出成
  `/lib/firmware/mediatek/mt7996/mt7992_eeprom_23.bin`。
- 新镜像已补齐所有 EEPROM 变体：`mt7992_eeprom.bin`、`_2i5i`、`_2i5e`、`_23`、`_23_2i5i`、
  `mt7996_eeprom.bin`、`mt7996_eeprom_2i5i6i.bin`（此前只有 `_23` 两个，驱动请求的普通名缺失）。

### 镜像
```text
build/images/build-h5000m-udev-20261004-093313/debian-13-h5000m-udev.bin
SHA-256 eacce1c4a1c7e0566f24cce37bce8892824e4fc3bb744c40ae73bf9c6d6532c9
```

---

## 8. 无线侧的 HNAT（WED/WARP）逆向结论（2026-10-04）

### 厂商 OpenWrt 6.6.94 的无线加速栈

对保存的厂商模块做符号/字符串分析：

```text
mtk_wed.ko (18KB, .text 仅 7.7KB) —— 薄壳
  字符串/调用: wed_request_irq, wed_drv_create_tunnel, wed_pci_rxq_get,
               wed_get_hif_txd_ver, WED_TX_RING, "More than one TxFreeDone ring",
               "%s-wed", "WED ver = %u, subver = %u not found", fmac_hif_txd_init
  外部符号: warp_isr_handler, warp_dma_handler(_after_fwdl), warp_wlan_tx/rx,
            warp_ring_init/exit, warp_rro_write_dma_idx, warp_mcu_wo_support,
            warp_proxy_read/write, warp_set_pao_sta_info, warp_set_pn_check,
            warp_512_support_handler, warp_register_client, mtk_bus_rx_ser_event …

mtk_warp.ko (287KB, .text 0x15c00) —— 真正的 WED/WARP 引擎（warp_* 全套）
   ↓ 依赖
mtkhnat.ko  —— PPE/HNAT 表管理
   ↓
mt_wifi / mt7992 / mtk_hwifi / connac_if / mtk_pci  —— 厂商 WiFi 驱动
```

依赖关系（modinfo）：`mtk_warp → mtkhnat`，`mtk_wed → mtk_warp,mtk_hwifi`，`mt_wifi → mtkhnat`。

### 结论：无法从二进制移植，也不在主线上游支持范围内

- 无线加速的真实实现是**闭源厂商引擎**（`mtk_warp` + `mtk_wed`），只以 6.6 ABI 的 .ko 形式存在；
- 主线 6.12 的 `mtk_wed` 没有 MT7987/WARP 支持（驱动里只有 mt7981/7986/7988 相关），
  `wed_enable=1` 时 attach 失败在 `mtk_wed_device_attach()` 内部（rro/wo 分配需要 MT7988 式
  `mediatek,wo-ccif` + wo 保留内存，MT7987 厂商 DT 并未描述）；
- 该引擎与厂商 `mt_wifi` 驱动栈强耦合（`mtk_bus_rx_ser_event`、`fmac_hif_txd_init` 等），
  只移植 WED 而不移植整栈没有意义。

### 现实选项

| 方案 | 结果 | 代价 |
|---|---|---|
| A. 保持现状（主线 mt76 + hostapd/networkd） | Debian 原生 WiFi 可用；Wi‑Fi 走 **CPU 软件转发**（A53×4，几百 Mbps）；有线仍有 PPE 硬件卸载（`flags offload`） | 无 |
| B. Debian userspace + 厂商 6.6 内核 | 厂商 WED/HNAT 与 mt_wifi 全套可用 | 需要厂商 6.6 内核 + 全部厂商 .ko（已备份）+ 厂商 WiFi 用户态（nvram/iwpriv 那套 OpenWrt 脚本），工作量大且失去 Debian 原生 WiFi 管理 |
| C. 移植 WARP 引擎 | —— | 无源码，不可行 |

**当前建议：A**（已实现并验证：双频开放 AP、5G USB 模组、有线 HNAT、风扇温控、eMMC 扩容 + 1G swap）。
