# mt76 驱动集成说明（AN758x PonWrt 云编译）

在 `Actions-OpenWrt-AN758X` 云编译流程中，编译前自动把定制版 mt76 无线驱动包
覆盖进 ponwrt 源码树，从而在 AN7581 机型上启用 **MT7915/MT7916 的 Airoha NPU 卸载**。

---

## 一、mt76 相关文件用途与放置位置

### 1.1 放置目录

| 项 | 值 |
|---|---|
| **覆盖目标（源码树内）** | `package/kernel/mt76/` |
| **本仓库携带位置** | `mt76/`（编译前由 `scripts/sync-mt76.sh` 拷过去） |
| **来源包** | OpenWrt 内核包 `kmod-mt76*` / `kmod-mt7915e` / `kmod-mt7996e` 等 |

`package/kernel/mt76` 是 OpenWrt/ponwrt 里 mt76 无线驱动的标准位置（属内核包，
不是 feeds 包）。整目录替换，不是只拷补丁 —— 原因见 1.5。

### 1.2 文件清单与用途

| 文件 | 用途 |
|---|---|
| `Makefile` | OpenWrt 包定义。① 指定驱动源码：`github.com/openwrt/mt76`，`PKG_SOURCE_DATE=2026-09-01`，`PKG_SOURCE_VERSION=be5ce7910521492d4a2e4ce7ee3843680a46c047`；② 定义全部 `kmod-mt76*` / `kmod-mt7915e` / `kmod-mt7996e` 内核包与固件包；③ **新增的 NPU 开关**（见下） |
| `patches/100-…tx_power-from-default-fw-if-EEP.patch` | MT7996：EEPROM 里 2.4G/5G 的 `tx_power` 全是 0（部分 BPI-R4-NIC-BE14 模块）时，改用固件文件中的默认值，保留其余 EEPROM 数据。来源：openwrt/mt76 PR #954 |
| `patches/110-mt7915-add-mt7916-cal-free-merge.patch` | MT7916：cal-free 机型把 4096 字节通用 EEPROM 模板放在 rootfs、只在 eFuse 存逐芯片 iCal 字段。补丁加入 MT7916 字段映射，并按 DT 属性 `mediatek,eeprom-merge-otp` 把 OTP 合并进模板。**AN758x 机型（HG5585F、ZN515XG-D、HM2004-DU 等）基本都走这条路** |
| `patches/113-mt7915-npu-vendor-rewrite.patch` | **本仓库定制、上游 ponwrt 没有**。给 MT7915/MT7916 加 Airoha NPU 卸载（vendor 协议重写）。详见 1.3 |

### 1.3 113 号补丁做了什么

新增 `mt7915/npu.c`（约 170 行，按从厂商 `mt7916_ap.ko` 还原的线格式实现），并改动：

| 文件 | 改动 |
|---|---|
| `mt7915/Kconfig` | 新增 `config MT7915_NPU`，`depends on MT7915E && NET_AIROHA_NPU`，`select MT76_NPU` |
| `mt7915/Makefile` | 仅 `CONFIG_MT7915_NPU` 时把 `npu.o` 编入 `mt7915e` |
| `mt7915/mt7915.h` | 新增 `npu_ba_node` / `npu_ba_node_dma` / `npu_cnt_base[3]` / `npu_rx_ring_base[2]`，导出三个 NPU 函数 |
| `mt7915/pci.c` | probe 时 `mt76_npu_init()`；新增 `mt7915_npu` 模块参数（默认 `true`，可运行时关闭） |
| `mt7915/init.c` | 注册设备前调用 `mt7915_npu_hw_init()` |
| `mt7915/mac.c` | RX 路径调用 `mt76_npu_check_ppe()` |
| `mt7915/main.c` | `sta_add`/`sta_remove` 时同步 wcid 给 NPU；新增 `mt7915_net_setup_tc()` |
| `dma.c` | TX 加缓冲时跳过 MT7996 专用 NPU DMA 路径（`!is_mt7915`） |
| `npu.c` | `dma_dev` / `hwrro_mode` / `rx_token_size` 只对 MT7996 生效 |
| `mt76.h` | `mt76_npu_device_active()` 改为直接 `return false` |

### 1.4 依赖的内核版本与配套补丁

