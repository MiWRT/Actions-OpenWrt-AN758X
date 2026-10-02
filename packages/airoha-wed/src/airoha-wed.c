// SPDX-License-Identifier: GPL-2.0-only
/*
 * Airoha AN7581 WED (Wi-Fi Offload Engine) register probe.
 *
 * STAGE 1 of the WED downlink bring-up. This driver deliberately does
 * *nothing* except claim the platform device, ioremap the register windows
 * and report what the block contains. It writes no registers, requests no
 * interrupt and touches no DMA, so loading it cannot disturb Wi-Fi.
 *
 * The point of this stage is to prove, on real hardware, that:
 *   1. the DT nodes describe something that exists and is clocked;
 *   2. every register window resolves to the right address (a relocated IP
 *      block that reads as all-zeroes or all-ones is the classic failure);
 *   3. both WED instances are distinct -- two instances accidentally mapped
 *      onto the same window would poison every later stage.
 *
 * Later stages add tx_ring_setup / rx_ring_setup / start / stop and finally
 * register an mtk_soc_wed_ops table, at which point mainline mt76's existing
 * mt7915 WED hooks activate. None of that exists yet, on purpose: an ops
 * table that advertises attach() while the ring helpers are unimplemented
 * would make mt7915 take WED paths that cannot work.
 *
 * Evidence that motivated this (2026-10-02, on the target board):
 *   devmem 0x1fa02000 -> 0x76220001   MT7622 rev 1, first instance
 *   devmem 0x1fa03000 -> 0x76220001   second instance, same IP
 *   devmem 0x1fa0200c -> 0x01000000   WED_CTRL
 *   devmem 0x1fa0201c -> 0x00000020   WED_CTRL2
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/io.h>
#include <linux/slab.h>
#include <linux/debugfs.h>
#include <linux/seq_file.h>
#include <linux/bitfield.h>

#include "airoha-wed-regs.h"

#define DRV_NAME			"airoha-wed"
#define AIROHA_WED_MAX_BANKS		2

struct airoha_wed_bank {
	void __iomem		*base;
	unsigned long long	 phys;
	unsigned long long	 size;
	int			 irq;
	u32			 rev;
	u32			 slot;
};

struct airoha_wed {
	struct device		*dev;
	u8			 nbank;
	struct airoha_wed_bank	 bank[AIROHA_WED_MAX_BANKS];
	struct dentry		*dbgfs;
};

static inline u32 airoha_wed_read(const struct airoha_wed_bank *b, u32 reg)
{
	return readl(b->base + reg);
}

/* Registers worth dumping: identification plus everything we already know
 * reads non-zero on this board. Grouped so a future diff of two snapshots
 * shows only what actually moved. */
static const struct {
	const char	*name;
	u32		 off;
} airoha_wed_dump_regs[] = {
	{ "WED_REV",		AIROHA_WED_REV		},
	{ "WED_MOD_RST",	AIROHA_WED_MOD_RST	},
	{ "WED_CTRL",		AIROHA_WED_CTRL		},
	{ "WED_AXI_CTRL",	AIROHA_WED_AXI_CTRL	},
	{ "WED_CTRL2",		AIROHA_WED_CTRL2	},
	{ "WED_EX_INT_STA",	AIROHA_WED_EX_INT_STA	},
	{ "WED_EX_INT_MSK",	AIROHA_WED_EX_INT_MSK	},
	{ "WED_IRQ_MON",	AIROHA_WED_IRQ_MON	},
	{ "WED_ST",		AIROHA_WED_ST		},
	{ "WED_WPDMA_ST",	AIROHA_WED_WPDMA_ST	},
	{ "WED_WDMA_ST",	AIROHA_WED_WDMA_ST	},
	{ "WED_BM_ST",		AIROHA_WED_BM_ST	},
	{ "WED_TX_BM_CTRL",	AIROHA_WED_TX_BM_CTRL	},
	{ "WED_TX_BM_BASE",	AIROHA_WED_TX_BM_BASE	},
	{ "WED_TX_BM_TKID",	AIROHA_WED_TX_BM_TKID	},
	{ "WED_TX_BM_BLEN",	AIROHA_WED_TX_BM_BLEN	},
	{ "WED_TX_BM_STS",	AIROHA_WED_TX_BM_STS	},
	{ "WED_TXDP_CTRL",	AIROHA_WED_TXDP_CTRL	},
	{ "WED_INT_STA",	AIROHA_WED_INT_STA	},
	{ "WED_INT_MSK",	AIROHA_WED_INT_MSK	},
	{ "WED_GLO_CFG",	AIROHA_WED_GLO_CFG	},
	{ "WED_RST_IDX",	AIROHA_WED_RST_IDX	},
	{ "WED_DLY_INT_CFG",	AIROHA_WED_DLY_INT_CFG	},
	{ "WED_SPR",		AIROHA_WED_SPR		},
	{ "WED_TX0_MIB",	AIROHA_WED_TX0_MIB	},
	{ "WED_TX1_MIB",	AIROHA_WED_TX1_MIB	},
};

