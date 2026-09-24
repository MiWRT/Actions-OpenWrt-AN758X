# AN7581 单机型配置（v2，基于 1063 行基座）

以你提供的 1063 行配置为基座，生成 9 份单机型 `.config`，分 15 段带中文注释。

## 相对基座改了什么

| 项 | 基座状态 | 现在 | 原因 |
|---|---|---|---|
| `kmod-airoha-en7572` / `kmod-airoha-paged-bosa` | 只有 `MODULE_DEFAULT_` 标记（不参与编译） | 按机型开一个 `=y`、另一个关闭 | 缺光器件驱动光口起不来 |
| `luci-app-iptv` | 只有 `MODULE_DEFAULT_` 标记 | `=y` ★补回 | IPTV 桥接界面 |
| `luci-i18n-iptv-zh-cn` | 只有 `MODULE_DEFAULT_` 标记 | `=y` ★补回 | 配套中文包 |
| 机型 | `MULTI_PROFILE=y` 但无任何 `DEVICE_*=y` | 每份指定 1 个 | 原来机型未定，构建行为不可预期 |
| `luci-app-upnp` | `=y` | 保留 | 基座新增 |
| `mount-utils` | `=y` | 保留 | 基座新增 |
| 重复行 | 8 项重复（nf-flow、nft-offload、wireguard 等） | 全部去重 | 基座里有重复定义 |

基座 205 个包**全部保留**，零遗漏。

## 三个必须知道的点

### 1. 基座用的是 apk，不是 opkg

```
CONFIG_USE_APK=y
CONFIG_SIGNED_PACKAGES=y
CONFIG_SIGN_EACH_PACKAGE=y
CONFIG_SIGN_FIRMWARE=y
```

刷完机用 `apk` 装软件，不是 `opkg`。同时固件和每个包都会签名，编译时间会更长。

### 2. WiFi 和 2.5G PHY 驱动没编进去

基座里这些**只有 `CONFIG_MODULE_DEFAULT_` 标记**——那是 kconfig 的「target 默认值」标记，不参与实际构建：

```
kmod-mt7915e、kmod-mt7916-firmware、wpad-openssl、
kmod-phy-airoha-en8811h、rtl826x-firmware、znxt-zn515-mt7916-eeprom
```

你的 HG5585F 有 MT7916 WiFi，**这样编出来没有 WiFi**。要开就把第 15 段对应行取消注释。

其他机型同理：XG-040G-MD 有 2.5G 口（EN8811H），不装 PHY 驱动那个口不会起来。

### 3. daed 需要 BTF，基座没开

基座有 `CONFIG_KERNEL_DEBUG_INFO=y` 但**没有** `CONFIG_KERNEL_DEBUG_INFO_BTF=y`。要用 daed 得手动补（第 14 段注释里列全了）。

## 分 15 段

| 段 | 内容 |
|---|---|
| DEVICES | 目标机型 |
| 1. PON 内核驱动 | `kmod-airoha-xpon`、`kmod-airoha-pon-frontend` |
| 2. 光器件驱动 | 按机型二选一，注明本机型选了哪颗 |
| 3. PON 用户态 | `airoha-pond`、`airoha-ponctl`、`airoha-pon-debug` |
| 4. PON/IPTV LuCI | `luci-app-pon`、`luci-app-iptv` + 中文包 |
| 5. 硬件卸载 | NPU 固件、`nft-offload`、`nf-flow`、`conntrack-bridge`、BBR |
| 6. 网络转发 / nftables / 隧道 | nft 全家桶、WireGuard、ovpn、TUN、fullcone、PPP |
| 7. LuCI 界面 | luci + 各 mod + **upnp** + 主题 + 中文包 |
| 8. 基础服务 | dnsmasq-full、firewall4、netifd、odhcp、dropbear、uhttpd、rpcd |
| 9. 系统工具 | tcpdump、iperf3、ethtool-full、i2c-tools、nand/ubi-utils、**mount-utils** |
| 10. 引导与固件 | TF-A BL2/BL31、U-Boot（Nokia XG-040G-MD）、fwtool |
| 11. 其他内核模块与库 | GPIO 按键/LED、crypto 全家桶、libbpf |
| 12. 基座其余包 | 依赖库与未归类项（自动兜底，保证零遗漏） |
| 13. 内核选项 | 来自基座的 KERNEL_* |
| 14. 可选插件 | diy-part3 拉取，默认全关 |
| 15. 按需开启 | 基座未启用的 PHY/WiFi/存储/USB，注释列出 |

## 用法

本地：

```bash
git clone https://github.com/pbs05/ponwrt.git && cd ponwrt
./scripts/feeds update -a && ./scripts/feeds install -a
cp an7581-fiberhome_hg5585f-cu.config .config
make defconfig          # 必须
make -j$(nproc)
```

云编译：替换 `configs/` 目录内容即可，机型名不变，工作流不用改。

## 机型与光器件

| 机型 | profile | 光器件 |
|---|---|---|
| 烽火 HG5382A | `fiberhome_hg5382a` | `kmod-airoha-paged-bosa` |
| 烽火 HG5585F 电信版 | `fiberhome_hg5585f-ct` | `kmod-airoha-paged-bosa` |
| 烽火 HG5585F 联通版 | `fiberhome_hg5585f-cu` | `kmod-airoha-paged-bosa` |
| 智易 XG2010G | `gemtek_xg2010g` | `kmod-airoha-en7572` |
| 诺基亚贝尔 XG-040G-MD | `nokia_xg-040g-md-ubi` | `kmod-airoha-en7572` |
| 诺基亚贝尔 XG-040G-TF | `nokia_xg-040g-tf-ubi` | `kmod-airoha-en7572` |
| 广东联动 UNG00A | `unionman_ung00a` | `kmod-airoha-en7572` |
| 中兴 ZN504XG-D | `znxt_zn504xg-d` | `kmod-airoha-en7572` |
| 中兴 ZN515XG-D | `znxt_zn515xg-d` | `kmod-airoha-en7572` |

## 校验结果

9 份全部通过：机型唯一、光器件恰好开一个、基座 205 包零遗漏、无重复键、字符串值不含行内注释。每份 415 行。
