# ==================================================================
# airoha-wed — Airoha AN7581 WED (Wi-Fi Offload Engine) driver
#
#   SoC-side peer of the mt_whnat WOE/WED driver, and the missing half of
#   mainline mt76's mt7915 WED support: on AN7581 mtk_eth_soc never probes,
#   so nothing fills the global mtk_soc_wed_ops pointer and mt76 keeps the
#   offload path disabled. This package fills it.
#
#   Stage 1 (done): probe, ioremap, register dump.
#   Stage 3b (this): publish the ops table with attach/tx_ring_setup/
#   rx_ring_setup/txfree_ring_setup/start/stop/detach, following mainline's
#   WED-v1 (mt7622) sequence -- the block reads back WED_REV 0x76220001.
#
#   Deliberately shipped with attach_enable=0 (dry run). The ops table is
#   published but attach() refuses after programming the hardware, so
#   mtk_wed_device_active() stays false, mt76 never offloads and Wi-Fi runs
#   exactly as before. Flipping a module parameter and rebooting is enough
#   to try the real thing -- no reflash needed either way.
#
#   Load priority 05 puts it ahead of mt7915e (which sorts later, having no
#   numeric prefix) so the ops table exists before mt76 probes.
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
  TITLE:=Airoha AN7581 WED (Wi-Fi downlink offload, SoC side)
  DEPENDS:=@TARGET_airoha
  FILES:=$(PKG_BUILD_DIR)/airoha-wed.ko
  AUTOLOAD:=$(call AutoLoad,05,airoha-wed,wed_ops=1 attach_enable=0)
endef

define KernelPackage/airoha-wed/description
  Drives the two MT7622-derived Wi-Fi Offload Engine blocks inside the
  Airoha AN7581 (0x1fa02000 / 0x1fa03000) and publishes an mtk_soc_wed_ops
  table so mainline mt76's mt7915 WED hooks can offload the Wi-Fi downlink.
  Register dump at /sys/kernel/debug/airoha-wed/regs.

  Ships in dry-run mode (attach_enable=0): the hardware is programmed and
  read back, then attach() fails on purpose, so Wi-Fi stays software-only.
  Set attach_enable=1 to actually offload.
endef

define KernelPackage/airoha-wdma
  SECTION:=kernel
  CATEGORY:=Kernel modules
  SUBMENU:=Wireless Drivers
  TITLE:=Airoha AN7581 WDMA rings (Wi-Fi downlink offload, SoC side)
  DEPENDS:=@TARGET_airoha +kmod-airoha-wed
  FILES:=$(PKG_BUILD_DIR)/airoha-wdma.ko
  AUTOLOAD:=$(call AutoLoad,06,airoha-wdma)
endef

define KernelPackage/airoha-wdma/description
  Claims the companion WDMA block (0x1fa06000 / 0x1fa06400), allocates
  its two 1024-entry RX descriptor rings per instance and starts the RX
  DMA engine, with a dump at /sys/kernel/debug/airoha-wdma/regs.

  Does not register an mtk_soc_wed_ops table yet, so mainline mt76 keeps
  the WED path disabled and normal Wi-Fi behaviour is untouched. With
  flow_offloading_hw=0 no packet reaches PSE port 3, so the started WDMA
  simply idles on an empty queue.
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
$(eval $(call KernelPackage,airoha-wdma))