| 依赖 | 说明 |
|---|---|
| **内核版本** | **6.18**。`target/linux/airoha/Makefile` 里 `KERNEL_PATCHVER:=6.18`，补丁目录 `target/linux/airoha/patches-6.18/`。换内核版本需确认 NPU 补丁已 backport |
| **内核符号** | `CONFIG_NET_AIROHA_NPU=y`（`target/linux/airoha/an7581/config-6.18` 已内置） |
| **内核头文件** | `<linux/soc/airoha/airoha_offload.h>`，提供 `airoha_npu` 结构与 `WLAN_FUNC_*` 枚举 |
| **内核 NPU 补丁** | `patches-6.18/` 下的 `102-02/102-03-net-airoha-npu-*`、`118/121/123/181-v7.x-net-airoha-npu-*`、`924/926-net-airoha-npu-*`（ponwrt 已带） |
| **DTS 保留内存** | `an7581-npu-wlan.dtsi`：`pkt` / `tx-pkt` / `tx-bufid` / `ba` 四块，`airoha_npu_wlan_init_memory()` 按名字查找，缺一块则 WiFi 卸载初始化失败 |
| **NPU 固件** | `/lib/firmware/airoha/en7581_npu_rv32.bin`（≤2 MiB）+ `en7581_npu_data.bin`（≤64 KiB） |
| **无线子系统** | `mac80211` backports 7.2（`package/kernel/mac80211`），提供 `mac80211-backport` 头文件 |

> 注意 **NPU 数据面变体**：MT7916/MT7996 走 **kite**，MT7991/MT7992/MT7993 走 **eagle**。
> 固件与 WiFi 芯片不匹配时 NPU 起不来或 WiFi 卸载不工作 —— 这正是仓库里
> `npu_fw=clanker` 选项存在的原因，见主 README。

### 1.5 为什么必须「Makefile + 补丁」成套替换

113 号补丁在 `mt7915/init.c` 里**无条件**调用 `mt7915_npu_hw_init()`，
而 `mt7915/npu.c`（该函数的实现）只在 Makefile 打开 `CONFIG_MT7915_NPU` 时才编译：

```makefile
ifdef CONFIG_MT7915_NPU
mt7915e-y += npu.o
endif
```

只拷补丁不改 Makefile → `mt7915_npu_hw_init` 是未定义符号，**链接直接失败**。
所以两者是一套，脚本采用 `rm -rf` 后整目录拷入，杜绝残留旧补丁导致 quilt 顺序错乱。

### 1.6 ⚠️ 已知注意事项（务必先看）

1. **上游 ponwrt 的 mt76 不含 NPU 支持。** 实测 `qwe3017/ponwrt@master` 的
   `package/kernel/mt76` 只有 100/110 两个补丁，Makefile 里只有给 MT7996 用的
   `CONFIG_MT76_NPU`、**没有** `CONFIG_MT7915_NPU`。
   因此 `MT76_SOURCE=remote` 拉上游会触发校验失败 → 按 `MT76_FALLBACK` 回退到本仓库的 vendored 版本。
   **想用 NPU 卸载就用默认的 `vendored`。**
2. **NPU 开关只对 AN7581 生效。** Makefile 里是 `ifdef CONFIG_TARGET_airoha_an7581`，
   AN7583（`nokia_xg-040g-mf*`）不会启用 MT7915 NPU。
3. **113 把 `mt76_npu_device_active()` 全局改成 `return false`**，即关闭 MT7996 式
   NPU 环 / RRO 数据面。若同一份固件还要支持 MT7996 机型，请确认其 NPU 行为不受影响。
4. `MT76_STRICT=false` 可跳过 NPU 特征校验（用于编译上游原版 mt76），默认 `true`。

### 1.7 已修复：`.net_setup_tc` 接线缺陷

本仓库自带的 113 补丁**已修正**上游原始版本的两个接线问题（详见 1.8）：
① `.net_setup_tc` 只在 WED 开启时挂接；② NPU 谓词被全局关闭导致函数形同虚设。
若你手上是**未经修正**的原始 113，请替换为 `mt76/patches/` 下这份，或按 1.8 自行修改。

### 1.8 接线缺陷的技术细节（修改依据）

原始 113 补丁有两处问题，都会导致 MT7916 的 NPU 卸载实际不生效：

