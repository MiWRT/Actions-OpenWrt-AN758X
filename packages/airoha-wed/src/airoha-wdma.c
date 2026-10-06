// SPDX-License-Identifier: GPL-2.0-only
/*
 * Airoha AN7581 WDMA -- the SoC-side DMA engine that drains the PSE port
 * feeding the WED, i.e. the first half of the Wi-Fi downlink offload path:
 *
 *   PPE/FOE --force_port=3--> WDMA RX ring --> WED --> PCIe --> MT7916
 *
 * STAGE 2 of the bring-up. It claims the wdma@1fa06000 device, allocates the
 * RX descriptor rings and starts the RX DMA engine, but -- crucially -- it
 * still does not register an mtk_soc_wed_ops table, so mainline mt76 leaves
 * the WED path alone.
 *
 * Why start RX DMA when nothing is feeding the port yet: with
 * flow_offloading_hw=0 the PPE creates no WiFi entries at all, so no packet
 * can reach PSE port 3 and the engine simply idles on an empty queue. That
 * makes it safe to bring up here, and it is worth doing: it proves the ring
 * allocator, the descriptor geometry and the GLO_CFG sequence are all
 * accepted by real hardware before the much larger WED attach stage is
 * layered on top.
 *
 * The packet buffers are NOT allocated here. mt_whnat only ever carves the
 * descriptor array (see its rx_dma_cb_init), and mainline fills the WDMA RX
 * ring from WED's own TX buffer manager (WED_TX_BM_*). Both agree that the
 * SoC side supplies descriptors only.
 *
 * Register knowledge is documented in airoha-wdma.h; the short version is
 * that mt_whnat's wdma.h and mainline's mtk_wed_regs.h describe the same IP
 * and agree on every offset used below.
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
#include <linux/dma-mapping.h>
#include <linux/delay.h>

#include "airoha-wdma.h"

#define DRV_NAME		"airoha-wdma"
#define AIROHA_WDMA_BANKS	2
#define AIROHA_WDMA_IRQS	3	/* WDMA_IRQ_NUM in mt_whnat */

struct airoha_wdma_ring {
	void		*desc;
	dma_addr_t	 desc_phys;
	size_t		 desc_size;
	int		 size;
};

struct airoha_wdma_bank {
	void __iomem		*base;
	phys_addr_t		 phys;
	resource_size_t		 size;
	int			 irq[AIROHA_WDMA_IRQS];
	u32			 info;
	struct airoha_wdma_ring	 rx[AIROHA_WDMA_RX_RINGS];
	bool			 started;
};

struct airoha_wdma {
	struct device		*dev;
	u8			 nbank;
	struct airoha_wdma_bank	 bank[AIROHA_WDMA_BANKS];
	struct dentry		*dbgfs;
};

static struct airoha_wdma *airoha_wdma_dev;
static bool airoha_wdma_enable = true;

module_param_named(enable, airoha_wdma_enable, bool, 0644);
MODULE_PARM_DESC(enable, "start the WDMA RX DMA engine at probe time");

static inline u32 aw_r(const struct airoha_wdma_bank *b, u32 reg)
{
	return readl(b->base + reg);
}

static inline void aw_w(const struct airoha_wdma_bank *b, u32 reg, u32 val)
{
	writel(val, b->base + reg);
}

static inline void aw_set(const struct airoha_wdma_bank *b, u32 reg, u32 val)
{
	aw_w(b, reg, aw_r(b, reg) | val);
}

static inline void aw_clr(const struct airoha_wdma_bank *b, u32 reg, u32 val)
{
	aw_w(b, reg, aw_r(b, reg) & ~val);
}

/* ------------------------------------------------------------------ */
/* rings                                                              */
/* ------------------------------------------------------------------ */

static void airoha_wdma_ring_free(struct device *dev,
				  struct airoha_wdma_ring *ring)
{
	if (!ring->desc)
		return;

	dma_free_coherent(dev, ring->size * ring->desc_size, ring->desc,
			  ring->desc_phys);
	memset(ring, 0, sizeof(*ring));
}

