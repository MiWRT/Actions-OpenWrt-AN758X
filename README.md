# PonWrt CI — Airoha AN758x PON 云编译

基于 P3TERX `Actions-OpenWrt` 模板重构，源码指向 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（默认分支 `master`），
针对 AN7581 / AN7583 PON 光猫做机型选择、磁盘释放与工具链缓存。

## 目录结构

```
.github/workflows/build-ponwrt.yml     主构建流程（机型可选 / 释放空间 / 工具链缓冲）
.github/workflows/cache-keepalive.yml  每 5 天 touch 缓存，防止被回收
diy-part1.sh    拉取可选插件到 package/custom（passwall/openclash/mosdns/lucky/tailscale 等，默认全关）
diy-part2.sh    默认值定制：① 时区改中国（Asia/Shanghai, CST-8）
                ② 5G WiFi：国家码 CN / 信道 auto / 频宽 160MHz
                ③ 固件版本后追加「作者 + 构建时间」
configs/        每机型一份精简 diffconfig（约 440 行，需 make defconfig 展开）
files/          自定义 rootfs 文件，会自动拷进源码（sbin/tempinfo + 两个 uci-defaults））
packages/npu-clanker-template/   可选插件包的 Makefile 模板（占位符 @PKG_NAME@ 等）
packages/npu-h3c-stock/          H3C HM2004-DU 原厂 NPU 镜像（npu_rv32.bin / npu_data.bin，未修改）
scripts/        NPU 固件脚本：
                  build-npu-fw.sh         现编 ClankerNPU（拉源码 + riscv 工具链 + 体积自检）
                  gen-npu-fw-package.sh   把编出的镜像包成「可选插件包」
                  gen-npu-h3c-package.sh  把 H3C 原厂镜像包成「可选插件包」
                  strip-default-npu-fw.sh 把 stock 固件从 target 的 DEFAULT_PACKAGES 里摘掉
                  apply-npu-dts.sh        给机型 DTS 补 WiFi 卸载保留内存区 / firmware-name
```

## diy 脚本

只有两个，职责单一：

### 索引判据：看 `tmp/.packageinfo`，不看 `package/feeds/custom`

`diy-part1.sh` 把包放进 `package/custom/` 就够了 —— `prepare-tmpinfo` 直接扫
`package/` 目录树（`find -L package -maxdepth 5 -name Makefile`），深度 3 的
`package/custom/<pkg>/Makefile` 必然被扫到，**不需要注册 feed**。

日志里出现 `⚠ package/feeds/custom 不存在` 是**正常现象**，不是索引失败：
`scripts/feeds` 的 `install_src()` 发现包已经 installed（就是上面那份扫出来的）
就直接返回，不会建符号链接。旧版本往 `feeds/luci/applications` 拷贝的兜底也已删除
（luci 是 git feed，拷进去下次 `feeds update -a` 就会被冲掉）。

> 强制重建索引时必须连 `tmp/info/.scan-*.stamp` 一起删。`prepare-tmpinfo` 有
> `scan_unchanged` 优化，stamp 还在且没有更新的 Makefile 时会跳过扫描，
> 于是 `tmp/.packageinfo` 被删了却没人重建。

### diy-part1.sh —— 拉插件

**默认开启**：

| 开关 | 包 | 作用 |
|------|-----|------|
| `ADD_AIROHA_NPU` | `luci-app-airoha-npu` | Airoha SoC 状态页：NPU 卸载 / CPU 频率与超频 / Frame Engine / PPE 流表 |

另外 CI 仓库自带两个本地包（`packages/`，不走 clone，由 diy-part1.sh 拷进 `package/custom`）：

| 包 | 作用 |
|-----|------|
| `luci-app-pon-status` | PON 光模块卡片：**温度 / 收光 / 发光 / 偏置电流 / 供电电压**，表格形式显示在概览页「系统」下一格 |
| `luci-app-natmode` | NAT 类型三选一：**全锥形 NAT1 / 受限型 NAT3 / 全对称型 NAT4**，菜单「网络 → NAT 类型」 |