**问题 A —— `.net_setup_tc` 挂不上。** 函数定义用了「或」条件，赋值却只用 WED：

```c
/* 定义：WED 或 MT7915_NPU 都能编进来 */
#if defined(CONFIG_NET_MEDIATEK_SOC_WED) || defined(CONFIG_MT7915_NPU)
static int mt7915_net_setup_tc(...) { ... }
#endif

const struct ieee80211_ops mt7915_ops = {
#ifdef CONFIG_NET_MEDIATEK_SOC_WED          /* ← 只有 WED！AN7581 上没有 */
	.net_setup_tc = mt7915_net_setup_tc,
#endif
};
```

Airoha 平台没有 MediaTek WED，于是函数被编译出来却从未挂进 `ieee80211_ops`
（表现为 `-Wunused-function` 告警 + NPU 的 TC 卸载不生效）。

**问题 B —— 更深一层：谓词被全局关闭。** 113 把 `mt76.h` 里的

```c
static inline bool mt76_npu_device_active(struct mt76_dev *dev)
{
	return false;   /* ← 全局关掉 */
}
```

而 `npu.c` 中 `mt76_npu_net_setup_tc()` 与 `mt76_npu_check_ppe()` 都以它为前置判断：

```c
int mt76_npu_net_setup_tc(...) {
	if (!mt76_npu_device_active(phy->dev))
		return -EOPNOTSUPP;      /* ← 永远走这里 */
	...
}
void mt76_npu_check_ppe(...) {
	if (!mt76_npu_device_active(dev))
		return;                  /* ← 永远走这里 */
	...
}
```

即便修好问题 A，`net_setup_tc` 也会立刻返回 `-EOPNOTSUPP`。
**只修 A 不修 B，等于没修。**

**修复方式**（保守、不改数据面）：新增一个只表示「NPU 协处理器已绑定」的谓词
`mt76_npu_bound()`，把这两处**控制面 / RX 元数据**的判断换掉；
`mt76_npu_device_active()` 保持 `false`，MT7996 专用的 DMA / HW-RRO 数据面仍按
原作者意图关闭：

```c
static inline bool mt76_npu_bound(struct mt76_dev *dev)
{
	return mt76_is_mmio(dev) && !!rcu_access_pointer(dev->mmio.npu);
}
```

```c
/* main.c —— 赋值条件与定义条件对齐 */
#ifdef CONFIG_NET_MEDIATEK_SOC_WED
	.net_fill_forward_path = mt7915_net_fill_forward_path,
#endif
#if defined(CONFIG_NET_MEDIATEK_SOC_WED) || defined(CONFIG_MT7915_NPU)
	.net_setup_tc = mt7915_net_setup_tc,
#endif
```

> **验证状态**：已用 `openwrt/mt76@be5ce791` 真实源码核对，GNU patch（quilt 所用）
> 干跑与实际打补丁均通过，两处谓词与挂接条件均已确认生效。
> **但未经真机验证** —— 请在目标机型上用 `dmesg | grep -i npu` 与
> Airoha SoC 状态页的 NPU 卸载计数确认实际效果。
>
> 若 `mt76_npu_check_ppe()` 在 MT7916 上出现误判（RX 描述符不含 NPU 的 FOE 字段时
> `reason`/`hash` 会读到无效值），把 `npu.c` 第 122 行改回
> `mt76_npu_device_active(dev)` 即可单独关掉这条路径，不影响 `net_setup_tc`。

---

## 二、改动点：与原流程的差异

| 项 | 原流程 | 适配后 |
|---|---|---|
| `.github/workflows/build-ponwrt.yml` | — | 新增 `Sync mt76 driver package` 步骤（第 2.5 步）；新增 4 个 workflow_dispatch 输入；defconfig 后新增 mt76 复核；Release 说明新增 mt76 表格 |
| `scripts/sync-mt76.sh` | 不存在 | **新增**：拉取 / 校验 / 覆盖 mt76，清理旧构建产物 |
| `scripts/fetch-mt76-local.sh` | 不存在 | **新增**：本机手动下载用，走 gh-proxy.com |
| `mt76/` | 不存在 | **新增**：随仓库携带的 mt76（Makefile + 3 个补丁） |
| 其余文件 | — | **全部未改动**（`diy-part1.sh` / `diy-part2.sh` / `configs/` / `files/` / `packages/` / 另两个脚本 / `cache-keepalive.yml`） |

