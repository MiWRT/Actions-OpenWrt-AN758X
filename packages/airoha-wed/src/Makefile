# SPDX-License-Identifier: GPL-2.0-only
# kbuild stub for the Airoha AN7581 WED bring-up modules.
#
# airoha-wed  : register probe for the two MT7622-derived WED blocks,
#               plus the mtk_soc_wed_ops table (airoha-wed-ops.c)
# airoha-wdma : RX ring allocator / starter for the WDMA that feeds them
airoha-wed-objs := airoha-wed-main.o airoha-wed-ops.o
obj-m += airoha-wed.o
obj-m += airoha-wdma.o