其余默认关闭：`ADD_PASSWALL` / `ADD_OPENCLASH` / `ADD_MOSDNS` / `ADD_LUCKY` /
`ADD_TAILSCALE` / `ADD_OPENLIST` / `ADD_SMARTDNS`。

### luci-app-airoha-npu 的源与中文

**源仓库：`luanmuc/luci-app-airoha-npu`**（`rchen14b` 的 fork 改进版）：

| | rchen14b（原版）| luanmuc（本仓库选用）|
|---|---|---|
| 中文翻译 | ❌ po/ 只有 es + templates | ✅ 自带 `po/zh_Hans`，48 条全翻 |
| 仓库结构 | ⚠ 根目录 + 同名子目录各一份，feed 索引会中断 | ✅ 单层，正常 |
| luci.mk 路径 | 需 feeds 在固定位置 | ✅ 已修 |

## 固件版本后追加「作者 + 构建时间」

LuCI 概览页「固件版本」现在长这样：

```
PonWrt SNAPSHOT · qwe3017 · 2026-09-30 17:09
```

### 原理（别改错文件）

LuCI 读的是 `/etc/openwrt_release` 里的 `DISTRIB_DESCRIPTION`。这个文件由
`base-files` 提供，编译时装完 ipk 后用 `VERSION_SED_SCRIPT` 把模板里的占位符替换：

| 占位符 | 含义 | ponwrt 默认 |
|---|---|---|
| `%D` | `VERSION_DIST` | `PonWrt` |
| `%V` | `VERSION_NUMBER` | `SNAPSHOT` |
| `%C` | `VERSION_CODE` | 空 |

所以改的是**模板** `package/base-files/files/etc/openwrt_release`
（`diy-part2.sh` 第 5 段），编译时自动替换 —— 不需要首启脚本，也不会被 ipk 覆盖。

> 不要写 `files/etc/openwrt_release`：那会把版本号写死，`%D %V` 就没了。
> `os-release` 里的 `%B` 只有 `SOURCE_DATE_EPOCH` 时间戳，不可读，所以构建
> 时间由脚本自己格式化。

### 怎么改

| 方式 | 做法 |
|---|---|
| 换作者名 | workflow 输入项 `fw_author`（默认 `qwe3017`） |
| 固定构建时间 | 环境变量 `FW_BUILD_TIME`（留空 = 自动取构建时刻，Asia/Shanghai） |
| 完全自定义后缀 | 环境变量 `FW_DESC_SUFFIX`（填了就忽略上面两个，例如 `\| built by A/B #1`） |
| 改 `diy-part2.sh` 顶部常量 | 同上三个常量，编译期生效 |

`FW_DESC_SUFFIX` 里带 `/` `|` `#` `&` 也没问题 —— 脚本用 perl + 环境变量传
替换文本，不走 sed 分隔符。

若 `.config` 里设了 `CONFIG_VERSION_CODE`，模板会自动保留 `%C`，不会出现连续空格。

## 5G WiFi 默认值（国家码 CN / 信道 auto / 160MHz）

由 `diy-part2.sh` 第 4 段实现，落在
`files/etc/uci-defaults/96-wifi-5g-cn`（**首启执行**）。

### 默认值

| 选项 | 值 |
|---|---|
| `country` | `CN`（中国） |
| `country_ie` | `1`（beacon 中广播国家码） |
| `channel` | `auto`（自动选信道 / ACS） |
| `htmode` | `HE160`（160MHz，WiFi 6）；不支持则回落 `HE80` |

编辑 `diy-part2.sh` 顶部的编译期常量（会被注入 uci-defaults 脚本）：

```bash
WIFI_5G_COUNTRY="${WIFI_5G_COUNTRY:-CN}"
WIFI_5G_CHANNEL="${WIFI_5G_CHANNEL:-auto}"
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE160}"
WIFI_5G_FALLBACK="${WIFI_5G_FALLBACK:-HE80}"
```

也支持 workflow 层通过环境变量覆盖。

### 注意事项

- **DFS**：CN 法规下 160MHz 需要信道 36–64，其中 52–64 属 DFS 信道。
  ACS 若选中，启动时会先做雷达检测（CAC），**WiFi 可能延迟 1–10 分钟才出现**
  或自动跳频。这是正常现象，不是故障。