static int airoha_wdma_ring_alloc(struct device *dev,
				  struct airoha_wdma_ring *ring,
				  int size, size_t desc_size)
{
	ring->desc = dma_alloc_coherent(dev, size * desc_size,
					&ring->desc_phys, GFP_KERNEL);
	if (!ring->desc)
		return -ENOMEM;

	ring->size = size;
	ring->desc_size = desc_size;
	memset(ring->desc, 0, size * desc_size);

	return 0;
}

/*
 * Mirrors mt_whnat's rx_dma_cb_init(): the only thing it does to a fresh
 * descriptor is set the DMA_DONE bit. See airoha-wdma.h for why bit 31 is
 * the right position despite mt_whnat's confusing bitfield order.
 */
static void airoha_wdma_ring_init_desc(struct airoha_wdma_ring *ring)
{
	__le32 *desc = ring->desc;
	int i, words = ring->desc_size / sizeof(__le32);

	for (i = 0; i < ring->size; i++)
		desc[i * words + 1] =
			cpu_to_le32(AIROHA_WDMA_DESC_CTRL_DMA_DONE);
}

/* Modeled on mainline mtk_wed_wdma_rx_ring_setup(). */
static int airoha_wdma_rx_ring_setup(struct device *dev,
				     struct airoha_wdma_bank *b, int idx)
{
	struct airoha_wdma_ring *ring = &b->rx[idx];
	u32 off = AIROHA_WDMA_RING_RX(idx);
	int ret;

	ret = airoha_wdma_ring_alloc(dev, ring, AIROHA_WDMA_RING_SIZE,
				     AIROHA_WDMA_RXD_SIZE);
	if (ret)
		return ret;

	airoha_wdma_ring_init_desc(ring);

	aw_w(b, off + AIROHA_WDMA_RING_OFS_BASE, (u32)ring->desc_phys);
	aw_w(b, off + AIROHA_WDMA_RING_OFS_COUNT, ring->size);
	aw_w(b, off + AIROHA_WDMA_RING_OFS_CPU_IDX, 0);

	return 0;
}

static void airoha_wdma_rx_ring_teardown(struct device *dev,
					 struct airoha_wdma_bank *b, int idx)
{
	u32 off = AIROHA_WDMA_RING_RX(idx);

	aw_w(b, off + AIROHA_WDMA_RING_OFS_BASE, 0);
	aw_w(b, off + AIROHA_WDMA_RING_OFS_COUNT, 0);
	aw_w(b, off + AIROHA_WDMA_RING_OFS_CPU_IDX, 0);
	airoha_wdma_ring_free(dev, &b->rx[idx]);
}

/* ------------------------------------------------------------------ */
/* start / stop                                                       */
/* ------------------------------------------------------------------ */

static void airoha_wdma_stop(struct device *dev, struct airoha_wdma_bank *b)
{
	int i;

	if (!b->started)
		return;

	aw_clr(b, AIROHA_WDMA_GLO_CFG, AIROHA_WDMA_GLO_RX_DMA_EN);

	/* Mirrors mainline's wait on MTK_WDMA_GLO_CFG_RX_DMA_BUSY. */
	for (i = 0; i < 100; i++) {
		if (!(aw_r(b, AIROHA_WDMA_GLO_CFG) &
		      AIROHA_WDMA_GLO_RX_DMA_BUSY))
			break;
		udelay(10);
	}
	if (aw_r(b, AIROHA_WDMA_GLO_CFG) & AIROHA_WDMA_GLO_RX_DMA_BUSY)
		dev_warn(dev, "WDMA at 0x%08llx: RX DMA did not go idle\n",
			 (unsigned long long)b->phys);

	for (i = 0; i < AIROHA_WDMA_RX_RINGS; i++)
		airoha_wdma_rx_ring_teardown(dev, b, i);

	b->started = false;
}

