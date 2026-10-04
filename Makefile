# Hiveton H5000M —— Debian 13 (ARM64) 镜像构建
SHELL := /bin/bash
BSP_COMMIT ?= 428fbc3b9920866daa5c1b2753849a6d49ed96ef
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu)

.PHONY: all bsp patches check kernel rootfs panel package clean distclean

all: rootfs package

## 拉 BSP（pin 提交）
bsp:
	scripts/fetch-bsp.sh

## 打补丁（BSP config/DTS + 内核 997/998 + .config）
patches: bsp
	scripts/apply-bsp-patches.sh

## 快速校验补丁可应用性（不需要 BSP，CI 用）
check:
	scripts/check-patches.sh

## 完整内核构建（tools + toolchain + kernel + modules，40~90 分钟）
kernel: patches
	scripts/build-kernel.sh $(JOBS)

## Debian rootfs（debootstrap + 包 + overlay + 面板）
rootfs:
	scripts/debootstrap-rootfs.sh
	PANEL_TARBALL="$$(ls -t build/h5000m-mt5700-panel-*.tar.gz 2>/dev/null | head -1)" \
	OWROOT="$(OWROOT)" scripts/build-rootfs.sh

## 面板（从 h5000m-mt5700-panel 仓库 release 拉取）
panel:
	scripts/fetch-panel.sh

## 打包刷机镜像
package:
	scripts/package-image.sh

clean:
	rm -rf build/check out

distclean: clean
	rm -rf bsp rootfs