## PON 光模块卡片（概览页系统下一格）

`packages/luci-app-pon-status`（本地包，非第三方 clone）在概览页新增
「PON 光模块」卡片，位置为**「系统」卡片的下一格**。

### 显示内容

| 字段 | 来源字段 | 单位 |
|------|---------|------|
| 收光功率 | `rx_power_dbm` | dBm |
| 发光功率 | `tx_power_dbm` | dBm |
| 光模块温度 | `temperature_celsius` | °C |
| 偏置电流 | `tx_bias_ma` | mA |
| 供电电压 | `voltage_volts` | V |

### 开关：SHOW_PON_OPTICS

`tempinfo` 顶部有一个开关：

```sh
SHOW_PON_OPTICS=1    # 温度行附带 PON 光功率/电流/电压
SHOW_PON_OPTICS=0    # 只显示温度（CPU / WiFi / PON）
```

设为 `0` 时输出：`CPU: 58.7°C, WiFi: 46.0°C 48.0°C, PON: 48.5°C`

本仓库**默认设为 `0`**，因为 `luci-app-pon-status` 卡片已用表格形式完整展示
收发光/电流/电压，两者会重复。若你想只要一行、不装 pon-status 卡片，改回 `1` 即可。

### 一点开销说明

概览页轮询间隔 3 秒，故 `tempinfo` 每 3 秒执行一次 `ponctl`。
`ponctl` 是 Rust 二进制、只读 sysfs，开销可忽略。
但注意 `luci-app-pon-status` 卡片同样每 3 秒调一次 `ponctl`，
两者叠加即约每 1.5 秒一次 `ponctl` 调用 —— 若在意，把 `SHOW_PON_OPTICS` 设 `0` 即可减半。

## Release 行为

- 只有 `scope=firmware` 且编译成功才发 Release；`toolchain-only` 不发。
- 空固件目录会跳过，不会发空 Release。
- `fail_on_unmatched_files: false`：机型产物后缀不同（`*.itb` / `*.ubi` / `*.bin` / `*.manifest` 等），缺哪种都不会让这一步失败。
- 自动清理：每个机型的 Release 只保留最近 10 个（`delete_tag_pattern: ^<DEVICE_NAME>-`，不会误删 `toolchain-cache`）。
- 关掉 Release 只留 Artifact：把 `upload_release` 选 `false`，或把 env 里 `UPLOAD_RELEASE` 默认值改成 `'false'`。

> 首次运行建议先 `scope=toolchain-only`（不产固件、不发 Release）把工具链缓存建起来，再跑 `firmware`。

## 支持的机型

| SoC | profile |
|-----|---------|
| AN7581 | `fiberhome_hg5382a` `fiberhome_hg5585f-ct` `fiberhome_hg5585f-cu` `gemtek_xg2010g` `nokia_xg-040g-md-ubi` `nokia_xg-040g-tf-ubi` `unionman_ung00a` `znxt_zn504xg-d` `znxt_zn515xg-d` |
| AN7583 | `nokia_xg-040g-mf` `nokia_xg-040g-mf-ubi` |

机型名写错会在 `Generate toolchain cache key` 步骤直接报 `::error::` 并退出，不会静默地全机型编译。

## 源码分支：必须是 ponwrt 的 `npu`

MT7916 的 NPU 卸载补丁**直接推进了 `qwe3017/ponwrt` 的 `npu` 分支**，本仓库不再
外挂注入任何 mt76 / kernel 补丁。所以 `branch` 输入的默认值是 `npu`，别改回去。

编译前 CI 会用 `Verify NPU patches (MT7916 offload)` 步骤逐项确认源码树里有下面这些，
缺任一项直接 `::error::` 退出（不会让你刷完机才发现没编进去）：