static int airoha_wdma_start(struct device *dev, struct airoha_wdma_bank *b)
{
	int i;

	if (b->started)
		return 0;

	/* Order taken from mainline's mtk_wed_hw_init_early(), v1 branch:
	 * reserve the three RX info words *before* touching anything else. */
	aw_set(b, AIROHA_WDMA_GLO_CFG,
	       AIROHA_WDMA_GLO_RX_INFO1_PRERES |
	       AIROHA_WDMA_GLO_RX_INFO2_PRERES |
	       AIROHA_WDMA_GLO_RX_INFO3_PRERES |
	       AIROHA_WDMA_GLO_CSR_CLKGATE_BYP);

	for (i = 0; i < AIROHA_WDMA_RX_RINGS; i++) {
		if (airoha_wdma_rx_ring_setup(dev, b, i)) {
			dev_err(dev, "WDMA: rx ring %d alloc failed\n", i);
			while (i--)
				airoha_wdma_rx_ring_teardown(dev, b, i);
			return -ENOMEM;
		}
		aw_w(b, AIROHA_WDMA_RST_IDX, AIROHA_WDMA_RST_DRX_IDX(i));
	}

	/* All interrupts off for now: there is no handler yet, and a
	 * fire-and-forget IRQ line would wedge the box. */
	aw_w(b, AIROHA_WDMA_INT_MSK, 0);
	aw_w(b, AIROHA_WDMA_INT_STA_REC, 0xffffffff);

	aw_set(b, AIROHA_WDMA_GLO_CFG, AIROHA_WDMA_GLO_RX_DMA_EN);
	b->started = true;

	return 0;
}

/* ------------------------------------------------------------------ */
/* debugfs                                                            */
/* ------------------------------------------------------------------ */

static int airoha_wdma_regs_show(struct seq_file *s, void *unused)
{
	struct airoha_wdma *wdma = s->private;
	int i, k;

	for (i = 0; i < wdma->nbank; i++) {
		struct airoha_wdma_bank *b = &wdma->bank[i];

		seq_printf(s, "WDMA%d\n", i);
		seq_printf(s, "  base   : 0x%08llx (%llu bytes)\n",
			   (unsigned long long)b->phys,
			   (unsigned long long)b->size);
		seq_printf(s, "  irq    : %d %d %d\n",
			   b->irq[0], b->irq[1], b->irq[2]);
		seq_printf(s, "  info   : 0x%08x (rev %u, idx_width %u, rx %u, tx %u)\n",
			   b->info,
			   FIELD_GET(AIROHA_WDMA_INFO_REV, b->info),
			   FIELD_GET(AIROHA_WDMA_INFO_INDEX_WIDTH, b->info),
			   FIELD_GET(AIROHA_WDMA_INFO_RX_RING_NUM, b->info),
			   FIELD_GET(AIROHA_WDMA_INFO_TX_RING_NUM, b->info));
		seq_printf(s, "  started: %d\n", b->started);
		if (!b->base)
			continue;

		seq_printf(s, "  GLO_CFG     : 0x%08x\n",
			   aw_r(b, AIROHA_WDMA_GLO_CFG));
		seq_printf(s, "  INT_STA_REC : 0x%08x\n",
			   aw_r(b, AIROHA_WDMA_INT_STA_REC));
		seq_printf(s, "  INT_MSK     : 0x%08x\n",
			   aw_r(b, AIROHA_WDMA_INT_MSK));

		for (k = 0; k < AIROHA_WDMA_RX_RINGS; k++) {
			u32 off = AIROHA_WDMA_RING_RX(k);
			struct airoha_wdma_ring *r = &b->rx[k];

			seq_printf(s, "  rx[%d] base=0x%08x cnt=%u cpu=%u dma=%u",
				   k,
				   aw_r(b, off + AIROHA_WDMA_RING_OFS_BASE),
				   aw_r(b, off + AIROHA_WDMA_RING_OFS_COUNT),
				   aw_r(b, off + AIROHA_WDMA_RING_OFS_CPU_IDX),
				   aw_r(b, off + AIROHA_WDMA_RING_OFS_DMA_IDX));
			if (r->desc)
				seq_printf(s, " (va=%pK pa=0x%08llx)",
					   r->desc,
					   (unsigned long long)r->desc_phys);
			seq_puts(s, "\n");
		}
	}

	return 0;
}

DEFINE_SHOW_ATTRIBUTE(airoha_wdma_regs);

/* ------------------------------------------------------------------ */
/* probe                                                              */
/* ------------------------------------------------------------------ */

