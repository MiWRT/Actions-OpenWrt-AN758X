/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Register definitions for the WDMA block that feeds the MT7622-derived
 * WED inside the Airoha AN7581.
 *
 * Two independent sources agree on this layout, which is why it can be
 * trusted without a datasheet:
 *
 *   1. airoha_wed_wdma/wdma.h (mt_whnat WOE/WED driver) -- written for this
 *      exact SoC. It even records the relocated bases:
 *          "WDMA0 Base: 0x1FA06000 //ECNT
 *           WDMA1 Base: 0x1FA06400 //ECNT"
 *      and the per-instance register offset cookies
 *          WDMA0_OFST0 0x2a042a20   WDMA0_OFST1 0x29002800
 *          WDMA1_OFST0 0x2e042e20   WDMA1_OFST1 0x2d002c00
 *
 *   2. mainline drivers/net/ethernet/mediatek/mtk_wed_regs.h (v6.18), whose
 *      MT7622 (WED version 1) path writes *exactly* those cookies:
 *          wed_w32(dev, MTK_WED_WDMA_OFFSET0, 0x2a042a20 + offset);
 *          wed_w32(dev, MTK_WED_WDMA_OFFSET1, 0x29002800 + offset);
 *              with offset = index ? 0x04000400 : 0
 *      and defines the ring block as
 *          MTK_WDMA_RING_RX(_n) (0x100 + (_n) * 0x10)
 *          MTK_WDMA_GLO_CFG     0x204
 *
 *  0x2a042a20 + 0x04000400 == 0x2e042e20, so WDMA1 is literally WDMA0 plus
 *  0x400 -- the same stride as the DT reg property. The IP is identical.
 *
 * Cross-checked on real hardware 2026-10-02:
 *      devmem 0x1fa06200 -> 0x3c000204   (WDMA_INFO)
 *      devmem 0x1fa06600 -> 0x3c000204   (second instance, same)
 *  0x3c000204 decodes as REV=3, INDEX_WIDTH=12 (4096 entries),
 *  BASE_PTR_WIDTH=0, RX_RING_NUM=2, TX_RING_NUM=4.
 */
#ifndef _AIROHA_WDMA_H
#define _AIROHA_WDMA_H

#include <linux/bits.h>

/* Ring registers. Each ring occupies 0x10 bytes:
 *   +0x00 base pointer   +0x04 max count
 *   +0x08 CPU index      +0x0c DMA index
 * Stride and layout identical to mainline MTK_WDMA_RING_RX(). */
#define AIROHA_WDMA_RING_RX(_n)		(0x100 + (_n) * 0x10)
#define AIROHA_WDMA_RING_TX(_n)		(0x000 + (_n) * 0x10)
#define AIROHA_WDMA_RING_OFS_BASE	0x00
#define AIROHA_WDMA_RING_OFS_COUNT	0x04
#define AIROHA_WDMA_RING_OFS_CPU_IDX	0x08
#define AIROHA_WDMA_RING_OFS_DMA_IDX	0x0c

#define AIROHA_WDMA_INFO		0x200
#define AIROHA_WDMA_INFO_REV		GENMASK(31, 28)
#define AIROHA_WDMA_INFO_INDEX_WIDTH	GENMASK(27, 24)
#define AIROHA_WDMA_INFO_BASE_PTR_WIDTH	GENMASK(23, 16)
#define AIROHA_WDMA_INFO_RX_RING_NUM	GENMASK(15, 8)
#define AIROHA_WDMA_INFO_TX_RING_NUM	GENMASK(7, 0)