| 文件 | 作用 |
|---|---|
| `package/kernel/mt76/patches/120-mt76-add-airoha-mt7915-kite-npu.patch` | mt76 里 MT7915/MT7916 的 Kite NPU 卸载实现（r65 系列 120–179 的第一个） |
| `package/kernel/mt76/Makefile` 含 `CONFIG_MT7915_NPU` | an7581 下打开该实现 |
| 同上，含 `npu_control=Y` | 模块参数真正打开 NPU（`wed_enable=Y` 是从 filogic 照抄的空转参数） |
| `patches-6.18/933-net-airoha-npu-kite-memory-profile.patch` | Kite 内存 profile；TX 区未预留就跳过对应命令 |
| `patches-6.18/944-airoha-kite-ppe-flowtable-datapath.patch` | PPE + flowtable 下行数据面，r65 这套的核心 |
| `target/linux/airoha/dts/an7581-npu-mt7916.dtsi` | MT7916 的 NPU 保留内存区（pkt + ba，0x92000000/0x94c00000）+ `airoha,clanker-kite-abi` |
| `package/firmware/airoha-clanker-npu/Makefile` | NPU 固件从源码现编（ClankerNPU），不是 linux-firmware 里的那份 |
| `package/devel/airoha-riscv-toolchain/Makefile` | 编 NPU 固件要的 host 工具链 |

同时会**反向校验**旧的 `113-mt7915-add-airoha-npu-offload-support.patch` 和
`950-net-airoha-npu-skip-tx-regions-not-reserved-in-dt.patch` 已经不在了 ——
它们和 r65 的补丁都新建 `mt7915/npu.c`，不可能共存。若还在，说明拉到了合并前的树。

> 这套栈是 2026-10-06 整体合并上游 `ntp2000/ponwrt` 的 `port/r65-npu-wifi`
> （merge 提交 `93943d57e1`）换来的，是一个整体 ABI，别只挑其中几个补丁。

> ⚠ 另一个常见坑是 GitHub Actions 页面上的 **"Use workflow from"** 下拉：它决定
> checkout 的是哪个分支。选错分支会拉到没有 workflow 改动（branch 默认还是 master）
> 的那一份，等于白跑一轮。

## Wi-Fi 卸载：只有 NPU（Clanker/Kite），WED 已摘除

**2026-10-06 结论：WED 路线已判死刑，本仓库不再注入任何 WED 代码。**
卸载栈整体换成了上游 `ntp2000/ponwrt` 的 `port/r65-npu-wifi`
（merge 提交 `93943d57e1`）—— 它 `NET_VENDOR_MEDIATEK` 是关的，根本不用 WED，
下行和上行都走 NPU + PPE flowtable 数据面。

判死刑的依据是三条实测，不是推测：

1. WED 四件套真的编进固件了：`airoha_wed` / `airoha_wdma` 都在 `lsmod` 里，
   `1fa02000.wed` / `1fa06000.wdma` 都在，`WED_REV=0x76220001` 读得到，
   `mtk_soc_wed_ops published`。
2. **干跑（`attach_enable=0`）寄存器全对**：`PCIE_CFG_BASE=0x1fc20000`
   （pcie1 = 7906 ✓）、`WDMA CFG_BASE=0x1fa00000` ✓、
   `WED_PCIE_INT_CTRL=0x00101000`（= H3C 原厂值）✓、`wpdma_phys=0x241d7000`，
   而且设备活得很好 ⇒ 配置不是病根。
3. **真 attach（`attach_enable=1`）把设备打重启**。对照实验里 `wed_enable=N`
   做同样的 PCI remove/rescan 完全正常 ⇒ 崩在 attach 成功之后的路径。

另外 mt76 的 `wed_enable` 默认就是 `N`（我们只给 filogic 段加了 `=Y`，
airoha 没有），所以之前那些「WED 没效果」的构建里 WED 从头到尾没 attach 过。
r65 的 `MODPARAMS.mt7915e` 里那个 `wed_enable=Y` 只是从 filogic 照抄的空转参数，
真正起作用的是 `npu_control=Y npu_enable=Y npu_tx=Y`。

> 旧的 `packages/airoha-wed/` 和 `patches/kernel-wed/`（960–964）已删除，
> `wifi_offload` 只剩 `npu` 一个选项，传 `both` / `wed` 会直接报错退出。
> 需要回看历史的话在 git 里找（删除提交 `7ff5d4c`）。

## NPU 固件选择（r65 / stock / h3c / clanker / none）

