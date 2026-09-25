# PonWrt CI — Airoha AN758x PON 云编译

基于 P3TERX `Actions-OpenWrt` 模板重构，源码指向 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（默认分支 `master`），
针对 AN7581 / AN7583 PON 光猫做机型选择、磁盘释放与工具链缓存。

## 目录结构

```
.github/workflows/build-ponwrt.yml     主构建流程（机型可选 / 释放空间 / 工具链缓冲）
.github/workflows/cache-keepalive.yml  每 5 天 touch 缓存，防止被回收
diy-part1.sh    拉取可选插件到 package/custom（passwall/openclash/mosdns/lucky/tailscale 等，默认全关）
diy-part2.sh    把默认时区改成中国（Asia/Shanghai, CST-8）
configs/        每机型一份精简 diffconfig（约 440 行，需 make defconfig 展开）
files/          可选：自定义 rootfs 文件，会自动拷进源码
```

## diy 脚本

只有两个，职责单一：

### diy-part1.sh —— 拉插件

**默认开启**：

| 开关 | 包 | 作用 |
|------|-----|------|
| `ADD_AIROHA_NPU` | `luci-app-airoha-npu` | Airoha SoC 状态页：NPU 卸载 / CPU 频率与超频 / Frame Engine / PPE 流表 |

另外 CI 仓库自带一个本地包（`packages/luci-app-pon-status`，不走 clone，由 diy-part1.sh 拷进
`package/custom`）：把 **PON 光模块的温度、收光功率、发光功率** 以表格形式显示在概览页。


其余默认关闭：`ADD_PASSWALL` / `ADD_OPENCLASH` / `ADD_MOSDNS` / `ADD_LUCKY` /
`ADD_TAILSCALE` / `ADD_OPENLIST` / `ADD_SMARTDNS`。

⚠️ 两点：
- 拉取目录名必须等于包名（`luci.mk: PKG_NAME ?= $(notdir ${CURDIR})`），
  改目录名会导致 config 里的符号对不上。
- 默认开启的 `luci-app-airoha-npu` 若拉取失败，脚本会 `::error::` 退出——否则 `defconfig`
  会静默剔除，编出缺状态页的固件还不易察觉。要关就把开关和 config 里的 `=y` 一起改。


## PON 光模块状态上概览页

`packages/luci-app-pon-status`（本地包，非第三方 clone）在「状态 → 概览」新增一个
「PON 光模块」卡片，显示：

| 字段 | 来源字段 | 单位 |
|------|---------|------|
| 收光功率 | `rx_power_dbm` | dBm |
| 发光功率 | `tx_power_dbm` | dBm |
| 光模块温度 | `temperature_celsius` | °C |
| 偏置电流 | `tx_bias_ma` | mA |
| 供电电压 | `voltage_volts` | V |

### 数据链路

```
概览页 include(70_pon.js)
  → rpcd file.exec（ACL: luci-app-pon-status）
  → ponctl --device <dev> status --json
  → airoha-ponctl 的 convert_optics() 已把 SFF-8472 原始值换算成显示单位
```

换算规则（`airoha-ponctl/src/src/status.rs`）：

| 原始字段 | 换算 | 输出字段 |
|---------|------|---------|
| `temperature_8472` | ÷ 256 | `temperature_celsius`（°C）|
| `voltage_8472` | × 1e-4 | `voltage_volts`（V）|
| `tx_bias_8472` | × 0.002 | `tx_bias_ma`（mA）|
| `tx_power_8472` | 10·log10(v) − 40 | `tx_power_dbm`（dBm）|
| `rx_power_8472` | 10·log10(v) − 40 | `rx_power_dbm`（dBm）|

### 实现要点

- 概览页扩展机制：`luci-mod-status` 的 `index.js` 会 `fs.list('/www/luci-static/resources/view/status/include')`，
  按文件名排序后 `L.require()` 每个 `.js`。模块用 `baseclass.extend({ title, load, render })` 导出。
  文件名 `70_pon.js` 决定它排在 `60_wifi.js` 之后。
- 设备名从 UCI `pon` 配置的 `xpon` 段 `device` 项读取，和 `luci-app-pon` 的 status.js 一致。
- 无 PON 设备或读取失败时 `render` 返回 `null`，卡片自动隐藏（`load` 里 `Promise.reject()`）。
- 自带 rpcd ACL（`luci-app-pon-status` 组），授权 `ponctl --device * status --json` 的 exec。
  与 `luci-app-pon` 用不同组名，避免 acl.d 同名覆盖。


