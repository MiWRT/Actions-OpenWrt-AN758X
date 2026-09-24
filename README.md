# PonWrt CI — Airoha AN758x PON 云编译

基于 P3TERX `Actions-OpenWrt` 模板重构，源码指向 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)（默认分支 `master`），
针对 AN7581 / AN7583 PON 光猫做机型选择、磁盘释放与工具链缓存。

## 目录结构

```
.github/workflows/build-ponwrt.yml     主构建流程（机型可选 / 释放空间 / 工具链缓冲）
.github/workflows/cache-keepalive.yml  每 5 天 touch 缓存，防止被回收
diy-part1.sh    拉取可选插件到 package/custom（argon/passwall/openclash/mosdns/lucky/tailscale 等，默认全关）
diy-part2.sh    把默认时区改成中国（Asia/Shanghai, CST-8）
configs/        每机型一份精简 diffconfig（约 440 行，需 make defconfig 展开）
files/          可选：自定义 rootfs 文件，会自动拷进源码
```

## diy 脚本

只有两个，职责单一：

### diy-part1.sh —— 拉插件

开关在脚本开头，默认只开 `ADD_ARGON=true`（sbwml 新版 argon 主题，会先 `rm -rf feeds/luci/themes/luci-theme-argon`
再拉，避免同名包冲突）。其余 `ADD_PASSWALL` / `ADD_OPENCLASH` / `ADD_MOSDNS` / `ADD_LUCKY` /
`ADD_TAILSCALE` / `ADD_OPENLIST` / `ADD_SMARTDNS` 默认 false。

启用两步：① 脚本里开关改 `true`；② `configs/<机型>.config` 第 19 段把对应
`# CONFIG_PACKAGE_xxx is not set` 改成 `=y`。

### diy-part2.sh —— 时区改中国

- 改 `package/base-files/files/bin/config_generate`：`timezone='CST-8'`、`zonename='Asia/Shanghai'`
- 写 `files/etc/uci-defaults/99-timezone-cn`，保留旧配置升级时也强制刷成中国时区
- 往 `.config` 追加 `CONFIG_PACKAGE_zoneinfo-asia=y`（LuCI 时区显示与切换需要，基座默认关闭）

## configs 说明

每个机型一份 `configs/<profile>.config`，统一为**精简 diffconfig**（约 440 行），只写与 ponwrt 官方
`configs/an7581.config` / `an7583.config` 基座的差异，流程里由 `Generate toolchain cache key` 步骤
`make defconfig` 展开成完整 `.config`。

统一规则：

- **NPU 每机型都开**：AN7581 → `airoha-en7581-npu-firmware=y`，AN7583 → `airoha-an7583-npu-firmware=y`，
  配合 `kmod-nft-offload` + `kmod-nf-flow` 走 PPE 硬件转发（PON 与以太网共用 NPU）。
- **全部走 ImmortalWrt 组件**：`dnsmasq-full`、`firewall4`、`nftables-json`、`autocore`、`shellsync`、
  `luci-app-package-manager`、`apk-openssl`。网络栈只有 nftables（`kmod-nft-*` / `kmod-nf-*`），
  不引入 iptables，也不引入 OpenWrt 官方 feed 的包；PON 相关全部来自 `pon_drivers` / `pon_userspace`。
- **按 DTS 硬件逐机型裁剪**：光器件（FiberHome BOSA / EN7572 二选一）、PHY（GPY211 / EN8811H / RTL8261N）、
  WiFi（仅 hg5585f-ct/cu 与 zn515 有 MT7916D）、USB（无口机型整段关闭）。
- 可选插件（passwall / openclash / mosdns / lucky / tailscale / 主题）全部以注释形式放在第 19 段，
  由 `diy-part3.sh` 拉取，默认关闭。

段落顺序：
```
target/包管理 → DEVICES → PON 内核驱动 → PON 用户态 → PON/IPTV LuCI
→ nftables 网络转发 → 隧道拨号 → LuCI → 基础服务 → 系统工具
→ 固件工具 → 内核模块 → 基础库 → 内核选项
→ 13 光器件 → 14 NPU 卸载 → 15 WiFi → 16 USB → 17 PHY → 18 TF-A → 19 可选插件 → 20 其他
```

| 机型 | SoC | 光器件 | 2.5G PHY | WiFi | USB | 校准数据 |
|------|-----|--------|----------|------|-----|----------|
| fiberhome_hg5382a | AN7581 | FiberHome BOSA (GN28L95/UX3363) | GPY211 | 无 | 无 | factory |
| fiberhome_hg5585f-ct | AN7581 | FiberHome BOSA | GPY211 | MT7916D | USB0(3.0)+USB1(2.0) | factory |
| fiberhome_hg5585f-cu | AN7581 | FiberHome BOSA | GPY211 | MT7916D | USB0(3.0)+USB1(2.0) | factory |
| gemtek_xg2010g | AN7581 | EN7572 | EN8811H + 2×RTL8261N | 无 | 无 | dsd |
| unionman_ung00a | AN7581 | EN7572 | EN8811H | 无 | 无 | reservearea |
| nokia_xg-040g-md-ubi | AN7581 | EN7572 | EN8811H | 无 | USB0+USB1（5V 可控） | bosa, ri |
| nokia_xg-040g-tf-ubi | AN7581 | EN7572 | EN8811H | 无 | USB0+USB1（无 5V 控制） | bosa, ri |
| znxt_zn504xg-d | AN7581 | EN7572 | EN8811H + 3×GE | 无 | USB1 | reservearea |
| znxt_zn515xg-d | AN7581 | EN7572 | EN8811H + 3×GE | MT7916D | USB1+USB2 | reservearea |
| nokia_xg-040g-mf | AN7583 | EN7572 | EN8811H | 无 | USB0 | bosa, ri |
| nokia_xg-040g-mf-ubi | AN7583 | EN7572 | EN8811H | 无 | USB0 | bosa, ri |

加减插件：把 `# CONFIG_PACKAGE_x is not set` 改成 `CONFIG_PACKAGE_x=y` 即开启，反向即关闭。

## 用法

1. Fork 本仓库，Settings → Actions 打开 Workflow 权限（Read and write）。
2. Actions → `Build PonWrt (Airoha AN758x PON)` → Run workflow，选参数：

| 参数 | 说明 |
|------|------|
| `branch` | ponwrt 源码分支，默认 `master` |
| `soc` | `an7581` / `an7583`，选 `all` 机型时生效，其他情况按机型自动校正 |
| `profile` | 机型，默认 `fiberhome_hg5585f-cu`；`all` = 全机型编译 |
| `scope` | `firmware` 出固件；`toolchain-only` 只编译并缓存工具链 |
| `ignore_cache` | `true` 时忽略缓存强制重编工具链 |
| `upload_release` | `true` 把固件发到 Release（默认开）；`false` 只传 Artifact |
| `ssh` | `true` 进入 tmate 调试 |

3. 产物：
   - Artifact：`OpenWrt_firmware_ponwrt-<soc>-<profile>_<时间>`（无论 `upload_release` 开关都会传）
   - Release：tag `ponwrt-<soc>-<profile>-<branch>-<时间戳>`，含固件 + sha256 校验 + 机型/校准数据说明

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