NPU 是 Airoha SoC 里那颗 RISC-V 核，**不是** Linux 驱动 —— host 端驱动 `airoha_npu`
随内核编出，它按固定名字找两个固件镜像：

| 镜像 | 默认文件名 | 上限 | 加载去向 |
|---|---|---|---|
| rv32（text+rodata） | `airoha/en7581_npu_rv32.bin`（AN7583 为 `an7583_*`） | 2 MiB | `npu_binary` @0x84000000 |
| data（.data） | `airoha/en7581_npu_data.bin` | 64 KiB | NPU 本地 SRAM |

`npu_fw` 决定用哪一份：

| 选项 | 行为 |
|---|---|
| `r65`（**默认**）★ | 用 ponwrt 自带的 `airoha-clanker-npu` 包，即 ClankerNPU `735529c` + 46 个补丁，`SOC=AN7581 WIFI=MT7916 NPUTX=1` 现编。**这是与当前内核/mt76 栈配套的那一版** |
| `stock` | 用 `airoha-en7581-npu-firmware`（linux-firmware 里的镜像，MT7992 / **eagle** 数据面）。⚠ 与已合并的 r65 驱动栈**不是同一套 ABI**，别在 npu 分支上用 |
| `h3c` | 用 H3C HM2004-DU 原厂镜像（仓库自带，配 MT7916 出厂的那份），见下节 |
| `clanker` | 用 [ClankerNPU](https://github.com/ClankerConstruction/ClankerNPU) 现编，变体由 `npu_wifi` 决定（自己指定的源码 ref，做实验用） |
| `none` | 不装任何固件（NPU 不起，只剩有线软件转发） |

> ⚠ **为什么默认从 `stock` 改成了 `r65`**：内核补丁 931–983 + mt76 120–179 和它
> 的固件是**同一个 ABI**。r65 驱动会以 `airoha,clanker-kite-abi` 去问固件要
> `GET_WAIT/SET_WAIT`，而 stock 那份是 Eagle/原厂 ABI，不支持这些命令
> （`airoha,skip-npu-version-query` 就是为此存在的：Clanker 的 GET_WAIT 是 0..9，
> Linux 的版本查询是 GET_WAIT 10）。配错不会出现编译错误，只会静默不卸载。

### H3C 原厂镜像（`npu_fw=h3c`）

`packages/npu-h3c-stock/` 里放的是从 H3C HM2004-DU 原厂系统 `/userfs` 原样取出的
两份镜像（未做任何修改，md5 在脚本里每次校验）：

| 文件 | 大小 | md5 |
|---|---|---|
| `npu_rv32.bin` | 90644 B | `e2551187360799dadaea241f4973d80a` |
| `npu_data.bin` | 2764 B | `18849de11feb56c008742fcb50576ecf` |

生成的包名为 `airoha-en7581-mt7916-h3c-npu-firmware`，勾选方式同 ClankerNPU：

```sh
CONFIG_PACKAGE_airoha-en7581-mt7916-h3c-npu-firmware=y
```

**和 stock / clanker 的关键差异**——体积只有 ~90KB（ClankerNPU 现编约 2MB）不是损坏，
它跑的是**配 MT7916 的裁剪版 NPU 固件**：

- 不支持专用 NPU ring / HW-RRO / TX 数据面（固件里对应的 mailbox wrapper 直接打
  `"not support on 791X"`），下行走 **TDMA 快转**；
- 因此它是 MT7916 上一张「厂商自己跑通过」的对照卡：如果 `stock` 那份
  linux-firmware 镜像起不来，用它做 A/B，就能区分「镜像不支持 MT7916」还是
  「host 驱动 / DTS 有问题」。

原厂镜像本名就是 `npu_rv32.bin` / `npu_data.bin`，安装时按驱动默认前缀
（`en7581`）改名落盘，所以**不用改 DTS 的 `firmware-name`**。

### ClankerNPU 固件现在是「可选插件包」

`npu_fw=clanker` 不再用 `files/lib/firmware/airoha/` 覆盖 rootfs，而是生成一个标准
OpenWrt 包放进 `package/custom/`，之后就能用 config 符号勾选：

```sh
CONFIG_PACKAGE_airoha-en7581-mt7916-npu-firmware=y
```

包命名规则 `airoha-<soc>-<wifi>-npu-firmware`：

| SoC | 包名 |
|---|---|
| AN7581 | `airoha-en7581-mt7916-npu-firmware` / `airoha-en7581-mt7992-npu-firmware` / `airoha-en7581-mt7996-clanker-npu-firmware` |
| AN7583 | `airoha-an7583-mt7916-npu-firmware` / `-mt7992-` / `-mt7993-` / `-mt7996-` / `-nowifi-` |
| AN7552 | `airoha-an7552-mt7916-npu-firmware` / `-mt7991-` / `-mt7993-` |

> AN7581 + MT7996 会撞上 linux-firmware 已有的 `airoha-en7581-mt7996-npu-firmware`，
> 生成脚本会自动改名成 `airoha-en7581-mt7996-clanker-npu-firmware`，避免包符号重名。

**怎么选**：工作流默认按 `npu_wifi` 推断出一个变体并自动写入 `=y`。想自己定，
在 `configs/<机型>.config` 里直接写那一行即可 —— `Select NPU firmware package`
步骤检测到就会沿用你的选择，不会覆盖。

**为什么必须先摘 DEFAULT_PACKAGES**：`airoha-en7581-npu-firmware` 是 an7581
subtarget 的 `DEFAULT_PACKAGE`，`make defconfig` 会把它强制拉回 `=y`，于是它和
ClankerNPU 包同时进 rootfs —— 两个包装的是同一批文件名，谁生效取决于安装顺序。
`scripts/strip-default-npu-fw.sh`（4.5 步）把这三个 stock 包从
`target/linux/airoha/**` 的 `DEFAULT_PACKAGES` / `DEVICE_PACKAGES` 里摘掉，
装哪个就完全由 `.config` 说了算。包符号本身还在，`npu_fw=stock` 照样能 `=y` 勾上。

### 相关输入项

| 输入 | 默认 | 说明 |
|---|---|---|
| `npu_fw` | `stock` | `stock` / `h3c` / `clanker` / `none` |
| `npu_wifi` | `auto` | 变体：`auto` 按机型推断，或手动选 `MT7916` `MT7992` `MT7996` `MT7991` `MT7993` `NOWIFI`；`all` = 该 SoC 所有变体都编成可选包，只默认勾一个 |
| `npu_default_wifi` | `MT7916` | `npu_wifi=all` 时默认勾选哪个变体 |
| `npu_clanker` | `0` | `1` = 适配 Clanker 自改的 host driver。**配 ponwrt 自带驱动必须保持 0** |
| `npu_fw_prefix` | 空 | 固件名前缀。空 = 驱动默认名（`en7581` / `an7583`），此时不用改 DTS |
| `npu_wlan_mem` | `true` | 给机型 DTS 补 WiFi 卸载必需的保留内存区（pkt / tx-pkt / tx-bufid / ba） |
| `npu_src_ref` | `main` | ClankerNPU 源码 ref（`main`=跟上游最新，也可填 commit sha / tag 钉死版本） |
| `npu_fw_files_fallback` | `false` | `true` = 额外把镜像铺进 `files/lib/firmware/airoha` 兜底（**开了以后包置 n 也会生效**，破坏可选语义，仅排查用） |

### 可用变体（ClankerNPU 共 11 个）

| SoC | 可选 WiFi 芯片 |
|---|---|
| AN7552 | MT7916、MT7991、MT7993 |
| AN7581 | MT7916、MT7992、MT7996 |
| AN7583 | MT7916、MT7992、MT7993、MT7996、NOWIFI |

`MT7916` / `MT7996` 走 **kite** 数据面，`MT7991` / `MT7992` / `MT7993` 走 **eagle**。
组合写错会在 `Build NPU firmware` 步骤开头直接报错，不会白跑一趟编译。

### 执行顺序（不能反）

```
4.5  Strip stock NPU firmware   ← 摘掉 DEFAULT_PACKAGES 里的 stock 固件（必须先做）
diy-part1.sh 拉插件
  └─> 5.5  Build NPU firmware package   ← 现编 + 生成 package/custom/airoha-<soc>-<wifi>-npu-firmware
                                           再 re-index custom feed（不索引符号就不存在）
载入 .config（基座 + 机型精简配置）
裁剪机型
  └─> 7.5  Select NPU firmware package  ← 统一重写 CONFIG_PACKAGE_airoha-*-npu-firmware
diy-part2.sh
make defconfig + 校验（含 NPU 固件包符号校验）
```

### 典型用法

| 场景 | 输入 |
|---|---|
| HG5585F-CT / ZN515XG-D 换成 kite 固件 | `npu_fw=clanker`（`npu_wifi` 自动推断为 MT7916）→ 得到 `CONFIG_PACKAGE_airoha-en7581-mt7916-npu-firmware=y` |
| 把 AN7581 的全部变体都编成可选包 | `npu_wifi=all`，再在 configs 里挑一个写 `=y` |
| Nokia XG-040G-MF（AN7583） | `profile=nokia_xg-040g-mf` + `npu_fw=clanker` + `npu_wifi=MT7993` |
| 只想要有线 PPE / HWNAT 卸载 | `npu_wlan_mem=false` |
| 完全不装固件 | `npu_fw=none` |
| 想钉死某一版固件 | `npu_src_ref=<commit sha>`（如 `735529c10d5120e10f7e4a6ddf97fb384fce9903`） |

### 注意事项

1. **`npu_clanker` 保持 0**：`CLANKER=1` 会加 `-DUSE_CLANKER_DRIVER`，是给 Clanker 自己改的
   host driver 用的，其 Makefile 注释明说配 stock 驱动可能坏；且它只影响 eagle 的 `sta_q`
   与 SRAM type 41 的 sizing，kite 变体开了也没差别。
2. **工具链必须是 elf/newlib**：固件用 `-march=rv32imc_zicsr_zifencei -mabi=ilp32` 编，
   `riscv64-linux-gnu` 编不了；脚本会自动下载 xpack `riscv-none-elf-gcc 14.2.0-3`（约 100 MB）。
3. **data 段只有 64 KiB 上限**，比 rv32 的 2 MiB 紧得多；脚本编完先自检，超限直接失败，
   不会编出刷上才炸的镜像。
4. **`npu_src_ref` 默认 `main`（跟上游最新）**：好处是总能吃到 ClankerNPU 的修复，
   代价是**不同时间跑 CI 编出的固件可能不同** —— 上游一改代码，行为就跟着变（且没法复现）。
   出问题时建议填 commit sha 钉死，先本地编一次验证再定。
   无论用哪种，Release 说明里都会记下当次的实际 gitrev，可以回溯这台机器刷的是哪版。
5. **机型 → WiFi 映射表**在 `Resolve device profile` 步骤里，只登记了
   `fiberhome_hg5585f-ct/cu` 与 `znxt_zn515xg-d/znxt_zn504xg-d`；其他机型会打 warning
   并回退 MT7916，请手动选 `npu_wifi`。
6. **`profile=all` + `clanker`** 只会给所有机型装同一份固件，脚本会 warning，建议按机型分别编。
7. Release 说明里会带上 NPU 固件的 SoC / 变体 / gitrev / 可选包名 / 两个 bin 的大小，便于回溯版本。
8. **包没进索引的表现**：`package/custom/` 下有包目录，但固件里没有固件文件，且不报错。
   原因是 `CONFIG_PACKAGE_xxx` 符号不存在，defconfig 把 `=y` 当无效符号静默删掉。
   5.5 步会 re-index custom feed 并打印 `package/feeds/custom/` 链接，
   9 步在 defconfig 后强制校验符号仍为 `=y`，失败会带 5 条排查线索直接退出。

### 刷完怎么验

```sh
dmesg | grep -i npu           # probe 时打 NPU fw version，固件 boot 行带 GITREV
ls -l /lib/firmware/airoha/   # 两个 bin 在位
```

- 缺文件或名字不匹配：`request_firmware_direct()` 返回 `-ENOENT`，驱动映射成 `-EPROBE_DEFER`，
  NPU 一直不绑定（`deferred probe pending` 里能看到具体文件名），不会像以前那样卡 60 秒 sysfs fallback。
- 大小超限：直接 `-E2BIG`。
- LuCI「Airoha SoC 状态页」（`luci-app-airoha-npu`）可看 NPU 卸载 / PPE 流表是否正常。

## 工具链缓存机制

- Key：`ponwrt-toolchain-<board>-<subtarget>-<tools/toolchain 源码 md5 前 16 位>`，源码工具链一变就失效重编。
- 命中顺序：`actions/cache` → 仓库 `toolchain-cache` Release 备份 → 本地编译。
- Release 命中后会回写 `actions/cache`，下次构建走快通道。
- 命中缓存时用 `sed -i 's/ $(tool.*\/stamp-compile)//' Makefile` 跳过工具链重编。
  （对 ponwrt 根 Makefile 确实命中第 46 / 47 / 130 行，去掉 `$(tools/stamp-compile)`、
  `$(toolchain/stamp-compile)` 依赖。）
- 额外缓存：`.ccache`（编译缓存）、`dl`（软件包下载目录）。

### 缓存 key 的滚动周期

`dl` 与 `ccache` 的 key 都用**年+周号**（`$(date +%Y%W)`，如 `202639`），由
`Resolve device profile` 步骤的 `week` output 提供。

| 缓存 | key |
|------|-----|
| dl | `ponwrt-dl-<branch>-<week>` |
| ccache | `ponwrt-ccache-<soc>-<week>` |

原因是这两个缓存**体积大且会每次 save**：

- 若用 `github.run_id` / `github.run_number`，每次运行都会生成一份新副本，
  10GB 配额很快被刷满，并淘汰掉真正有用的旧缓存；
- 改成周号后，同一周内多次运行复用同一条目，`restore-keys` 仍能跨周命中。

### ccache：默认关闭，按需开启

ccache 默认**关闭**（`USE_CCACHE: false`，config 里也不写 `CONFIG_CCACHE`）。
原因是一个真实的缓存一致性陷阱：

`tools/Makefile`：

```makefile
ifneq ($(CONFIG_CCACHE)$(CONFIG_SDK),)
  tools-y += ccache xxhash
endif
```

即 **ccache 二进制只在 `CONFIG_CCACHE` 生效时才由 `make tools/install` 编入**
`staging_dir/host/bin`。而 `rules.mk`：

```makefile
ifneq ($(CONFIG_CCACHE),)
  TARGET_CC:= ccache $(TARGET_CC)
  export CCACHE_DIR:=$(TOPDIR)/.ccache
endif
```

于是出现这种失败：

| 时序 | 结果 |
|------|------|
| 工具链缓存是**未开 ccache** 时建立的 | 缓存里没有 `staging_dir/host/bin/ccache` |
| 之后开启 `CONFIG_CCACHE=y` + 缓存命中 | `make tools/install` 被跳过 → ccache 没被补装 |
| 编译任何包 | `/bin/sh: 1: .../staging_dir/host/bin/ccache: not found`（**Error 127**）|

要开启 ccache，**只改一处**：workflow 的 `USE_CCACHE: true`。
流程里「Setup ccache (opt-in)」步骤会：

1. 自动往 `.config` 追加 `CONFIG_CCACHE=y` 并 `make defconfig`；
2. 检测 `staging_dir/host/bin/ccache`，缺失就 `make tools/ccache/install` 补装
   （ccache 依赖 `xxhash` → `cmake`，首次会多花几分钟）；
3. 补装失败则自动把 `CONFIG_CCACHE` 改回 `is not set` 并继续编译 ——
   **绝不会因为 ccache 让整次构建失败**。

> 提醒：开启后 `.ccache` 会额外占用磁盘，注意 runner 剩余空间。

## 首次使用建议

免费 runner 单次上限 6 小时，首次全量编译（工具链 + 内核 + 全包）大概率超时：

1. 先跑一次 `scope = toolchain-only`，把工具链缓存建起来；
2. 再跑一次 `scope = firmware` 出固件；
3. 若仍超时，把 `configs/*.config` 里不需要的 luci-app / 语言包删掉再提交。

