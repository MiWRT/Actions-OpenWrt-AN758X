/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Register definitions for the MediaTek MT7622-derived WED
 * (Wi-Fi Offload Engine) instances embedded in the Airoha AN7581.
 *
 * Source of truth for these offsets: wed_def.h from the "mt_whnat"
 * WOE/WED driver tree (airoha_wed_wdma), whose banner comment records the
 * original SoC address 1020A000. The same IP was relocated to 0x1fa02000
 * on AN7581, hence WED_REG_BASE is 0: offsets are relative to the DT window.
 *
 * Only the small control/status window is described here -- enough to
 * identify the block and observe what the firmware left behind. Ring and
 * buffer-manager registers will be added as each hardware path is enabled.
 */
#ifndef _AIROHA_WED_REGS_H
#define _AIROHA_WED_REGS_H

/* GENMASK comes from here; the macros below are expanded at the call site,
 * but making the dependency explicit keeps the header self-contained. */
#include <linux/bits.h>

#define AIROHA_WED_REG_BASE		0

#define AIROHA_WED_REV			(AIROHA_WED_REG_BASE + 0x00000000)
#define AIROHA_WED_MOD_RST		(AIROHA_WED_REG_BASE + 0x00000008)
#define AIROHA_WED_CTRL			(AIROHA_WED_REG_BASE + 0x0000000c)
#define AIROHA_WED_AXI_CTRL		(AIROHA_WED_REG_BASE + 0x00000010)
#define AIROHA_WED_CTRL2		(AIROHA_WED_REG_BASE + 0x0000001c)
#define AIROHA_WED_EX_INT_STA		(AIROHA_WED_REG_BASE + 0x00000020)
#define AIROHA_WED_EX_INT_MSK		(AIROHA_WED_REG_BASE + 0x00000028)
#define AIROHA_WED_IRQ_MON		(AIROHA_WED_REG_BASE + 0x00000050)
#define AIROHA_WED_ST			(AIROHA_WED_REG_BASE + 0x00000060)
#define AIROHA_WED_WPDMA_ST		(AIROHA_WED_REG_BASE + 0x00000064)
#define AIROHA_WED_WDMA_ST		(AIROHA_WED_REG_BASE + 0x00000068)
#define AIROHA_WED_BM_ST		(AIROHA_WED_REG_BASE + 0x0000006c)
#define AIROHA_WED_TX_BM_CTRL		(AIROHA_WED_REG_BASE + 0x00000080)
#define AIROHA_WED_TX_BM_BASE		(AIROHA_WED_REG_BASE + 0x00000084)
#define AIROHA_WED_TX_BM_TKID		(AIROHA_WED_REG_BASE + 0x00000088)
#define AIROHA_WED_TX_BM_BLEN		(AIROHA_WED_REG_BASE + 0x0000008c)
#define AIROHA_WED_TX_BM_STS		(AIROHA_WED_REG_BASE + 0x00000090)
#define AIROHA_WED_TXDP_CTRL		(AIROHA_WED_REG_BASE + 0x00000130)
#define AIROHA_WED_INT_STA		(AIROHA_WED_REG_BASE + 0x00000200)
#define AIROHA_WED_INT_MSK		(AIROHA_WED_REG_BASE + 0x00000204)
#define AIROHA_WED_GLO_CFG		(AIROHA_WED_REG_BASE + 0x00000208)
#define AIROHA_WED_RST_IDX		(AIROHA_WED_REG_BASE + 0x0000020c)
#define AIROHA_WED_DLY_INT_CFG		(AIROHA_WED_REG_BASE + 0x00000210)
#define AIROHA_WED_SPR			(AIROHA_WED_REG_BASE + 0x0000021c)
#define AIROHA_WED_TX0_MIB		(AIROHA_WED_REG_BASE + 0x000002a0)
#define AIROHA_WED_TX1_MIB		(AIROHA_WED_REG_BASE + 0x000002a4)

/* WED_REV fields -- observed on-device: 0x76220001 */
#define AIROHA_WED_REV_ID		GENMASK(31, 16)
#define AIROHA_WED_REV_SUB_ID		GENMASK(15, 0)

/*
 * Must match WED_REV's 31:16 as read from real hardware so that a broken
 * DT window (wrong base address) is reported loudly instead of silently
 * looking like an uninitialised block.
 */
#define AIROHA_WED_EXPECTED_REV_ID	0x7622

#endif /* _AIROHA_WED_REGS_H */