static int airoha_wed_regs_show(struct seq_file *s, void *unused)
{
	struct airoha_wed *wed = s->private;
	int i, k;

	for (i = 0; i < wed->nbank; i++) {
		const struct airoha_wed_bank *b = &wed->bank[i];

		seq_printf(s, "WED%d\n", i);
		seq_printf(s, "  base    : 0x%llx (%llu bytes)\n", b->phys, b->size);
		seq_printf(s, "  irq     : %d\n", b->irq);
		seq_printf(s, "  slot    : %u\n", b->slot);
		seq_printf(s, "  rev     : 0x%08x\n", b->rev);
		if (!b->base)
			continue;

		for (k = 0; k < ARRAY_SIZE(airoha_wed_dump_regs); k++)
			seq_printf(s, "  %-16s +0x%03x : 0x%08x\n",
				   airoha_wed_dump_regs[k].name,
				   airoha_wed_dump_regs[k].off,
				   airoha_wed_read(b, airoha_wed_dump_regs[k].off));
	}

	return 0;
}

DEFINE_SHOW_ATTRIBUTE(airoha_wed_regs);

static void airoha_wed_report(struct airoha_wed *wed)
{
	struct device *dev = wed->dev;
	int i;

	for (i = 0; i < wed->nbank; i++) {
		struct airoha_wed_bank *b = &wed->bank[i];
		u32 rev_id = FIELD_GET(AIROHA_WED_REV_ID, b->rev);

		dev_info(dev,
			 "WED%d window 0x%llx + 0x%llx irq=%d slot=%u\n",
			 i, b->phys, b->size, b->irq, b->slot);
		dev_info(dev, "WED%d WED_REV = 0x%08x (id 0x%04x, sub-id 0x%04x)\n",
			 i, b->rev, rev_id,
			 FIELD_GET(AIROHA_WED_REV_SUB_ID, b->rev));

		if (rev_id != AIROHA_WED_EXPECTED_REV_ID)
			dev_warn(dev,
				 "WED%d unexpected revision id 0x%04x, expected 0x%04x -- DT window likely wrong\n",
				 i, rev_id, AIROHA_WED_EXPECTED_REV_ID);

		dev_info(dev, "WED%d WED_CTRL = 0x%08x WED_CTRL2 = 0x%08x WED_ST = 0x%08x\n",
			 i,
			 airoha_wed_read(b, AIROHA_WED_CTRL),
			 airoha_wed_read(b, AIROHA_WED_CTRL2),
			 airoha_wed_read(b, AIROHA_WED_ST));
	}

	/* Guarding against a copy/paste DT error: the two instances must not
	 * resolve to the same physical window, otherwise every later stage
	 * would programme one block twice and leave the other untouched. */
	for (i = 1; i < wed->nbank; i++) {
		if (wed->bank[i].phys == wed->bank[0].phys)
			dev_err(dev,
				"WED0 and WED%d share the same window (0x%llx) -- DT reg entries are wrong\n",
				i, wed->bank[i].phys);
	}
}