#define AIROHA_WDMA_GLO_CFG		0x204
#define AIROHA_WDMA_GLO_RX_2B_OFFSET		BIT(31)
#define AIROHA_WDMA_GLO_CSR_CLKGATE_BYP		BIT(30)
#define AIROHA_WDMA_GLO_BYTE_SWAP		BIT(29)
#define AIROHA_WDMA_GLO_RX_INFO1_PRERES		BIT(28)
#define AIROHA_WDMA_GLO_RX_INFO2_PRERES		BIT(27)
#define AIROHA_WDMA_GLO_RX_INFO3_PRERES		BIT(26)
#define AIROHA_WDMA_GLO_TX_WB_DDONE		BIT(6)
#define AIROHA_WDMA_GLO_RX_DMA_BUSY		BIT(3)
#define AIROHA_WDMA_GLO_RX_DMA_EN		BIT(2)
#define AIROHA_WDMA_GLO_TX_DMA_BUSY		BIT(1)
#define AIROHA_WDMA_GLO_TX_DMA_EN		BIT(0)

#define AIROHA_WDMA_RST_IDX		0x208
#define AIROHA_WDMA_RST_DRX_IDX(_n)	BIT(16 + (_n))
#define AIROHA_WDMA_RST_DTX_IDX(_n)	BIT(_n)

#define AIROHA_WDMA_DELAY_INT_CFG	0x20c
#define AIROHA_WDMA_FREEQ_THRES		0x210
#define AIROHA_WDMA_INT_STA_REC		0x220
#define AIROHA_WDMA_INT_MSK		0x228
#define AIROHA_WDMA_INT_STS_GRP0	0x240
#define AIROHA_WDMA_INT_STS_GRP1	0x244
#define AIROHA_WDMA_INT_STS_GRP2	0x248
#define AIROHA_WDMA_INT_GRP1		0x250
#define AIROHA_WDMA_INT_GRP2		0x254

/*
 * RX consumer (CRX) index counters. whnat's woe_hw.c clears both right after
 * WDMA_RST_IDX while draining a stop sequence: resetting the DRX index alone
 * leaves the consumer pointers stale, and the frames they already reference
 * stay pinned in the FE (PSE) shared buffer.
 */
#define AIROHA_WDMA_RX_CRX_IDX0	0x108
#define AIROHA_WDMA_RX_CRX_IDX1	0x118
#define AIROHA_WDMA_SCH_Q01_CFG		0x280
#define AIROHA_WDMA_SCH_Q23_CFG		0x284

/* The WED-side mirror of those RX rings lives in airoha-wed-regs.h
 * (AIROHA_WED_WDMA_RING_RX), next to the rest of the WED window. */

/* Descriptor layout, 16 bytes.
 *
 * mt_whnat names the second word's fields res1/sdl0/ls/ddone. Read its two
 * endian variants against each other (the BE one lists ddone first, i.e.
 * MSB) and both resolve to: ddone = bit 31, ls = bit 30, sdl0 = bits 29:16.
 * That is mainline's MTK_WDMA_DESC_CTRL_* layout verbatim, so the two
 * sources agree here too. */
#define AIROHA_WDMA_RXD_SIZE		16
#define AIROHA_WDMA_DESC_CTRL_DMA_DONE	BIT(31)
#define AIROHA_WDMA_DESC_CTRL_LAST_SEG0	BIT(30)
#define AIROHA_WDMA_DESC_CTRL_LEN0	GENMASK(29, 16)
#define AIROHA_WDMA_DESC_CTRL_BURST	BIT(16)
#define AIROHA_WDMA_DESC_CTRL_LAST_SEG1	BIT(15)
#define AIROHA_WDMA_DESC_CTRL_LEN1	GENMASK(14, 0)

/* Ring geometry. 1024 comes from mt_whnat's WDMA_TX_BM_RING_SIZE and from
 * mainline's MTK_WED_WDMA_RING_SIZE; 2 rings is both WDMA_INFO's
 * RX_RING_NUM and MTK_WED_RX_QUEUES. */
#define AIROHA_WDMA_RX_RINGS		2
#define AIROHA_WDMA_RING_SIZE		1024

/* The PSE port whose output queue feeds this block.
 * mt_whnat: "#define WHNAT_WDMA_PORT 3"; the SDK force-port table agrees
 * (FP_WDMA == FP_GDMA3 == 3). This is the number the airoha PPE must be
 * told instead of CDM4 (7) for the WiFi downlink to reach the WDMA at all. */
#define AIROHA_WDMA_PSE_PORT		3

#endif /* _AIROHA_WDMA_H */