### 步骤插入位置（关键）

```
2.  Clone source code
2.5 Sync mt76 driver package      ← 新增
3.  Cache dl directory
4.  Update & install feeds
5.  diy-part1.sh
…
9.  Generate toolchain cache key  ← 内部新增 mt76 复核
```

必须在 `feeds update` 与 `make download` **之前**：mt76 的 Makefile 决定拉哪一版源码，
`patches/` 决定打哪些补丁，两者在 `make download` 时即定型，之后再改不会重新应用。

---

## 三、使用方法

### 3.1 云端（GitHub Actions，默认）

`workflow_dispatch` 新增输入：

| 输入 | 默认 | 说明 |
|---|---|---|
| `mt76_source` | `vendored` | `vendored`=用本仓库 `mt76/`；`remote`=现拉；`none`=用 ponwrt 自带 |
| `mt76_repo` | `qwe3017/ponwrt` | 仅 `remote` 生效，格式 `owner/repo` |
| `mt76_ref` | `master` | 仅 `remote` 生效，分支 / tag / commit sha |
| `mt76_fallback` | `true` | `remote` 拉取或校验失败时回退 vendored |

> 云端 runner 直连 GitHub，**不使用** gh-proxy。

### 3.2 本机手动下载（走 gh-proxy.com）

```bash
# 默认拉 qwe3017/ponwrt@master 的 package/kernel/mt76，写入本仓库 mt76/
./scripts/fetch-mt76-local.sh

# 先看抓到什么，不写入 mt76/
DRY_RUN=true ./scripts/fetch-mt76-local.sh

# 不走代理（本机直连 GitHub 通）
USE_PROXY=false ./scripts/fetch-mt76-local.sh

# 换代理前缀
GH_PROXY=https://ghfast.top/ ./scripts/fetch-mt76-local.sh
```

代理用法即把原始 URL 拼在 `https://gh-proxy.com/` 后面（脚本已封装，失败自动回退直连）：

```
https://gh-proxy.com/https://raw.githubusercontent.com/qwe3017/ponwrt/master/package/kernel/mt76/Makefile
https://gh-proxy.com/https://github.com/qwe3017/ponwrt/archive/refs/heads/master.zip
```

> 脚本只会「缺什么补什么」，已存在的 `113-mt7915-npu-vendor-rewrite.patch`
> **不会被上游目录覆盖**——上游本来就没这个文件。

### 3.3 更新 mt76 的标准流程

```bash
# 1) 本机拉取（可选，走代理）
./scripts/fetch-mt76-local.sh

# 2) 确认 NPU 特征还在
grep -E 'CONFIG_MT7915_NPU' mt76/Makefile
ls mt76/patches/

# 3) 提交
git add mt76 && git commit -m "mt76: sync" && git push

# 4) CI 用默认 mt76_source=vendored 编译
```

---

## 四、校验与故障排查

`sync-mt76.sh` 在覆盖前后各校验一次，缺任一 NPU 特征即 `::error::` 并终止，
不会让你跑完一小时工具链才发现补丁没生效。

| 现象 | 原因 / 处理 |
|---|---|
| `mt76 Makefile 缺少 CONFIG_MT7915_NPU` | 拉到上游原版。用 `vendored`，或 `MT76_STRICT=false` |
| `缺少补丁 113-…` | 同上 |
| `远端拉取失败，已回退到随仓库携带的 mt76` | 远端仓库/分支写错或网络问题；已自动用 vendored 兜底 |
| 编译报 `mt7915_npu_hw_init` 未定义 | Makefile 与补丁不配套（只换了补丁）。必须成套替换 |
| 补丁打不上（quilt 失败） | `PKG_SOURCE_VERSION` 与补丁不匹配。确认 Makefile 与补丁来自同一套 |
| WiFi 起来了但 NPU 没卸载 | 检查 DTS 保留内存区（`npu_wlan_mem=true`）、NPU 固件变体（kite/eagle）、`dmesg \| grep -i npu` |

刷完验证：

```sh
dmesg | grep -i npu
ls -l /lib/firmware/airoha/
cat /sys/kernel/debug/ieee80211/phy0/mt76/npu   # 视内核配置而定
```
