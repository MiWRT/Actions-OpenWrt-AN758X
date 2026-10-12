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
                ③ 概览页「CPU 使用率（%）」行：USR/SYS + 每核明细
                ④ 固件版本后追加「作者 + 构建时间」
configs/        每机型一份精简 diffconfig（约 440 行，需 make defconfig 展开）
files/          自定义 rootfs 文件，会自动拷进源码（sbin/tempinfo + sbin/cpuusage + 两个 uci-defaults）
scripts/        编译期脚本：
                  patch-luci-cpuusage.sh     把概览页 CPU 使用率行的取值命令改指 /sbin/cpuusage
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
（`diy-part2.sh` 末段），编译时自动替换 —— 不需要首启脚本，也不会被 ipk 覆盖。

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

## 概览页「CPU 使用率（%）」行：USR/SYS + 每核明细

ImmortalWrt 的 luci 默认只给一个总占用率（图左），改为下图右的样式：

```
CPU 使用率（%）   5%                                    ← 原来
CPU 使用率（%）   USR: 2% SYS: 1% · C0 3%/1% C1 0%/0% C2 1%/2% C3 4%/1%
```

`C0 … C3` 依次是每个核心的「USR%/SYS%」。

### 原理（别改错文件）

这一行是「前端渲染 + rpcd 取值」两段拼起来的，实际只改了后者：

| 环节 | 文件 | 说明 |
|------|------|------|
| 文案 + 渲染 | `luci-mod-status/htdocs/.../view/status/include/10_system.js` | `_('CPU usage (%)'), cpuusage.cpuusage`，**不动** |
| 取值 | `luci-base/root/usr/share/rpcd/ucode/luci` 的 `getCPUUsage` | 原本是 `top -n1 \| awk '/^CPU/ {printf("%d%", 100 - $8)}'` |
| 授权 | `luci-mod-status/root/usr/share/rpcd/acl.d/luci-mod-status.json` | 已授权 `luci [ "getCPUUsage" ]`，**不动** |
| 数据源 | `files/sbin/cpuusage`（本仓库新增） | 两次 `/proc/stat` 采样求差值 |

前端拿到什么就原样塞进单元格，`luci.getCPUUsage` 在 LuCI 里也只有这一个调用方
（整个 immortalwrt/luci 里引用它的就上面三处），所以 `scripts/patch-luci-cpuusage.sh`
只把 `popen()` 里的**那一个命令字符串**换掉即可 —— 补丁前后只差 1 行：

```diff
-			const fd = popen('top -n1 | awk \'/^CPU/ {printf("%d%", 100 - $8)}\'');
+			const fd = popen('sh /sbin/cpuusage');
```

**为什么走 `sh /sbin/cpuusage`**：直接 exec 要求脚本带可执行位，而这个位在
Windows 打包 / 解压 / git checkout 链路上反复丢失（`luci-app-pon-status` 的
`ponstat-conn` 踩过同一个坑）。经 `/bin/sh` 读脚本内容就不依赖它了。

### 数值口径

两次 `/proc/stat` 采样（间隔 `SAMPLE_DELAY`，默认 0.2 s）取差值，**不是**开机至今的平均值：

| 显示 | 计算 |
|------|------|
| `USR` | `user + nice` |
| `SYS` | `system + irq + softirq` |
| 每核 | 同上，取 `/proc/stat` 的 `cpuN` 行 |

`guest` / `guest_nice` 不计入 —— 内核已把它们算在 `user` / `nice` 里，再加一次会重复计数。
所以 `USR + SYS` 通常**小于**旧口径的 `100 - 空闲`（后者还含 iowait / nic 等），属正常。

### 失败时的行为

纯显示层的东西，任一环节不满足都只 `::warning::`，**不会让构建失败**：

| 情况 | 表现 |
|------|------|
| `files/sbin/cpuusage` 不在源码树 | 跳过补丁，这一行维持原来的单个占用率 |
| `feeds/` 下找不到 `*rpcd/ucode/luci`（换 fork / LuCI 版本不同） | 同上 |
| 有 `getCPUUsage` 但命令行变了（上游改实现） | 同上，并提示同步本脚本的 `OLD_FIX` / `NEW_FIX` |
| 脚本在设备上采样失败（`/proc/stat` 读不到等） | 脚本内部退回 `top -n1` 的旧口径，这一行永远有值 |

想临时关掉：把 `diy-part2.sh` 里调用 `scripts/patch-luci-cpuusage.sh` 的那段注释掉即可。

### 想换显示格式

只改 `files/sbin/cpuusage` 里 awk 的 `END` 段（`sprintf` 那两行）就行，例如去掉每核明细
只留总量：删掉拼 `cores` 的那一支即可。数值口径改 `SAMPLE_DELAY`（这行是纯变量，不必动 awk）。

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

## NPU 固件

NPU 是 Airoha SoC 里那颗 RISC-V 核，**不是** Linux 驱动 —— host 端驱动 `airoha_npu`
随内核编出，它按固定名字找两个固件镜像：

| 镜像 | 默认文件名 | 上限 | 加载去向 |
|---|---|---|---|
| rv32（text+rodata） | `airoha/en7581_npu_rv32.bin`（AN7583 为 `an7583_*`） | 2 MiB | `npu_binary` @0x84000000 |
| data（.data） | `airoha/en7581_npu_data.bin` | 64 KiB | NPU 本地 SRAM |

固件由 ponwrt 自带的 linux-firmware 包提供（`airoha-en7581-npu-firmware` /
`airoha-an7583-npu-firmware`），在 `configs/<机型>.config` 里写
`CONFIG_PACKAGE_airoha-en7581-npu-firmware=y` 即会装进 rootfs。

工作流**不介入**固件的生成与选择：不再有现编、变体推断、DEFAULT_PACKAGES 摘除
等环节。要换固件就改 config 里那一行，改完照常 `make defconfig` 生效。

### 刷完怎么验

```sh
dmesg | grep -i npu           # probe 时打 NPU fw version
ls -l /lib/firmware/airoha/   # 两个 bin 在位
```

- 缺文件或名字不匹配：`request_firmware_direct()` 返回 `-ENOENT`，驱动映射成
  `-EPROBE_DEFER`，NPU 一直不绑定（`deferred probe pending` 里能看到具体文件名）。
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

