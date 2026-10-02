# ==================================================================
# airoha-wed — Airoha AN7581 WED (Wi-Fi Offload Engine) probe
#
#   SoC-side peer of the mt_whnat WOE/WED driver. This package is stage 1
#   of bringing up the Wi-Fi downlink offload path and is intentionally
#   read-only: claim the platform device, ioremap the register windows,
#   report and expose a debugfs dump.
#
#   It does NOT yet register an mtk_soc_wed_ops table, so mainline mt76's
#   mt7915 WED hooks stay inactive and normal Wi-Fi behaviour is untouched.
#   Later stages add tx/rx ring setup and that registration; switching it
#   on before the ring helpers exist would make mt7915 take paths that
#   cannot work.
#
#   目录名必须等于包名（buildroot 约定 PKG_NAME ?= $(notdir ${CURDIR})）。
# ==================================================================
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

PKG_NAME:=airoha-wed
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

define KernelPackage/airoha-wed
  SECTION:=kernel
  CATEGORY:=Kernel modules
  SUBMENU:=Wireless Drivers
  TITLE:=Airoha AN7581 WED/WDMA bring-up (probe + WDMA rings)
  DEPENDS:=@TARGET_airoha
  FILES:=$(PKG_BUILD_DIR)/airoha-wed.ko $(PKG_BUILD_DIR)/airoha-wdma.ko
  AUTOLOAD:=$(call AutoProbe,airoha-wed,airoha-wdma)
endef

define KernelPackage/airoha-wed/description
  Bring-up modules for the Wi-Fi downlink offload path on the Airoha
  AN7581.

  airoha-wed probes the two MT7622-derived Wi-Fi Offload Engine blocks
  (0x1fa02000 / 0x1fa03000), reports WED_REV for each and exposes a full
  register dump at /sys/kernel/debug/airoha-wed/regs. Read-only.

  airoha-wdma claims the companion WDMA block (0x1fa06000 / 0x1fa06400),
  allocates its two 1024-entry RX descriptor rings and starts the RX DMA
  engine, with a dump at /sys/kernel/debug/airoha-wdma/regs.

  Neither module registers an mtk_soc_wed_ops table yet, so mainline mt76
  keeps the WED path disabled and normal Wi-Fi behaviour is untouched.
  With flow_offloading_hw=0 no packet reaches PSE port 3, so the started
  WDMA simply idles on an empty queue.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
endef

define Build/Compile
	+$(MAKE) -C "$(LINUX_DIR)" \
		$(KERNEL_MAKE_FLAGS) \
		M="$(PKG_BUILD_DIR)" \
		modules
endef

$(eval $(call KernelPackage,airoha-wed))
