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
| `diy-part1.sh: cannot execute: required file not found`（exit 127） | **CRLF 行尾**。shebang 变成 `#!/bin/bash\r`，Linux 找不到该解释器。见 [4.1](#41-crlf-行尾问题必须在 windows 提交前处理) |
| WiFi 起来了但 NPU 没卸载 | 检查 DTS 保留内存区（`npu_wlan_mem=true`）、NPU 固件变体（kite/eagle）、`dmesg \| grep -i npu` |
| `make menuconfig` 取值异常 / `.config` 里出现 `y^M` | 同上，`.config` 被 CRLF 污染 |

### 4.1 CRLF 行尾问题（必须在 Windows 提交前处理）

#### 症状

```
/home/runner/work/_temp/xxxx.sh: line 3:
  /home/runner/work/<repo>/<repo>/diy-part1.sh: cannot execute: required file not found
Error: Process completed with exit code 127.
```

#### 根因

`file not found` 指的不是 `diy-part1.sh`（`chmod +x` 已经成功，文件确实在），
而是它**第一行 shebang 指定的解释器**：

```sh
#!/bin/bash\r          # ← 末尾多了一个 CR，Linux 去找 "/bin/bash\r" 这个不存在的路径
```

Windows 上 `git config core.autocrlf` 为 `true` 时，检出会把 LF 全转成 CRLF；
若这些文件被直接提交/打包发走，GitHub 上的 blob 就是 CRLF，runner 上必然炸。

#### 为什么只有 `diy-part1.sh` 报错

本流程里两类调用方式混用：

| 调用方式 | 是否受 shebang 影响 | 涉及脚本 |
|---|---|---|
| `"$GITHUB_WORKSPACE/$DIY_P1_SH"`（直接 exec） | **是** → exit 127 | `diy-part1.sh`、`diy-part2.sh` |
| `bash "$REPO_DIR/scripts/xxx.sh"` | 否（显式指定解释器） | `sync-mt76.sh`、`build-npu-fw.sh`、`apply-npu-dts.sh` |

所以这是一部分脚本「侥幸没炸」，并不代表问题只存在于 `diy-part1.sh`。

#### 除了 exit 127，CRLF 还有两个隐蔽后果

1. **`.config` 全部带 CR** → kconfig 读到的值是 `y\r`，配置不生效或不识别。
   本仓库 13 个 `configs/*.config` 全部受影响。
2. **`.patch` 全部带 CR** → `quilt` / `git apply` 上下文不匹配，补丁打不上。
   `mt76/patches/*.patch`（含 113 号 NPU 补丁）全部受影响。

这三个是同一根因，只修 shebang 会漏掉后两个。

#### 已采取的三层防护

1. **发货内容全部规范化为 LF** —— 本 zip 内所有文本文件均为 LF（已校验 0 个 CR）。
2. **`.gitattributes`** —— `* text=auto eol=lf`，强制检出写 LF。
   即使本地 `core.autocrlf=true` 也不会再污染。
3. **workflow 内自愈步骤** —— `Checkout` 之后立即执行 `Normalize line endings (CRLF -> LF)`：
   剥掉所有文本文件的 CR、重设可执行位、并对 shebang 做兜底体检。
   即使将来有人提交了 CRLF，也只是产生一条 `::warning::`，不会中断构建。

#### 如果你本地仓库已经被污染

```bash
# 0) 确认现状
file diy-part1.sh            # 出现 "CRLF line terminators" 即已污染

# 1) 一次性重规范化（依赖 .gitattributes，务必先把它提交进来）
git add .gitattributes
git add --renormalize .
git status                   # 应看到大量文件被 restage

# 2) 提交
git commit -m "fix: normalize line endings to LF"

# 3) 建议同时关掉本机自动转换（全局或本仓库二选一）
git config --global core.autocrlf false
# 或：git config core.autocrlf false   （仅本仓库）

# 4) 验证：检出后应全是 LF
file diy-part1.sh configs/an7581.config mt76/patches/*.patch
```

> `core.autocrlf=false` 只影响以后的转换，不会动已入库的 blob；
> 已污染的历史 blob 必须靠第 1 步的 `--renormalize` 修正。

---

### 4.2 WiFi 起来了但 NPU 没有卸载（静默失效）

这是本次集成最容易被误判的场景：**WiFi 一切正常，但 NPU 卸载完全没生效，且 dmesg 里一个字都没有。**

#### 现象

```sh
$ dmesg | grep -i npu
[    0.000000] OF: reserved mem: ... npu-binary@84000000
[    0.000000] OF: reserved mem: ... npu-pkt@81000000
...（只有 reserved memory，没有任何驱动侧初始化日志）

$ cat /sys/module/mt7915e/parameters/mt7915_npu
Y
$ cat /sys/firmware/devicetree/base/soc/npu@1e900000/status
okay
$ ls -l /lib/firmware/airoha/
en7581_npu_data.bin / en7581_npu_rv32.bin        # 固件在
```

看起来什么都对，但 NPU 就是没工作。

#### 排除干扰项：`input device check on` 是假阳性

`dmesg | grep -i npu` 匹配到的 `input device check on` 里 "npu" 是 `i-n-p-u-t` 的子串，与 NPU 无关。

#### 确定失败点：两条 hard evidence

`mt7915/npu.c` 的 `mt7915_npu_hw_init()` 一旦拿到 `npu` 句柄，`NPU_DP_STEP >= 1` 段必定产生以下两条之一：

```c
dev_warn(..., "NPU set driver model failed %d\n", err);   /* mt76_npu_send_msg 失败 */
dev_info(..., "NPU version: %d.%d\n", ...);               /* 成功拿到版本号 */
```

**两条都没出现 ⇒ 函数在第一段就早退了 ⇒ `dev->mt76.mmio.npu == NULL`。**

又因 `mt7915.h` 里没有给 `mt7915_npu_hw_init()` 写 `#else` 桩函数（`mt7915_npu` 参数虽存在，但它是
113 在 `pci.c` **无条件**注册的，不能作为 `CONFIG_MT7915_NPU` 是否开启的依据），
而其馀编译/加载路径若无 NPU 会直接链接失败——模块既然已加载，
就证明 `CONFIG_MT7915_NPU` 必然为真、该调用必然执行过。

结论：**`mt76_npu_init()` 返回了错误码**，三个出口之一失败：

| 出口 | 调用 | 典型原因 |
|---|---|---|
| `error_unlock` | `airoha_npu_get()` | NPU platform 驱动没 probe 完成（`-EPROBE_DEFER`） |
| `error_npu_put` | `airoha_ppe_get_dev()` | PPE 设备未就绪 |
| `error_ppe_put` | `airoha_npu_wlan_init_reserved_memory()` | DTS 的 `memory-region-names` 不齐（需 `binary`/`pkt`/`tx-pkt`/`tx-bufid`/`ba`） |

#### 为什么原来查不出来

`mt76_npu_init()` 的三个失败出口全是 `goto` + `return err`，**没有一条 `dev_err`**；
而调用方 `mt7915/pci.c` 又直接忽略了返回值：

```c
if (mt7915_npu)
    mt76_npu_init(&dev->mt76, pci_resource_start(pdev, 0),
                  id->device == 0x7906 ? 2 : 3);      /* 返回值丢弃 */
```

`mt7915_npu_hw_init()` 里拿到 NULL 也是 `return 0` 静默返回。整条链路做不到"失败可见"。

#### 修复：新增 114 号诊断补丁

`mt76/patches/114-mt76-npu-debug-log.patch` 给上述每个出口补上 `dev_err`（带错误码），
并在绑定成功时补一条 `dev_info`；同时把 113 里 `mt7915_npu_hw_init()` 的 NULL 早退
从静默 `return 0` 改成可读的 `dev_info`。

重编后：

```sh
dmesg | grep -i npu
# 成功：
#   mt7915e 0001:01:00.0: NPU bound: type=3 phy=0x... hwrro=... token=...
#   mt7915e 0001:01:00.0: NPU version: 1.2
# 失败（会明确告诉你卡在哪步）：
#   mt7915e 0001:01:00.0: NPU bind failed: airoha_npu_get() err=-517 (找不到 NPU 设备，或其 platform 驱动尚未 probe 完成)
#   mt7915e 0001:01:00.0: NPU offload disabled: npu handle is NULL (mt76_npu_init failed)
```

> 114 是**纯诊断**补丁，不改任何行为，可随时删除。
> 它不在 `sync-mt76.sh` 的必选清单里（`100/110/113` 才必选），
> 但 `sync-mt76.sh` 是整目录替换，会自动一起拷进去。

#### 不用重编就能先确认的事

```sh
# 1) NPU platform 设备到底有没有绑定到驱动？（最可能是这一步）
ls /sys/bus/platform/drivers/airoha-npu/          # 应出现 1e900000.npu
ls /sys/bus/platform/devices/ | grep npu

# 2) 完整启动日志里有没有 NPU firmware 版本行（118 号补丁专门加的）
dmesg | grep -i "npu fw version"

# 3) mt7915e.ko 里 NPU 代码是否真的编译进去了
find /lib/modules -name mt7915e.ko -exec strings {} \; | grep -i "NPU version\|set driver model"

# 4) 完整 npu 相关日志，别只看 tail
dmesg | grep -iE "airoha-npu|npu bind|npu offload|reserved memory"
```

第 1 条若 `/sys/bus/platform/drivers/airoha-npu/` 下没有 `1e900000.npu`，
就是 NPU 平台设备未 probe —— 后续 `airoha_npu_get()` 必然返回 `-EPROBE_DEFER`(-517)。

---

刷完验证：

```sh
dmesg | grep -i npu
ls -l /lib/firmware/airoha/
cat /sys/kernel/debug/ieee80211/phy0/mt76/npu   # 视内核配置而定
```


---

## 9. NPU 卸载不生效的根因（实测定位，非推测）

### 现象

打了 114 诊断补丁后 `dmesg | grep -i npu` 给出确切错误码：

```
mt7915e 0001:01:00.0: NPU bind failed: reserved memory init err=-22
```

`-22 = -EINVAL`。注意它**不是** `-110`（超时），两者含义完全不同：

| errno | 含义 |
|---|---|
| `-110` `-ETIMEDOUT` | mailbox 发出去 100 ms 内 DONE 位没起来 → 固件没跑 |
| `-22` `-EINVAL` | **DONE 位起来了，但 STATUS 字段是 ERROR** → 固件在线，主动拒绝 |

### 定位过程（可在任意一台同型机上复现）

1. **读 mailbox 控制寄存器**（NPU 基址 `0x1e900000`，mailbox 偏移 `0x30c000`）：

   ```sh
   devmem 0x1ec0c03c 32   # REG_CR_MBQ0_CTRL(3)
   ```

   位定义：`FUNC_ID[14:11]` `STATUS[4:2]` `DONE[1]` `WAIT_RSP[0]`。
   实测 `0x00000003` → DONE=1、STATUS=0(`NPU_MBOX_ERROR`)、FUNC_ID=0(`NPU_FUNC_WIFI`)。
   → 固件有应答，返回的是错误状态。

2. **读最后一条消息的 DMA 缓冲区**。`MBQ0_CTRL(0)` 给出物理地址：

   ```sh
   devmem 0x1ec0c030 32   # 例：0x91BA9000
   devmem 0x91ba9000 32   # 0x00000010 -> ifindex=0, func_type=1(SET)
   devmem 0x91ba9004 32   # 0x00000020 -> func_id = 32
   devmem 0x91ba9008 32   # 0x90C00000 -> payload = npu-txbufid 基址
   ```

   `func_id=32` 即 `WLAN_FUNC_SET_WAIT_TX_BUF_CHECK_ADDR`，
   payload 正是 DTS 里 `npu-txbufid@90c00000` 的地址 ——
   失败点锁定在 `airoha_npu_wlan_init_memory()` 的第 2 步（第 1 步 BAND0_ONCPU 是通过的）。

### 根因：驱动与固件的命令表错位

内核 `enum airoha_npu_wlan_set_cmd` 有 **34** 项（0..33），
而 NPU 固件（ClankerNPU）的 `set_wait_func_table` 只有 **31** 项（0..30），
`npu_wifi.c` 里明确写着：

```c
case 1:  /* SET_WAIT */
    if (msg[1] > 30)
        return wifi_mail_exceed(msg, 1);   /* 返回 0 -> STATUS=ERROR -> -EINVAL */
```

对齐关系：

| id | 内核驱动 (6.18) | 固件表 |
|---|---|---|
| 0..29 | 一致 | 一致 |
| 30 | `HWNAT_INIT` | `arht_chip_info`（会误调，但当前无人发送） |
| 31 | `ARHT_CHIP_INFO` | — 越界 |
| **32** | **`TX_BUF_CHECK_ADDR`** | — 越界 → **-22** |
| 33 | `TOKEN_ID_SIZE` | — 越界（当前无人发送） |

平台驱动实际只会用到 32 这一条越界命令，所以只在这里炸。

### 修复

`patches/kernel/950-airoha-npu-skip-unsupported-tx-buf-check.patch`（走
`install-kernel-patches.sh` 复制进 `target/linux/airoha/patches-*/`，由 quilt 应用）。

把 `TX_BUF_CHECK_ADDR` 的 `-EINVAL` 视为非致命：固件既然没有对应 handler，
就说明它根本不使用 `tx-bufid` 这块区域，跳过不影响其余初始化。
**其余错误码、以及后续所有命令的错误仍然照常中止绑定。**

重编刷机后应看到：

```
mt7915e ...: TX_BUF_CHECK_ADDR unsupported by NPU fw, skipping
mt7915e ...: NPU bound: type=... phy=...
```

### 附带说明

- 这次 `-22` 与 DTS 无关：本机 `memory-region-names` 五项齐全
  （`binary pkt tx-pkt tx-bufid ba`）。**用 `strings` 读该属性会被坑** ——
  它默认跳过短字符串，`pkt`(3)、`ba`(2) 会被丢掉，看起来像只有 3 项。
  要用 `cat ... | tr '\0' '\n'`。
- probe 里的 `WLAN_FUNC_GET_WAIT_NPU_VERSION` 失败是**静默**的
  （`if (!ret)` 才打印），所以 dmesg 里看不到 `NPU fw version:` 是正常的，
  不能据此判断固件没起来 —— 要看 err 是 -22 还是 -110。

### 补丁没生效？先查有没有人调用安装脚本

第一次刷完 950 之后设备上**仍然是 -22**。原因不是补丁写错，而是：

> `scripts/install-kernel-patches.sh` 在仓库里存在，但**从来没有任何地方调用它**。

所以 `patches/kernel/` 下的补丁一直只是躺在仓库里，压根没进编译。
脚本不会自己跑起来 —— 仓库里有文件 ≠ 流程会用它。

已在 `.github/workflows/build-ponwrt.yml` 里补了 `Install kernel patches` 步骤
（在 `diy-part1.sh` 之后、`make defconfig` 之前），现在会显式调用：

```bash
bash scripts/install-kernel-patches.sh "$BUILD_ROOT/openwrt" "$GITHUB_WORKSPACE/patches/kernel"
```

⚠️ 这一步**不能**改成直接 `git apply`：此刻内核源码还没解压，
`drivers/net/ethernet/airoha/airoha_npu.c` 不存在，只能交给 quilt 目录，
等 kernel prepare 阶段统一打。编号用 `9xx-` 前缀（官方补丁最大到 930），
保证排在最后应用。

### 补丁上下文会不会被官方补丁顶掉

不会。改动 `airoha_npu.c` 的官方补丁共 8 个
（102-02 / 102-03 / 118 / 121 / 123 / 181 / 924 / 926），
其中只有 121 动过 `init_memory`，且插在 `TX_BUF_CHECK_ADDR` **之后**。
924 / 926 只改 `send_msg` 和 `probe`（行 23、160-213、499、772），
与 950 的上下文（539 附近）不重叠，行号偏移不影响匹配。

---

## 10. 第二层问题：绑定成功后固件不再响应 mailbox

绑上之后以为成了，结果一连客户端就暴露出第二层问题：

```
NPU wcid_sync entry: band=1 wcid=3
NPU sta sync: band=1 wcid=3
airoha-npu 1e900000.npu: mailbox function 0 timed out
NPU sta sync: band=1 wcid=3 ret=-110      ← 超时，不是拒绝
```

### 实测取证

| 检查 | 结果 | 含义 |
|---|---|---|
| `/proc/interrupts` 中 `airoha-npu-mbox` | **0 次** | 固件从未给主机发中断 |
| `devmem 0x1ec0c03c` (CTRL3) | `0x1` | WAIT_RSP=1、**DONE=0**，固件没完成事务 |
| 手动构造 cmd=6 触发（序号 +1，等 2 s） | CTRL3 仍 `0x1` | 固件**完全不响应** |
| `rmmod mt7915e && modprobe mt7915e` | `NPU offload disabled: npu handle is NULL` | 连 init_memory 都失败 → 固件此后一直沉默 |
| `clk_summary` 的 `npu` | enable=Y, 800 MHz | 时钟开着，排除时钟/电源门控 |

即：**固件在首次 init 之后就不再响应 mailbox**，寄存器仍可读写（总线在），但固件 core 没在干活。

### 为什么怀疑是命令 32 干的

时间线对得上：

1. `init_memory` 发 BAND0_ONCPU → 成功
2. 发 **TX_BUF_CHECK_ADDR(32)** → 固件回 STATUS=ERROR
3. 发 PKT / TX_PKT / BA / IS_FORCE_TO_CPU → 都成功（所以此时固件还活着）
4. 绑定成功
5. 之后任何命令 → 全部超时

固件源码 `npu_wifi.c` 里：

```c
case 1:  /* SET_WAIT */
    if (msg[1] > 30)
        return wifi_mail_exceed(msg, 1);   /* 返回 0 -> STATUS=ERROR */
```

两个变体（Kite / Eagle）的 `set_wait_func_table` **都是 `[31]`**，
没有任何变体支持命令 32。`wifi_mail_exceed` 这条异常返回路径很可能
没清中断/状态标志，把固件的 mailbox 状态机留在了卡住的状态。

**所以上一版"发送后忽略 -EINVAL"是不够的** —— 错误是忽略了，
但命令已经发出去，固件已经被带偏。改成**根本不发**。

### 补丁 v2 的两处改动

- 把 `TX_BUF_CHECK_ADDR` 的发送整块删除（保留注释说明理由）
- `init_memory()` 末尾加一次 `WLAN_FUNC_GET_WAIT_NPU_VERSION` 探测并
  `dev_info` 打印结果 —— 用来从 dmesg 直接区分
  "初始化后固件还活着"（ret=0）和 "固件已经沉默"（ret=-110）

刷机后看这条日志即可判断：

```
airoha-npu 1e900000.npu: NPU post-init check: version query ret=0 ver=0x...
```

- `ret=0` → 固件活着，接下来看 `NPU sta sync ... ret=0` 有没有出现
- `ret=-110` → 固件在 init 后就不响应了，得换固件（不是驱动能救的）

### 排查手法备忘

- **手动触发 mailbox**（判断固件死活）：写 `CTRL(0)` 指向的 DMA 缓冲
  3 个 u32（ifindex/type、func_id、payload），写 `CTRL(1)=0xC`，
  **`CTRL(2)` 必须比当前值大 1**（序号倒退固件会直接忽略，这点踩过坑），
  再写 `CTRL(3)=0x1` 触发，然后读 `CTRL(3)` 看 DONE(bit1) 是否置起。
- `MT7916` 上 `hwrro=0 token=0` 正常；`mt76_npu_device_active()` 返回
  false 也是设计如此（见第 9 章），不要当故障查。


---

## 11. 真正的根因：越界命令会毒死 mailbox（且不止一条）

刷入 950 v2 后仍然失败，`dmesg` 关键两行：

```
airoha-npu 1e900000.npu: NPU post-init check: version query ret=-22 ver=0x0
mt7915e 0001:01:00.0: NPU sta sync: band=1 wcid=3 ret=-110
```

看起来像"固件 init 后就不响应"，其实是**越界命令**问题，而且 950 v1 只修了一半。

### 事实：主机枚举比固件表长

| 方向 | 主机枚举项数 | 固件表项数 | 有效下标 |
|---|---|---|---|
| SET | 34 | 31 | 0..30（31/32/33 越界）|
| GET | 11 | 10 | 0..9（10 越界）|

固件分发：

```c
case 1:  if (msg[1] > 30) return wifi_mail_exceed(msg, 1);  /* SET_WAIT */
case 3:  if (msg[1] > 9)  return wifi_mail_exceed(msg, 3);  /* GET_WAIT */
```

`wifi_mail_exceed()` 这条异常返回路径**不清 mailbox 状态**。一旦踩到，
之后**所有**事务都完不成：寄存器上表现为 `CTRL3=0x1`（WAIT_RSP=1, DONE=0），
驱动侧看到的就是 `-110 ETIMEDOUT` 雪崩。

### 两个越界元凶

| 命令 | 下标 | 谁在用 | 状态 |
|---|---|---|---|
| `SET_WAIT_TX_BUF_CHECK_ADDR` | 32 | `airoha_npu_wlan_init_memory()` | 已由 950 删除 ✓ |
| `GET_WAIT_NPU_VERSION` | **10** | 950 的探针 **和** 113 的 `mt7915_npu_hw_init()` | **本次修复** |

第二条是上一轮自己埋的：950 v2 为了"探测固件死活"加了版本查询，
而 `WLAN_FUNC_GET_WAIT_NPU_VERSION` 下标是 10 —— **探针本身就是新的楔子源**。
所以删掉命令 32 没能让事情变好：探针紧接着又把 mailbox 打死了。

> 教训：写诊断代码前必须确认它用到的命令在固件表里真的存在。
> 一次约简名下标的 GET ≈ 一枚 mailbox 手雷。

### 修复

- 版本查询统一改用 `WLAN_FUNC_GET_WAIT_NPU_INFO`（下标 0，映射到
  `wifi_mail_get_npu_info`，固件实现 `return 1` 成功）
- 同时把 `NPU_DP_STEP` 从 `1` 提到 `3`，让 mt7915 真正把数据面配置发下去
  （每 band 的 `PCIE_ADDR`、`DESC`、`GET RXDESC_BASE`、DBG 计数器等）。
  这些是 NPU 知道"WiFi 的 ring 在哪"的前提，缺了它即使 sta sync 成功也卸载不了

### 新增的自查脚本

改任何 `WLAN_FUNC_*` 调用前先跑一遍，确认没有命令越界：

```python
# 对照 airoha_offload.h 的枚举 vs 固件表长度（SET<=30, GET<=9）
# 脚本见仓库 README 第 11 章，或直接：
#   SET 有效 0..30 / GET 有效 0..9，超出即越界，一定 wedge mailbox
```

### 排错手法补充

- `CTRL3=0x3` = DONE=1 + STATUS=ERROR：说明**固件有应答**，只是拒绝了这条命令
  → 往"命令不支持/越界"方向查，不要再往"固件死了/时钟断电"方向查
- `CTRL3=0x1` = WAIT_RSP=1 + DONE=0：事务发出去但永不被完成 → 已被 wedge

---

## mt7915_net_fill_forward_path 从未注册（WiFi 卸载最后一环）

### 现象

`ppe/bind` 里只有**有线口之间**的 BND（lan1↔lan4），无线客户端的流从来绑不上：
它的 MAC 偶尔出现在学习表里（`wifi_entries=1`），但 `wifi_bind` 全程为 0。

### 定位：`/proc/kallsyms` 一句话定案

```
$ grep mt7915_net_fill_forward_path /proc/kallsyms   # 本机：无输出
$ grep mt7915_net_setup_tc          /proc/kallsyms   # 本机：ffff... t mt7915_net_setup_tc [mt7915e]
$ cat /sys/module/mt7915e/parameters/wed_enable      # N  ← 没有 MediaTek WED
$ cat /sys/module/mt7915e/parameters/mt7915_npu      # Y  ← NPU 路径已启用
```

113 补丁只把 `net_setup_tc` 的条件放成了
`CONFIG_NET_MEDIATEK_SOC_WED || CONFIG_MT7915_NPU`，
而同一处的 `.net_fill_forward_path` 仍锁在 `#ifdef CONFIG_NET_MEDIATEK_SOC_WED` 里。
本机没有 WED，所以这个钩子**根本没被编译进 mt7915e**。

### 为什么这一环致命

`airoha_ppe_foe_entry_prepare()` 里，出接口是 WiFi netdev 时必须靠
`airoha_ppe_get_wdma_info()` 拿到 `band/bss/wcid`：

```c
if (!airoha_ppe_get_wdma_info(netdev, data->eth.h_dest, &info)) {
        val   |= NBQ(info.idx) | PSE_PORT(FE_PSE_PORT_CDM4);
        qdata |= ACTDP(info.bss);
        wlan_etype = WDMA_BAND(info.idx) | WDMA_WCID(info.wcid);
} else {
        if (!airoha_is_valid_gdm_dev(eth, dev))
                return -EINVAL;          /* WiFi / br-* 出口全栽在这里 */
}
```

而 `airoha_ppe_get_wdma_info()` 走 `dev_fill_forward_path()`，要求路径末端是
`DEV_PATH_MTK_WDMA` —— 这个节点只能由无线驱动的 `net_fill_forward_path` 产生。
钩子缺失 ⇒ `-EINVAL` ⇒ WiFi 出接口的流一条都建不出来。

（顺带确认了另一侧是齐的：`dev_fill_forward_path` 和 mac80211 的
`ieee80211_netdev_fill_forward_path` 都在内核里，桥接流也会写 `wlan_etype`，
`airoha_ppe_foe_entry_prepare()` 第 469 行那个赋值在 type switch 之后统一生效。）

### 修复

- 两个钩子统一在 `CONFIG_NET_MEDIATEK_SOC_WED || CONFIG_MT7915_NPU` 下编译
- NPU 分支用 `mt76_npu_bound()` 替代 `mtk_wed_device_active()` 作为判据
- `wdma_idx` 填 `phy->mt76->band_idx`：airoha 把同一个 idx 同时用作 `NBQ`
  和 `WDMA_BAND`，而固件 `pkt_forward(buf, len, wcid, amsdu, band, ...)`
  就是按 `band`（0/1）取环基址的
- `wcid` 一律填真实值。`0x3ff` 是留给"WiFi 硬件自己解析"的新款 MKROM 组合的，
  NPU 侧必须用它从 `mt7915_npu_wcid_sync()` 同步过的那个 wcid
- 加一条 ratelimited 打印，用来区分"根本没走到钩子"和"走了但 PPE 仍拒绝"

### 验证要点（重要）

**手机必须亮屏/有流量时才能测。** 休眠的手机不回 ICMP，就没有双向流量、
不会产生 established 流，表自然是空的——这跟钩子没修是两回事，别混为一谈。