static int airoha_wdma_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct airoha_wdma *wdma;
	int i, k, ret, nres;

	wdma = devm_kzalloc(dev, sizeof(*wdma), GFP_KERNEL);
	if (!wdma)
		return -ENOMEM;
	wdma->dev = dev;
	platform_set_drvdata(pdev, wdma);
	airoha_wdma_dev = wdma;

	/* Both the WDMA and the wifi chip are 32-bit DMA masters. */
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		dev_warn(dev, "cannot set 32-bit DMA mask (%d)\n", ret);

	nres = 0;
	while (platform_get_resource(pdev, IORESOURCE_MEM, nres))
		nres++;
	if (!nres || nres > AIROHA_WDMA_BANKS) {
		dev_err(dev, "%d reg entries, expected 1..%d\n",
			nres, AIROHA_WDMA_BANKS);
		return -EINVAL;
	}
	wdma->nbank = (u8)nres;

	for (i = 0; i < wdma->nbank; i++) {
		struct airoha_wdma_bank *b = &wdma->bank[i];
		struct resource *res;

		res = platform_get_resource(pdev, IORESOURCE_MEM, i);
		b->base = devm_ioremap_resource(dev, res);
		if (IS_ERR(b->base))
			return dev_err_probe(dev, PTR_ERR(b->base),
					     "WDMA%d: cannot map\n", i);

		b->phys = res->start;
		b->size = resource_size(res);
		b->info = aw_r(b, AIROHA_WDMA_INFO);

		for (k = 0; k < AIROHA_WDMA_IRQS; k++)
			b->irq[k] = platform_get_irq(pdev,
						     i * AIROHA_WDMA_IRQS + k);

		dev_info(dev,
			 "WDMA%d 0x%08llx +0x%llx info=0x%08x (rev %u, rx rings %u) irq=%d/%d/%d\n",
			 i, (unsigned long long)b->phys,
			 (unsigned long long)b->size, b->info,
			 FIELD_GET(AIROHA_WDMA_INFO_REV, b->info),
			 FIELD_GET(AIROHA_WDMA_INFO_RX_RING_NUM, b->info),
			 b->irq[0], b->irq[1], b->irq[2]);
	}

	for (i = 1; i < wdma->nbank; i++)
		if (wdma->bank[i].phys == wdma->bank[0].phys)
			dev_err(dev, "WDMA0 and WDMA%d share a window\n", i);

	if (airoha_wdma_enable) {
		for (i = 0; i < wdma->nbank; i++) {
			ret = airoha_wdma_start(dev, &wdma->bank[i]);
			if (ret)
				return ret;
		}
		dev_info(dev, "RX DMA started on %d instance(s), PSE port %d\n",
			 wdma->nbank, AIROHA_WDMA_PSE_PORT);
	} else {
		dev_info(dev, "enable=0: rings left unprogrammed\n");
	}

	wdma->dbgfs = debugfs_create_dir(DRV_NAME, NULL);
	debugfs_create_file("regs", 0444, wdma->dbgfs, wdma,
			    &airoha_wdma_regs_fops);

	return 0;
}

static void airoha_wdma_remove(struct platform_device *pdev)
{
	struct airoha_wdma *wdma = platform_get_drvdata(pdev);
	int i;

	for (i = 0; i < wdma->nbank; i++)
		airoha_wdma_stop(wdma->dev, &wdma->bank[i]);

	debugfs_remove_recursive(wdma->dbgfs);
	airoha_wdma_dev = NULL;
	dev_info(wdma->dev, "detached\n");
}

static const struct of_device_id airoha_wdma_of_match[] = {
	{ .compatible = "en751221,wdma", },
	{ }
};
MODULE_DEVICE_TABLE(of, airoha_wdma_of_match);

static struct platform_driver airoha_wdma_driver = {
	.probe		= airoha_wdma_probe,
	.remove		= airoha_wdma_remove,
	.driver		= {
		.name		= DRV_NAME,
		.of_match_table	= airoha_wdma_of_match,
	},
};
module_platform_driver(airoha_wdma_driver);

MODULE_DESCRIPTION("Airoha AN7581 WDMA (WED feed DMA) ring bring-up");
MODULE_AUTHOR("AN7581 WED downlink bring-up");
MODULE_LICENSE("GPL");