### 本仓库的解决方式

直接放一份 `files/sbin/tempinfo` 覆盖进 rootfs（autocore 在 airoha 上不装同名文件，不冲突）：

- **CPU**：`/sys/class/thermal/thermal_zone0/temp`
- **WiFi**：mt76 的 hwmon，`phy*/hwmon*/temp1_input` 和
  `phy*/device/hwmon/hwmon*/temp1_input` 两个路径都试（mt76 两种挂法都见过）
- **PON**：`ponctl --device <dev> status --json` + `jsonfilter`，
  取 `frontend` 组的 `temperature_celsius` / `rx_power_dbm` / `tx_power_dbm` /
  `tx_bias_ma` / `voltage_volts`（airoha-ponctl 的 `convert_optics()` 已换算成显示单位）

输出示例：

```
CPU: 58.7°C, WiFi: 46.0°C 48.0°C, PON: 48.5°C ↑2.41dBm ↓-21.30dBm 12.50mA 3.30V
```

授权不需要额外处理 —— autocore 装的
`/usr/share/rpcd/acl.d/luci-mod-status-autocore.json` **无条件**授权 `luci.getTempInfo`
（只有 tempinfo 脚本本身受平台限制）。所以只要 `autocore=y` + `luci-base=y` 就通。

### 开关：SHOW_PON_OPTICS

`tempinfo` 顶部有一个开关：

```sh
SHOW_PON_OPTICS=1    # 温度行附带 PON 光功率/电流/电压
SHOW_PON_OPTICS=0    # 只显示温度（CPU / WiFi / PON）
```

设为 `0` 时输出：`CPU: 58.7°C, WiFi: 46.0°C 48.0°C, PON: 48.5°C`

本仓库**默认设为 `0`**，因为 `luci-app-pon-status` 卡片已用表格形式完整展示
收发光/电流/电压，两者会重复。若你想只要一行、不装 pon-status 卡片，改回 `1` 即可。

⚠️ 取舍：`SHOW_PON_OPTICS=1` 会把 dBm / mA / V 塞进标题为「温度」的一行，语义不严谨且行较长。


| | autocore tempinfo | luci-app-temp-status |
|---|---|---|
| CPU 温度 | ✅ | ✅ |
| WiFi 温度 | ✅ | ✅ |
| PON 温度/光功率 | ✅（本仓库扩展）| ❌ |
| 依赖 | 仅 shell + autocore + ponctl | `ucode` + `ucode-mod-fs` |

保留 autocore 方案：它是 ImmortalWrt 原生机制，无额外依赖，且能顺带扩展 PON。
移除后也省掉了 `ucode-mod-fs` 等间接项的体积（虽小）。

依赖：`airoha-ponctl`（`ponctl`）、`jsonfilter`、`uci` —— 配置里均已 `=y`。
脚本对三者都做了 `-x` 存在性检查，缺任一则自动跳过 PON 段，不影响 CPU/WiFi 显示。

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

## 工具链缓存机制

- Key：`ponwrt-toolchain-<board>-<subtarget>-<tools/toolchain 源码 md5 前 16 位>`，源码工具链一变就失效重编。
- 命中顺序：`actions/cache` → 仓库 `toolchain-cache` Release 备份 → 本地编译。
- Release 命中后会回写 `actions/cache`，下次构建走快通道。
- 命中缓存时用 `sed -i 's/ $(tool.*\/stamp-compile)//' Makefile` 跳过工具链重编。
- 额外缓存：`.ccache`（编译缓存）、`dl`（软件包下载目录）。

## 首次使用建议

免费 runner 单次上限 6 小时，首次全量编译（工具链 + 内核 + 全包）大概率超时：

1. 先跑一次 `scope = toolchain-only`，把工具链缓存建起来；
2. 再跑一次 `scope = firmware` 出固件；
3. 若仍超时，把 `configs/*.config` 里不需要的 luci-app / 语言包删掉再提交。

## 注意事项

- 刷机前用 [AN758x-Stock2UBI](https://github.com/pbs05) 备份原厂 flash；烽火 `factory` 备份需先过 `FiberHome Factory` 转换。
- 刷完后通过 U-Boot Web 或 LuCI → 网络 → PON → Configuration → PON board data 恢复校准/身份数据，否则 WiFi 与 PON  Registration 异常。
- `toolchain-cache` Release 由流程自动维护，`Remove old releases` 用 `delete_tag_pattern: ^<DEVICE_NAME>-` 限定，不会误删。