static int airoha_wed_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *np = dev->of_node;
	struct airoha_wed *wed;
	u32 val;
	int i, nresource;

	wed = devm_kzalloc(dev, sizeof(*wed), GFP_KERNEL);
	if (!wed)
		return -ENOMEM;
	wed->dev = dev;
	platform_set_drvdata(pdev, wed);

	if (of_property_read_u32(np, "wed_num", &val)) {
		dev_info(dev, "wed_num not set, assuming %u instances\n",
			 AIROHA_WED_MAX_BANKS);
		val = AIROHA_WED_MAX_BANKS;
	}
	if (!val || val > AIROHA_WED_MAX_BANKS) {
		dev_err(dev, "wed_num=%u out of range (1..%d)\n", val,
			AIROHA_WED_MAX_BANKS);
		return -EINVAL;
	}
	wed->nbank = (u8)val;

	for (i = 0; i < wed->nbank; i++) {
		if (of_property_read_u32_index(np, "pci_slot_map", i, &val))
			val = i;	/* absence means identity mapping */
		wed->bank[i].slot = (u32)val;
	}

	for (i = 0; i < wed->nbank; i++) {
		struct airoha_wed_bank *b = &wed->bank[i];
		struct resource *res;

		res = platform_get_resource(pdev, IORESOURCE_MEM, i);
		if (!res) {
			dev_err(dev, "WED%d: missing DT reg entry %d\n", i, i);
			return -ENODEV;
		}

		b->base = devm_ioremap_resource(dev, res);
		if (IS_ERR(b->base)) {
			dev_err_probe(dev, PTR_ERR(b->base),
				      "WED%d: cannot map 0x%llx\n", i,
				      (unsigned long long)res->start);
			return PTR_ERR(b->base);
		}

		b->phys = (unsigned long long)res->start;
		b->size = (unsigned long long)resource_size(res);
		b->irq = platform_get_irq(pdev, i);	/* may be -ENXIO */
		b->rev = airoha_wed_read(b, AIROHA_WED_REV);
	}

	airoha_wed_report(wed);

	/* Read-only debug window: cat /sys/kernel/debug/airoha-wed/regs */
	wed->dbgfs = debugfs_create_dir(DRV_NAME, NULL);
	debugfs_create_file("regs", 0444, wed->dbgfs, wed,
			    &airoha_wed_regs_fops);

	/* Only reported once -- the resource count is a sanity cross-check
	 * for the DT against the number of instances actually described. */
	nresource = 0;
	while (platform_get_resource(pdev, IORESOURCE_MEM, nresource))
		nresource++;
	if (nresource != wed->nbank)
		dev_warn(dev, "%d DT reg entries for wed_num=%d\n",
			 nresource, wed->nbank);

	dev_info(dev, "probing done: %d instance(s), registers readable, dump at debugfs/%s/regs\n",
		 wed->nbank, DRV_NAME);

	return 0;
}

static void airoha_wed_remove(struct platform_device *pdev)
{
	struct airoha_wed *wed = platform_get_drvdata(pdev);

	debugfs_remove_recursive(wed->dbgfs);
	dev_info(&pdev->dev, "detached\n");
}

static const struct of_device_id airoha_wed_of_match[] = {
	/* Also accepted by the mt_whnat (WOE) driver tree, so either can bind. */
	{ .compatible = "en751221,wed", },
	{ }
};
MODULE_DEVICE_TABLE(of, airoha_wed_of_match);

static struct platform_driver airoha_wed_driver = {
	.probe		= airoha_wed_probe,
	.remove		= airoha_wed_remove,
	.driver		= {
		.name		= DRV_NAME,
		.of_match_table	= airoha_wed_of_match,
	},
};
module_platform_driver(airoha_wed_driver);

MODULE_DESCRIPTION("Airoha AN7581 WED register probe (read-only)");
MODULE_AUTHOR("AN7581 WED downlink bring-up");
MODULE_LICENSE("GPL");
